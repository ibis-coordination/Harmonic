# Silent re-auth via long-lived refresh tokens

## What it does

Devices that have completed an interactive 2FA login get a long-lived (90-day) refresh token in a parent-domain httpOnly cookie. When the session cookie's controller-enforced timeouts go stale and the controller clears the session, a `before_action` silently mints a new session from the refresh token — no redirect to the auth subdomain, no 2FA re-prompt. Routine browsing stays seamless; sensitive operations still hit the reverification gate at full force.

Users see and manage their devices on the user-settings page. Admins kill all of a user's sessions via the existing `account_security_reset` flow, which now also revokes refresh tokens.

Scope: OAuth auth mode (production). `AUTH_MODE=honor_system` (dev) is untouched.

## Architecture

### Data model — `RefreshToken`

```
user_id           bigint    (fk, indexed)
token_digest      string    (SHA-256 of raw token; unique. Raw never stored.)
family_id         uuid      (groups rotated tokens — replay detection)
expires_at        timestamp (LIFETIME = 90 days from issuance)
rotated_at        timestamp (nullable — set when this token rotates to a successor)
last_used_at      timestamp
revoked_at        timestamp (nullable)
revoked_reason    string    (nullable; from VALID_REVOKE_REASONS)
user_agent        string
device_label      string    (parsed from UA: iPhone, Mac, Android, etc.)
ip_at_issue       string
two_factor_at     timestamp (nullable — when 2FA was last passed on this device)
```

Indexes: `(token_digest unique)`, `(family_id)`, `(user_id, revoked_at)`.

Not tenant-scoped: a refresh token represents a user's trusted device, valid across every tenant they belong to.

`VALID_REVOKE_REASONS`: `user_logout`, `rotation_replay`, `user_ineligible`, `admin`, `password_change`, `two_factor_disabled`.

### Cookie

- Name `_harmonic_refresh`. Value: 256-bit random base64url. The digest stays server-side; raw is unrecoverable from the DB.
- Domain `.<HOSTNAME>` (parent), path `/`, httpOnly, secure (prod/caddy), sameSite=`lax` (strict would block the existing OAuth bounce-back).
- Max-age: 90 days, refreshed on every rotation.

### Issuance — `TwoFactorAuthController#complete_2fa_login` only

Originally planned across three session-establishment sites; settled on one: **only after the user has actually passed 2FA on this device** (either via TOTP or a recovery code, both of which call `complete_2fa_login`).

The `oauth_callback` no-2FA path deliberately does NOT mint a refresh token. Doing so would create a 2FA bypass: handing a refresh cookie to a non-2FA user means silently re-authing them indefinitely if they later enabled 2FA. Users without 2FA continue to redo the OAuth bounce on session expiry (status quo); users with 2FA get the silent refresh win.

`ApplicationController#issue_refresh_token_for!` is defensively gated to `user.human?` so a future code path that forgets the gate can't mint a token for AI agents or collective identities.

### Silent refresh — `attempt_silent_refresh`

Runs as a `before_action` ordered AFTER `restore_mcp_dispatch_context!` and BEFORE `current_user` so downstream callbacks see the restored session as if the user had been logged in all along. It fires when the session is missing OR its timestamps are stale enough that `check_session_timeout` would clear them.

Short-circuit guards (any one → no-op): `AUTH_MODE != oauth`, auth subdomain, API-token request, auth controller, mid-2FA (`session[:pending_2fa_identity_id].present?`).

Token-level checks (any one → revoke + clear cookie + no session restored):
- Token nil / revoked / expired
- User no longer human, or now suspended
- `sessions_revoked_after?` — `user.sessions_revoked_at` is more recent than `token.created_at` (closes the gap where stale tokens could undo an admin "revoke all sessions" action)

`establish_silent_session` calls `reset_session` before writing `user_id`/`logged_in_at`/`last_activity_at`. Per-scope `reverified_at_*` keys are deliberately dropped on every silent refresh: routine browsing is restored, but reverification proofs are not. The user must reverify on the next sensitive action.

### Rotation + replay detection

Every successful silent refresh rotates the token: marks the presented token `rotated_at = now`, mints a successor in the same `family_id`, writes the successor's plaintext to the cookie. (RFC 6749 §10.4 refresh-token rotation.)

Presenting an already-rotated token within `REPLAY_GRACE_WINDOW` (30s) is treated as a benign in-flight race — common with multi-tab use where two tabs both refresh at once. The session is established **without re-rotating** and **without setting a new cookie**: the browser cookie was already updated by the winning sibling. Outside the window, replay = real compromise → the entire family is revoked.

The grace window is load-bearing for multi-tab use, not cosmetic. Without it, every Mac-user-with-two-tabs would get their family revoked on session expiry.

Side effect of rotation: `reset_session` regenerates the CSRF token. Forms rendered before the rotation will fail CSRF on submit and need a refresh. Acceptable.

### Revocation paths

| Trigger | What revokes | Mechanism |
|---|---|---|
| Explicit logout | The current device's token only | `SessionsController#destroy` → `revoke_current_refresh_token!` |
| User signs out a device from settings | That one device | `DevicesController#destroy` → `RefreshToken#revoke!` |
| User signs out other devices | All except the current one | `DevicesController#revoke_others` |
| 2FA disabled | ALL of the user's tokens | `TwoFactorAuthController#disable` → `RefreshToken.revoke_all_for_user!(reason: "two_factor_disabled")` |
| Password changed | ALL of the user's tokens | `PasswordResetsController#update` → `RefreshToken.revoke_all_for_user!(reason: "password_change")` |
| Admin "Account security reset" | All sessions + all API tokens + all refresh tokens | `User#revoke_all_sessions!` (called from `app_admin#execute_account_security_reset`) |

Timeout-driven logouts (idle/absolute) deliberately do NOT revoke the refresh token — that would defeat the whole point of silent re-auth on the next visit.

### `enforce_refresh_token_revocation` — the "kick the device immediately" check

Added in the settings-UI PR because revoking a refresh token alone doesn't end an in-flight session on that device. The session cookie was minted from a fresh interactive login and stays valid until it times out (which under Harmonic's current `SESSION_ABSOLUTE_TIMEOUT` of ~90 days is effectively forever).

The fix: the refresh cookie is sent on every request. A new `before_action` on every request reads the cookie, looks up the token, and if it's been revoked, logs the user out **on that request**. Rotated-but-not-revoked tokens pass through (rotation is benign in-flight state, not a kill signal).

This is what makes "Sign out device X from another device" actually mean "device X is signed out the next time it touches the server," not "device X is signed out in up to 90 days."

### Sessions-revoked-at interaction

`User#sessions_revoked_at` is a whole-user blanket cutoff timestamp that predates refresh tokens. It kills any session whose `logged_in_at < sessions_revoked_at` via `check_session_timeout`.

These coexist as parallel kill mechanisms:

- `sessions_revoked_at`: kills sessions. Honored by `check_session_timeout`.
- `refresh_token.revoked_at`: kills a specific device. Honored by `attempt_silent_refresh` AND `enforce_refresh_token_revocation`.
- `RefreshToken.revoke_all_for_user!`: kills all devices' silent re-auth. Honored by the same.

`silent refresh -> sessions_revoked_after?` bridges them at refresh time: a refresh token issued before `sessions_revoked_at` is refused. `revoke_all_sessions!` now also calls `RefreshToken.revoke_all_for_user!` so the bridge isn't load-bearing — both layers are killed explicitly.

### Tenant switching and multi-tab races

The Rails session cookie was already cross-subdomain (`config/initializers/session_store.rb`), so tenant switching today is seamless when the user is a member of both tenants. Refresh tokens preserve and extend that: one silent refresh restores the session everywhere at once, since both cookies are parent-domain scoped.

"Sign out of just one tenant on this device" is not supported. Refresh tokens are one-per-device-per-user, not per-tenant.

Representation sessions don't auto-resume: if a user was acting on behalf of someone else when their session expired, silent refresh restores `user_id` but not the representation state — they come back as themselves. Intentional.

## What was built (mapping to commits)

| PR | Commit | What it adds |
|----|--------|----|
| 1 | `30a3b1a9` | RefreshToken model + table + 26 model tests |
| 2 | `a104d223` | Issuance at 2FA verify_submit only; cookie helpers; 5 integration tests |
| 3 | `b842a30f` | `attempt_silent_refresh` before_action + all the guards; 13 integration tests |
| 4 | `e7d94700` | Revocation on logout, 2FA disable, password change; 7 integration tests |
| 5 | `63017c44` | Devices settings UI; `enforce_refresh_token_revocation`; `DevicesController`; 12 integration tests |
| 6 | `b2dae664` | `revoke_all_sessions!` covers refresh tokens; the admin panic button is now complete |

## Known limitations

- **Cross-subdomain cookies don't transfer cleanly in `ActionDispatch::IntegrationTest`** (same reason the session cookie skips its domain attribute in test mode). Tests stage refresh cookies directly on the tenant subdomain rather than driving the auth bounce. Production behavior is unaffected.
- **No IP-based location display**. The DB has `ip_at_issue`; the user-facing settings page deliberately doesn't render it (raw IPs aren't useful to most users; VPN/mobile cases lie). Geo lookup (MaxMind GeoLite2) is a possible follow-up.
- **No new-device login notifications**. The infrastructure makes this cheap to add: every new `RefreshToken` row is exactly one "new device" email. Not built here.
- **Recovery-code path is untested at the integration level**. `verify_submit` routes both TOTP and recovery-code success through `complete_2fa_login`, so the recovery-code path mints a refresh token via the same line. Covered in spirit by the TOTP test.

## Security properties (the load-bearing claims)

1. **No 2FA bypass.** Refresh tokens are issued only after the user actually passes 2FA on this device. Disabling 2FA, changing password, or running the admin security reset all revoke every token immediately. A user who has never enabled 2FA never has a refresh token to compromise.
2. **Theft is detected.** A stolen refresh cookie used after the legitimate user's next refresh trips the replay-grace-window check and revokes the family. Both parties get kicked; the user notices and re-auths.
3. **Reverification stays strict.** `establish_silent_session` calls `reset_session` so per-scope `reverified_at_*` keys are dropped on every silent refresh. Sensitive ops still require explicit reverification.
4. **Per-device revocation is immediate.** `enforce_refresh_token_revocation` kicks revoked devices on their very next request, not in 90 days.
5. **Admin panic button is complete.** `revoke_all_sessions!` revokes sessions, API tokens, AND refresh tokens. No surface remains through which a compromised account could silently re-auth after admin reset.

## Decisions

- Refresh token lifetime: 90 days, with rotation on every use.
- Issuance site: 2FA verify_submit only.
- Replay grace window: 30 seconds.
- 2FA re-prompt cadence on a trusted device: never on routine refresh while the token is active; sensitive ops gate via reverification.

## Out of scope (not built, not needed for this stack)

- WebAuthn / passkeys.
- Device fingerprinting beyond UA string.
- Per-tenant signout.
- Geo-IP location display.
- New-device login email notifications.
- Periodic cleanup of revoked/expired token rows (the table will grow; a daily Rake task is a future PR).
