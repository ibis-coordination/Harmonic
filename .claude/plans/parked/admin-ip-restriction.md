# Admin Access Hardening (IP Restriction + 2FA Re-verification)

## Context

Admin accounts (sys_admin, app_admin) are the most privileged in the system. To reduce risk from compromised credentials or session hijacking, we want two layers of protection:

1. **IP restriction** — limit admin panel access to specified IP addresses or CIDR ranges (e.g., a Tailscale network at `100.64.0.0/10`)
2. **2FA re-verification** — require admins to submit a fresh TOTP code before accessing admin panels, even if they already passed 2FA at login

Both layers are independent — either can be enabled without the other. This is the first phase; tenant-level restrictions will follow later.

## Approach

### IP Restriction

**Storage**: `ADMIN_ALLOWED_CIDRS` environment variable (comma-separated CIDR list). When unset, no restrictions apply. This matches how other security settings (`SESSION_ABSOLUTE_TIMEOUT`, etc.) are configured.

**Enforcement**: A shared `AdminIpRestriction` concern included in all three admin controllers. The IP check runs *after* the admin role check so non-admins see the normal "not an admin" page (no information leakage).

**No bypass**: If locked out, fix the env var. Anyone who can change env vars already has server access.

### Admin 2FA Re-verification

**Requirement**: `ADMIN_REQUIRE_2FA_REVERIFY` environment variable (boolean, default `false`). When enabled, admin users must enter a TOTP code before accessing any admin panel, regardless of whether they verified 2FA at login. Admins who don't have 2FA set up are redirected to the 2FA setup page first.

**Session tracking**: On successful verification, store `session[:admin_2fa_verified_at]` with a timestamp. The verification expires after a configurable duration (`ADMIN_2FA_REVERIFY_TIMEOUT`, default 1 hour). After expiry, the admin must re-verify. This is separate from the login 2FA session state (`session[:two_factor_verified]`).

**Flow**:
1. Admin navigates to an admin panel
2. Concern checks `session[:admin_2fa_verified_at]` — if missing or expired, redirect to `/admin/verify-2fa`
3. Admin enters TOTP code on a simple verification form (reuses existing TOTP verification logic from `TwoFactorAuthController`)
4. On success, set `session[:admin_2fa_verified_at]` and redirect to original destination
5. On failure, show error with retry (lockout follows existing 2FA lockout rules)

**Order of checks**: Role check → IP restriction → 2FA re-verification. Each layer only runs if the previous passed.

## Files to Create (IP Restriction)

### 1. `app/controllers/concerns/admin_ip_restriction.rb`
Concern providing `ensure_admin_ip_allowed` before_action:
- Parses `ADMIN_ALLOWED_CIDRS` env var into CIDR list
- Checks `request.remote_ip` against each range using `IPAddr` (same pattern as `automation_rule.rb:96-110`)
- On block: logs to `SecurityAuditLog`, renders 403
- On no config: allows all (feature is opt-in)

### 2. `app/views/shared/403_ip_blocked.html.erb`
Simple 403 page following the pattern of existing admin 403 pages (`app/views/app_admin/403_not_app_admin.html.erb`). Message: "Admin access is not available from your current network." Does not reveal the user's IP or allowed ranges.

### 3. `test/controllers/concerns/admin_ip_restriction_test.rb`
Test cases:
- No env var set → admin access works
- Allowed IP → access works
- Blocked IP → 403 + security audit log entry
- CIDR range matching (e.g., `10.0.0.0/8` allows `10.1.2.3`, blocks `192.168.1.1`)
- Multiple CIDRs (comma-separated)
- Invalid CIDR in config → gracefully handled
- JSON and markdown format responses

## Admin 2FA Re-verification

Uses the general-purpose re-verification system defined in
`.claude/plans/sensitive-action-reverification.md`. The admin controllers
simply include the `RequiresReverification` concern and add a
`before_action :require_reverification` after the admin role check.

No admin-specific 2FA controller or views needed — the shared
`/reverify` page handles everything.

## Files to Modify

### 9. `app/controllers/app_admin_controller.rb` (line 17-20)
Add `include AdminIpRestriction`, `include RequiresReverification`, and corresponding before_actions after `ensure_app_admin`. Order: `ensure_admin_ip_allowed`, then `require_reverification`.

### 10. `app/controllers/system_admin_controller.rb` (line 16-19)
Same — include both concerns and add before_actions after `ensure_sys_admin`.

### 11. `app/controllers/api/app_admin_controller.rb` (line 47)
Add IP check at end of `authenticate_app_admin!` method, after `token_used!`. (2FA re-verification does not apply to API token auth — tokens are already a separate credential.)

### 12. `app/services/security_audit_log.rb`
Add `log_admin_ip_blocked` class method following existing patterns.

### 13. `.env.example`
Add commented-out `ADMIN_ALLOWED_CIDRS` with documentation.

## Verification

1. Run existing admin controller tests to confirm no regressions
2. Run new IP restriction tests
3. Run new admin 2FA re-verification tests
4. Manual test (IP): set `ADMIN_ALLOWED_CIDRS=127.0.0.1/32` in Docker environment, confirm admin panels work from localhost, then set to a non-matching range and confirm 403
5. Manual test (2FA): set `ADMIN_REQUIRE_2FA_REVERIFY=true`, navigate to admin panel, confirm redirect to 2FA verification page, enter valid TOTP code, confirm access granted and subsequent requests within timeout don't re-prompt
