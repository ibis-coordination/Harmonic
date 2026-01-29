# Two-Factor Authentication (TOTP) Implementation Plan

**Created**: 2026-01-27
**Completed**: 2026-01-28
**Status**: Complete
**Priority**: High

## Overview

Add TOTP-based 2FA using authenticator apps (Google Authenticator, Authy, etc.) with backup recovery codes. Users can optionally enable 2FA in their settings.

## Key Decisions

- **Scope**: Email/password (identity provider) only - GitHub OAuth users rely on GitHub's security
- **Enforcement**: User optional - no tenant-level requirements
- **Recovery**: 10 one-time-use backup codes, stored as SHA256 hashes
- **Lockout**: 5 failed attempts → 15-minute lockout
- **Disabling**: Requires valid TOTP code or recovery code

---

## Dependencies to Add

```ruby
# Gemfile
gem 'rotp', '~> 6.3'      # TOTP implementation
gem 'rqrcode', '~> 2.2'   # QR code generation
```

---

## Database Migration

```ruby
class AddTwoFactorAuthToOmniAuthIdentities < ActiveRecord::Migration[7.0]
  def change
    add_column :omni_auth_identities, :otp_secret, :string
    add_column :omni_auth_identities, :otp_enabled, :boolean, default: false, null: false
    add_column :omni_auth_identities, :otp_enabled_at, :datetime
    add_column :omni_auth_identities, :otp_recovery_codes, :jsonb, default: []
    add_column :omni_auth_identities, :otp_failed_attempts, :integer, default: 0, null: false
    add_column :omni_auth_identities, :otp_locked_until, :datetime
  end
end
```

---

## Files to Create/Modify

### New Files

| File | Purpose |
|------|---------|
| `app/controllers/two_factor_auth_controller.rb` | Handle setup, verify, disable, regenerate |
| `app/views/two_factor_auth/verify.html.erb` | Login verification page |
| `app/views/two_factor_auth/setup.html.erb` | QR code setup page |
| `app/views/two_factor_auth/show_recovery_codes.html.erb` | Display recovery codes |
| `app/views/two_factor_auth/settings.html.erb` | Manage 2FA settings |
| `test/controllers/two_factor_auth_controller_test.rb` | Controller tests |
| `test/models/omni_auth_identity_two_factor_test.rb` | Model unit tests |

### Modify Existing

| File | Changes |
|------|---------|
| `Gemfile` | Add rotp, rqrcode gems |
| `app/models/omni_auth_identity.rb` | Add TOTP methods, recovery codes |
| `app/controllers/sessions_controller.rb` | Check 2FA in oauth_callback for identity provider |
| `app/services/security_audit_log.rb` | Add 2FA audit events |
| `app/views/users/settings.html.erb` | Add 2FA section |
| `config/routes.rb` | Add 2FA routes |

---

## Routes

```ruby
# In OAuth auth mode block
get 'login/verify-2fa' => 'two_factor_auth#verify'
post 'login/verify-2fa' => 'two_factor_auth#verify_submit'

get 'settings/two-factor' => 'two_factor_auth#setup'
post 'settings/two-factor/confirm' => 'two_factor_auth#confirm_setup'
get 'settings/two-factor/manage' => 'two_factor_auth#settings'
post 'settings/two-factor/disable' => 'two_factor_auth#disable'
post 'settings/two-factor/regenerate-codes' => 'two_factor_auth#regenerate_codes'
```

---

## Login Flow Modification

### Current Flow (Identity Provider)

```
1. User enters email/password → OmniAuth identity callback
2. oauth_callback sets session[:user_id] → redirect to /login/return
3. Token encrypted → redirect to tenant → session established
```

### Modified Flow

```
1. User enters email/password → OmniAuth identity callback
2. oauth_callback checks: is this identity provider AND otp_enabled?
   - YES → set session[:pending_2fa_identity_id], redirect to /login/verify-2fa
   - NO → proceed normally
3. User enters TOTP code → verify → set session[:user_id]
4. Continue to /login/return as normal
```

**Key**: Only intercept for identity provider (`request.env['omniauth.auth'].provider == 'identity'`), not GitHub OAuth.

---

## OmniAuthIdentity Model Additions

```ruby
# Constants
OTP_ISSUER = "Harmonic"
RECOVERY_CODE_COUNT = 10
MAX_OTP_ATTEMPTS = 5
OTP_LOCKOUT_DURATION = 15.minutes

# Core methods
def generate_otp_secret!
def otp_provisioning_uri
def verify_otp(code)
def generate_recovery_codes!
def verify_recovery_code(code)
def remaining_recovery_codes_count

# State management
def otp_locked?
def increment_otp_failed_attempts!
def reset_otp_failed_attempts!
def enable_otp!
def disable_otp!
```

---

## Security Audit Events

Add to SecurityAuditLog:

| Event | Description |
|-------|-------------|
| `log_2fa_success` | Successful 2FA verification during login |
| `log_2fa_failure` | Failed 2FA attempt |
| `log_2fa_lockout` | Account locked due to failed attempts |
| `log_2fa_enabled` | User enabled 2FA |
| `log_2fa_disabled` | User disabled 2FA |
| `log_2fa_recovery_code_used` | Recovery code consumed |
| `log_2fa_recovery_codes_regenerated` | New codes generated |

---

## Implementation Order

### Phase 1: Foundation

| # | Task | Status |
|---|------|--------|
| 1 | Add gems (rotp, rqrcode) to Gemfile | ✅ Done |
| 2 | Create database migration | ✅ Done |
| 3 | Add TOTP methods to OmniAuthIdentity model | ✅ Done |
| 4 | Write unit tests for model methods | ✅ Done |

### Phase 2: Login Verification

| # | Task | Status |
|---|------|--------|
| 5 | Create TwoFactorAuthController with verify/verify_submit actions | ✅ Done |
| 6 | Create verify.html.erb view | ✅ Done |
| 7 | Modify sessions_controller oauth_callback for identity provider | ✅ Done |
| 8 | Add verify routes | ✅ Done |
| 9 | Write integration tests for login flow | ✅ Done |

### Phase 3: Setup Flow

| # | Task | Status |
|---|------|--------|
| 10 | Add setup/confirm_setup actions to controller | ✅ Done |
| 11 | Create setup.html.erb with QR code | ✅ Done |
| 12 | Create show_recovery_codes.html.erb | ✅ Done |
| 13 | Add setup routes | ✅ Done |
| 14 | Write tests for setup flow | ✅ Done |

### Phase 4: Management

| # | Task | Status |
|---|------|--------|
| 15 | Add settings/disable/regenerate_codes actions | ✅ Done |
| 16 | Create settings.html.erb | ✅ Done |
| 17 | Add 2FA section to users/settings.html.erb | ✅ Done |
| 18 | Add security audit events | ✅ Done |
| 19 | Write management tests | ✅ Done |

### Phase 5: Polish

| # | Task | Status |
|---|------|--------|
| 20 | Add CSS for QR code and recovery codes display | ✅ Done (inline styles) |
| 21 | Add copy-to-clipboard for recovery codes | ✅ Done |
| 22 | End-to-end testing | Pending (manual testing) |
| 23 | Update plan doc with completion status | ✅ Done |

---

## Verification Checklist

After implementation, verify:

### Setup Flow
- [ ] User can scan QR code with authenticator app
- [ ] Valid code enables 2FA
- [ ] Recovery codes are displayed and can be copied

### Login Flow
- [ ] Email/password login with 2FA enabled redirects to verification
- [ ] Valid TOTP code completes login
- [ ] Valid recovery code completes login (and is consumed)
- [ ] GitHub OAuth bypasses 2FA verification

### Security
- [ ] 5 failed attempts lock account for 15 minutes
- [ ] Recovery codes work only once
- [ ] Disabling requires valid code
- [ ] All events logged to security audit log

### Tests
- [ ] All model unit tests pass
- [ ] All controller integration tests pass
- [ ] `./scripts/run-tests.sh` passes

---

## Key Implementation Details

### OTP Secret Storage

Store in plaintext in database (not encrypted). Rationale:
- The secret needs to be readable to generate TOTP codes
- Database-level encryption (if configured) provides protection at rest
- This matches the pattern used by most 2FA implementations

### Recovery Code Format

- 10 codes, each 16 hex characters (e.g., `A1B2C3D4E5F6G7H8`)
- Stored as JSON array of objects: `[{"hash": "sha256...", "used_at": null}, ...]`
- Only hashes stored; plaintext shown once at generation

### Pending 2FA Session

- Use `session[:pending_2fa_identity_id]` to store identity ID
- Add `session[:pending_2fa_started_at]` for timeout (5 minutes)
- Clear both on successful verification or timeout

---

## References

- [OWASP MFA Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Multifactor_Authentication_Cheat_Sheet.html)
- [RFC 6238 - TOTP](https://datatracker.ietf.org/doc/html/rfc6238)
- [rotp gem documentation](https://github.com/mdp/rotp)
- [rqrcode gem documentation](https://github.com/whomwah/rqrcode)
