# Authentication Security Hardening Plan

**Created**: 2026-01-27
**Status**: Active
**Priority**: High

## Overview

This plan documents the findings from a comprehensive security audit of the Harmonic authentication system and provides actionable items for hardening the application against common attack vectors.

---

## Current Security Posture

### Strengths (No Action Required)

| Area | Implementation | Location |
|------|----------------|----------|
| Password Hashing | BCrypt via `has_secure_password` | `app/models/omni_auth_identity.rb` |
| Password Length | 14-character minimum (exceeds NIST recommendations) | `app/models/omni_auth_identity.rb:46` |
| Rate Limiting | Multi-layer with Redis persistence | `config/initializers/rack_attack.rb` |
| OAuth CSRF | `omniauth-rails_csrf_protection` gem | `Gemfile`, `config/initializers/omniauth.rb` |
| OAuth Requests | POST-only (prevents GET-based attacks) | `config/initializers/omniauth.rb` |
| Password Reset Tokens | 256-bit cryptographically secure, 2-hour expiry | `app/models/omni_auth_identity.rb` |
| Account Enumeration | Generic responses in password reset flow | `app/controllers/password_resets_controller.rb:36` |
| Security Audit Logging | Comprehensive event logging with alerts | `app/services/security_audit_log.rb` |
| CSP Frame Protection | `frame-ancestors: none` (prevents clickjacking) | `config/initializers/content_security_policy.rb` |
| HTTPS | `force_ssl = true` in production | `config/environments/production.rb:51` |
| Multi-Tenant Token Validation | Encrypted tokens with tenant_id verification | `app/controllers/sessions_controller.rb:173-176` |

---

## Phase 1: High Priority Fixes

### 1.1 Add HttpOnly Flag to Shared Domain Cookies

**Risk Level**: Medium
**Effort**: Low
**Location**: `app/controllers/sessions_controller.rb:245-251`

**Current Code**:
```ruby
def set_shared_domain_cookie(key, value)
  cookies[key] = { value: value, domain: ".#{ENV['HOSTNAME']}" }
end
```

**Problem**: Cookies (`token`, `redirect_to_subdomain`, `redirect_to_resource`, `studio_invite_code`) are accessible to JavaScript, making them vulnerable to XSS-based theft.

**Solution**: Add security flags to all shared domain cookies:
```ruby
def set_shared_domain_cookie(key, value)
  cookies[key] = {
    value: value,
    domain: ".#{ENV['HOSTNAME']}",
    httponly: true,
    secure: Rails.env.production?,
    same_site: :lax
  }
end
```

**Testing**:
- [ ] Verify OAuth login flow still works
- [ ] Verify cross-subdomain redirects work
- [ ] Verify studio invite flow works
- [ ] Check browser dev tools to confirm flags are set

---

### 1.2 Sanitize HTML in OAuth Error Response

**Risk Level**: Low-Medium
**Effort**: Low
**Location**: `app/controllers/sessions_controller.rb:59`

**Current Code**:
```ruby
render status: 403, layout: 'pulse', html: "OAuth provider <code>#{request.env['omniauth.auth'].provider}</code> is not enabled for subdomain <code>#{original_tenant.subdomain}</code>".html_safe
```

**Problem**: Uses `.html_safe` with interpolated values. While OmniAuth should sanitize provider names and subdomain comes from the database, this violates defense-in-depth principles.

**Solution**: Use ERB escaping:
```ruby
provider = ERB::Util.html_escape(request.env['omniauth.auth'].provider)
subdomain = ERB::Util.html_escape(original_tenant.subdomain)
render status: 403, layout: 'pulse', html: "OAuth provider <code>#{provider}</code> is not enabled for subdomain <code>#{subdomain}</code>".html_safe
```

**Or better**, use a proper view template.

**Testing**:
- [ ] Test with valid OAuth provider
- [ ] Test with invalid OAuth provider (should show error)

---

## Phase 2: Medium Priority Improvements

### 2.1 Implement Session Timeout

**Risk Level**: Medium
**Effort**: Medium
**Location**: `config/initializers/session_store.rb`, `app/controllers/application_controller.rb`

**Problem**: Sessions persist indefinitely until browser close or cookie expiry (Rails default ~4 weeks). Compromised sessions remain valid too long.

**Solution**: Implement both absolute and idle timeouts.

**Option A - Gem-based** (Recommended):
Add `devise-security` or implement custom timeout logic.

**Option B - Custom Implementation**:

1. Add timestamp tracking to session:
```ruby
# In ApplicationController
before_action :check_session_timeout

private

def check_session_timeout
  return unless logged_in?

  # Absolute timeout: 24 hours from login
  if session[:logged_in_at] && session[:logged_in_at] < 24.hours.ago
    reset_session
    redirect_to login_path, alert: "Session expired. Please log in again."
    return
  end

  # Idle timeout: 2 hours of inactivity
  if session[:last_activity_at] && session[:last_activity_at] < 2.hours.ago
    reset_session
    redirect_to login_path, alert: "Session expired due to inactivity."
    return
  end

  session[:last_activity_at] = Time.current
end
```

2. Set `logged_in_at` on successful login in `sessions_controller.rb`

**Configuration Options** (add to settings):
- `SESSION_ABSOLUTE_TIMEOUT`: 24 hours (default)
- `SESSION_IDLE_TIMEOUT`: 2 hours (default)

**Testing**:
- [ ] Verify session expires after absolute timeout
- [ ] Verify session expires after idle timeout
- [ ] Verify active usage resets idle timer
- [ ] Verify user is redirected to login with appropriate message

---

### 2.2 Remove `unsafe-inline` from CSP Style Directive

**Risk Level**: Low
**Effort**: Medium-High
**Location**: `config/initializers/content_security_policy.rb:38`

**Current Code**:
```ruby
policy.style_src :self, :unsafe_inline
```

**Problem**: Allows style injection attacks (UI redress, data exfiltration via CSS).

**Solution**: Use CSP nonces for inline styles.

1. Generate nonce in ApplicationController:
```ruby
before_action :set_csp_nonce

def set_csp_nonce
  @csp_nonce = SecureRandom.base64(16)
end
```

2. Update CSP config:
```ruby
policy.style_src :self, -> { "nonce-#{@csp_nonce}" }
```

3. Update all inline styles to use nonce:
```erb
<style nonce="<%= @csp_nonce %>">
  /* styles */
</style>
```

**Note**: This requires auditing all views for inline styles. May be deferred if effort is too high.

**Testing**:
- [ ] Verify all pages render correctly
- [ ] Check browser console for CSP violations
- [ ] Test inline styles in views

---

### 2.3 Validate Encryptor Key Length

**Risk Level**: Low
**Effort**: Low
**Location**: `app/controllers/application_controller.rb:479-481`

**Current Code**:
```ruby
def encryptor
  @encryptor ||= ActiveSupport::MessageEncryptor.new(Rails.application.secret_key_base[0..31])
end
```

**Problem**: Truncates key to 32 chars without validation. Non-standard pattern.

**Solution**: Add validation and use Rails key derivation:
```ruby
def encryptor
  @encryptor ||= begin
    key = Rails.application.secret_key_base
    raise "SECRET_KEY_BASE must be at least 32 characters" if key.length < 32
    derived_key = ActiveSupport::KeyGenerator.new(key).generate_key('cross_subdomain_token', 32)
    ActiveSupport::MessageEncryptor.new(derived_key)
  end
end
```

**Testing**:
- [ ] Verify OAuth login flow works
- [ ] Verify existing tokens are invalidated (expected - one-time migration)

---

## Phase 3: Low Priority / Future Enhancements

### 3.1 Add Common Password Checking

**Risk Level**: Low
**Effort**: Low
**Location**: `app/models/omni_auth_identity.rb`

**Problem**: Only length is validated. Users could use common passwords like "passwordpassword".

**Solution**: Add validation against common password list:
```ruby
validate :password_not_common, if: -> { password.present? }

COMMON_PASSWORDS = Set.new(File.readlines(Rails.root.join('config', 'common_passwords.txt')).map(&:strip))

def password_not_common
  if COMMON_PASSWORDS.include?(password.downcase)
    errors.add(:password, "is too common. Please choose a more unique password.")
  end
end
```

Download common passwords list from: https://github.com/danielmiessler/SecLists/blob/master/Passwords/Common-Credentials/10k-most-common.txt

**Testing**:
- [ ] Verify common passwords are rejected
- [ ] Verify unique passwords are accepted
- [ ] Verify error message is user-friendly

---

### 3.2 Hash Password Reset Tokens

**Risk Level**: Low
**Effort**: Low
**Location**: `app/models/omni_auth_identity.rb`

**Current**: Reset tokens stored in plaintext.

**Problem**: Database compromise exposes valid reset tokens.

**Solution**: Store only hashed tokens:
```ruby
def generate_reset_password_token!
  raw_token = SecureRandom.urlsafe_base64(32)
  self.reset_password_token = Digest::SHA256.hexdigest(raw_token)
  self.reset_password_sent_at = Time.current
  save!
  raw_token  # Return raw token for email
end

def self.find_by_reset_password_token(raw_token)
  return nil if raw_token.blank?
  hashed = Digest::SHA256.hexdigest(raw_token)
  find_by(reset_password_token: hashed)
end
```

**Testing**:
- [ ] Verify password reset flow works
- [ ] Verify tokens in database are hashed
- [ ] Verify old plaintext tokens no longer work (migration needed)

---

### 3.3 Multi-Factor Authentication (MFA) ✅

**Risk Level**: N/A (Enhancement)
**Effort**: High
**Location**: `app/controllers/two_factor_auth_controller.rb`, `app/models/omni_auth_identity.rb`

**Status**: ✅ Complete

**Implementation**:
- TOTP-based MFA using `rotp` gem for email/password users
- 10 backup recovery codes stored as SHA256 hashes
- 5 failed attempts triggers 15-minute lockout
- QR code generation using `rqrcode` gem
- Stimulus controller for CSP-compliant copy/download of recovery codes

**Features**:
- Setup flow with QR code and manual key entry
- Verification during login
- Settings page to manage 2FA, regenerate codes, or disable
- Recovery code usage with automatic invalidation
- Security audit logging for all 2FA events

**Files Added/Modified**:
- `app/controllers/two_factor_auth_controller.rb` (new)
- `app/views/two_factor_auth/` (4 views)
- `app/models/omni_auth_identity.rb` (OTP methods)
- `app/javascript/controllers/recovery_codes_controller.ts` (new)
- `config/routes.rb` (2FA routes)
- 38 tests in `test/controllers/two_factor_auth_controller_test.rb`

---

### 3.4 Add Re-authentication for Sensitive Operations

**Risk Level**: Low
**Effort**: Medium
**Location**: Various controllers

**Problem**: Session hijacking allows full account access.

**Solution**: Require password re-entry for:
- Password changes
- Email changes
- API token creation/deletion
- Account deletion
- Admin operations

**Implementation**: Add `require_recent_authentication` before_action that checks `session[:authenticated_at]` is within 5-10 minutes.

---

## Phase 4: Verification & Monitoring

### 4.1 Verify Honor System Disabled in Production

**Location**: `config/initializers/security_checks.rb`

**Status**: ✅ Complete

**Implementation**: Added runtime check in initializer that raises an error if `AUTH_MODE=honor_system` in production. The application will fail to boot with a clear error message explaining the issue and how to fix it.

**Checklist**:
- [x] Verify `AUTH_MODE` is NOT `honor_system` in production (enforced at boot)
- [x] Add CI check to prevent deployment with `AUTH_MODE=honor_system` (app won't start)
- [ ] Document in deployment runbook

---

### 4.2 Review Unscoped Queries

**Location**: Search codebase for `.unscoped`

**Known Usage**: `app/controllers/sessions_controller.rb:216`

**Checklist**:
- [ ] Audit all `.unscoped` usage
- [ ] Verify each usage is necessary and safe
- [ ] Document why unscoped is needed in comments

---

### 4.3 Set Up Security Monitoring

**Checklist**:
- [ ] Monitor `log/security_audit.log` for anomalies
- [ ] Set up alerts for:
  - Multiple failed logins from same IP
  - Password reset spikes
  - IP blocks
- [ ] Review logs weekly during initial rollout

---

## Implementation Order

| Priority | Item | Effort | Risk Mitigated | Status |
|----------|------|--------|----------------|--------|
| 1 | 1.1 HttpOnly Cookies | Low | XSS token theft | ✅ Done |
| 2 | 1.2 Sanitize HTML | Low | XSS in error page | ✅ Done |
| 3 | 2.1 Session Timeout | Medium | Session hijacking | ✅ Done |
| 4 | 2.3 Key Validation | Low | Crypto weakness | ✅ Done |
| 5 | 3.1 Common Passwords | Low | Weak passwords | ✅ Done |
| 6 | 3.2 Hash Reset Tokens | Low | DB compromise | ✅ Done |
| 7 | 4.1 Honor System Check | Low | Misconfig in prod | ✅ Done |
| 8 | 2.2 CSP Nonces | High | Style injection | Deferred |
| 9 | 3.3 MFA | High | Account takeover | ✅ Done |
| 10 | 3.4 Re-authentication | Medium | Session abuse | Future |

---

## Files to Modify

| File | Changes |
|------|---------|
| `app/controllers/sessions_controller.rb` | Cookie flags, HTML sanitization |
| `app/controllers/application_controller.rb` | Session timeout, key validation |
| `app/models/omni_auth_identity.rb` | Common password check, token hashing |
| `config/initializers/content_security_policy.rb` | CSP nonces (if implemented) |
| `config/initializers/session_store.rb` | Session configuration |
| `config/initializers/security_checks.rb` | Honor system production check (new) |

---

## Success Criteria

- [x] All Phase 1 items completed and tested
- [x] No security regressions in existing functionality (all 1367 tests pass)
- [x] Security audit log shows expected events (session timeout logging added)
- [x] MFA/2FA implementation complete with 38 passing tests
- [ ] Browser dev tools confirm cookie flags are set (manual verification needed)
- [ ] Penetration test (if planned) shows no critical findings
- [ ] Phase 5 API token security items completed
- [ ] Phase 6 user suspension feature completed

## Implementation Notes (2026-01-27)

**Completed implementations:**

1. **HttpOnly Cookies (1.1)**: Added `httponly: true`, `secure: Rails.env.production?`, and `same_site: :lax` to `set_shared_domain_cookie` in `sessions_controller.rb:245-253`

2. **HTML Sanitization (1.2)**: Added `ERB::Util.html_escape` for provider and subdomain in OAuth error response at `sessions_controller.rb:59-61`

3. **Session Timeout (2.1)**: Added absolute (24h) and idle (2h) timeouts via `check_session_timeout` in `application_controller.rb`. Configurable via `SESSION_ABSOLUTE_TIMEOUT` and `SESSION_IDLE_TIMEOUT` env vars. Sessions now track `logged_in_at` and `last_activity_at`.

4. **Key Derivation (2.3)**: Changed `encryptor` method to use `ActiveSupport::KeyGenerator` with proper key derivation instead of direct key truncation. See `application_controller.rb:487-493`

5. **Common Password Check (3.1)**: Added `password_not_common` validation to `OmniAuthIdentity` with a curated list of 14+ character common passwords in `config/common_passwords.txt`

6. **Hashed Reset Tokens (3.2)**: Password reset tokens are now stored as SHA256 hashes. Raw token returned from `generate_reset_password_token!` for email delivery. See `omni_auth_identity.rb:12-34` and `password_reset_mailer.rb`

7. **Honor System Production Check (4.1)**: Added `config/initializers/security_checks.rb` that raises a clear error at boot if `AUTH_MODE=honor_system` in production environment.

**Files modified:**
- `app/controllers/sessions_controller.rb`
- `app/controllers/application_controller.rb`
- `app/models/omni_auth_identity.rb`
- `app/services/security_audit_log.rb`
- `app/mailers/password_reset_mailer.rb`
- `app/controllers/password_resets_controller.rb`
- `config/common_passwords.txt` (new)
- `test/test_helper.rb` (updated encryption key derivation)
- `test/controllers/sessions_controller_test.rb` (updated test helper)
- `test/controllers/password_resets_controller_test.rb` (updated for hashed tokens)
- `config/initializers/security_checks.rb` (new - honor system production check)

**MFA/2FA files added (Phase 3.3):**
- `app/controllers/two_factor_auth_controller.rb` (new)
- `app/views/two_factor_auth/setup.html.erb` (new)
- `app/views/two_factor_auth/verify.html.erb` (new)
- `app/views/two_factor_auth/settings.html.erb` (new)
- `app/views/two_factor_auth/show_recovery_codes.html.erb` (new)
- `app/javascript/controllers/recovery_codes_controller.ts` (new)
- `app/javascript/controllers/index.ts` (updated - register recovery-codes controller)
- `config/routes.rb` (updated - 2FA routes)
- `test/controllers/two_factor_auth_controller_test.rb` (new - 38 tests)
- `db/migrate/XXXXXX_add_otp_to_omni_auth_identities.rb` (new)

---

## Phase 5: API Token Security Hardening

**Added**: 2026-01-27
**Status**: Pending

This phase addresses security concerns identified during an audit of API token management in the UI and API.

### Current Implementation Summary

| Component | Location | Status |
|-----------|----------|--------|
| Token Generation | `app/models/api_token.rb:188` | ✅ Secure (40-char hex via `SecureRandom.hex(20)`) |
| Token Storage | Database | ⚠️ Plaintext (not hashed) |
| Token Display | `app/views/api_tokens/show.html.erb` | ✅ Obfuscated (first 4 chars + asterisks) |
| Clipboard Copy | `app/javascript/controllers/clipboard_controller.ts` | ✅ Secure (hidden input + Clipboard API) |
| Parameter Filtering | `config/initializers/filter_parameter_logging.rb` | ✅ `:token` filtered in logs |
| Expiration | `app/models/api_token.rb:108-111` | ✅ Enforced at auth time |
| Soft Delete | `app/models/api_token.rb:134-137` | ✅ Sets `deleted_at` timestamp |

---

### 5.1 Fix Markdown View Token Exposure (CRITICAL)

**Risk Level**: High
**Effort**: Low
**Location**: `app/views/api_tokens/show.md.erb:10`

**Current Code**:
```erb
| Token | `<%= @token.token %>` |
```

**Problem**: Full unobfuscated API token is exposed in markdown output. Any LLM or API client requesting token details in markdown format receives the plaintext token. This is inconsistent with the HTML view which shows the obfuscated token.

**Solution**: Use obfuscated token in markdown view, matching HTML behavior:
```erb
| Token | `<%= @token.obfuscated_token %>` |
```

**Note**: If the intention is to allow LLMs to retrieve the full token once for use, add a separate action with explicit acknowledgment (e.g., `reveal_token` action) rather than exposing it by default.

**Testing**:
- [ ] Verify markdown view shows obfuscated token
- [ ] Verify LLM can still create tokens via markdown API
- [ ] Consider if a `reveal_token` action is needed for LLM workflows

---

### 5.2 Fix Bug in API Token Update Controller

**Risk Level**: Medium (bug, not security)
**Effort**: Low
**Location**: `app/controllers/api/v1/api_tokens_controller.rb:33`

**Current Code**:
```ruby
def update
  token = current_user.api_tokens.find_by(id: params[:id])
  token ||= current_user.api_tokens.find_by(token: params[:id])
  return render_not_found(note) unless token  # BUG: references `note` instead of `token`
  # ...
end
```

**Problem**: References undefined variable `note` instead of `token`. This will cause a `NameError` when token is not found.

**Solution**:
```ruby
return render_not_found(token) unless token
```

**Testing**:
- [ ] Verify 404 response when updating non-existent token
- [ ] Add test case for this scenario

---

### 5.3 Remove Token String Lookup in API

**Risk Level**: Medium
**Effort**: Low
**Location**: `app/controllers/api/v1/api_tokens_controller.rb:10-12, 31-32, 44-45`

**Current Code**:
```ruby
token = current_user.api_tokens.find_by(id: params[:id])
token ||= current_user.api_tokens.find_by(token: params[:id])
```

**Problem**: Allows looking up tokens by their secret value in the URL path (e.g., `GET /api/v1/users/:user_id/tokens/abc123secrettoken`). While authentication is still required, this:
1. May expose tokens in server logs, browser history, or referrer headers
2. Is unnecessary since tokens have IDs for lookup
3. Violates principle of least exposure

**Solution**: Remove token string lookup fallback:
```ruby
token = current_user.api_tokens.find_by(id: params[:id])
return render_not_found(token) unless token
```

**Testing**:
- [ ] Verify lookup by ID still works
- [ ] Verify lookup by token string returns 404
- [ ] Update any documentation that suggests using token string for lookup

---

### 5.4 Restrict Full Token Retrieval

**Risk Level**: Medium
**Effort**: Low
**Location**: `app/controllers/api/v1/api_tokens_controller.rb:12`, `app/models/api_token.rb:82-84`

**Current Code**:
```ruby
# Controller
render json: token.api_json(include: params[:include]&.split(','))

# Model
if include&.include?('full_token')
  json[:token] = token
end
```

**Problem**: Any authenticated request with `?include=full_token` can retrieve the full token value at any time. Tokens should only be visible immediately after creation.

**Solution Options**:

**Option A (Recommended)**: Remove `full_token` include option entirely:
```ruby
# Remove lines 82-84 from api_token.rb
```

**Option B**: Add time restriction (only within 5 minutes of creation):
```ruby
if include&.include?('full_token') && created_at > 5.minutes.ago
  json[:token] = token
end
```

**Testing**:
- [ ] Verify token is returned on creation
- [ ] Verify token cannot be retrieved later via `include=full_token`
- [ ] Update API documentation

---

### 5.5 Consider Hashing Stored Tokens

**Risk Level**: Medium
**Effort**: Medium
**Location**: `app/models/api_token.rb`

**Current State**: Tokens are stored in plaintext in the database.

**Problem**: Database compromise exposes all valid API tokens.

**Solution**: Store only hashed tokens (similar to password reset token hashing in Phase 3.2):

```ruby
# In ApiToken model
before_create :generate_and_hash_token

def generate_and_hash_token
  raw_token = SecureRandom.hex(20)
  self.token = Digest::SHA256.hexdigest(raw_token)
  @raw_token = raw_token  # Temporarily store for response
end

def raw_token
  @raw_token
end

# For authentication lookup
def self.find_by_raw_token(raw_token)
  return nil if raw_token.blank?
  hashed = Digest::SHA256.hexdigest(raw_token)
  find_by(token: hashed)
end
```

**Migration Considerations**:
- Existing tokens would need to be invalidated OR migrated with a flag
- Token display changes to show "Shown once" after creation
- Obfuscation would need to use a separate `token_prefix` column

**Testing**:
- [ ] Verify token creation returns raw token
- [ ] Verify token authentication works with hashed storage
- [ ] Verify raw tokens cannot be recovered from database

---

### 5.6 Add Token Rotation Endpoint

**Risk Level**: Low (enhancement)
**Effort**: Medium
**Location**: `app/controllers/api/v1/api_tokens_controller.rb`, `config/routes.rb`

**Problem**: No way to rotate a token while preserving its name and configuration. Users must create a new token and delete the old one (two operations, potential for mistakes).

**Solution**: Add rotation endpoint:

```ruby
# POST /api/v1/users/:user_id/tokens/:id/rotate
def rotate
  old_token = current_user.api_tokens.find_by(id: params[:id])
  return render_not_found unless old_token

  new_token = current_user.api_tokens.create!(
    name: old_token.name,
    scopes: old_token.scopes,
    expires_at: [old_token.expires_at, 1.year.from_now].compact.min
  )

  old_token.delete!

  render json: new_token.api_json(include: ['full_token'])
end
```

**Testing**:
- [ ] Verify rotation creates new token with same config
- [ ] Verify old token is deleted
- [ ] Verify new token is returned in response

---

### 5.7 Add Expired Token Cleanup Job

**Risk Level**: Low (maintenance)
**Effort**: Low
**Location**: New Sidekiq job

**Problem**: Expired and soft-deleted tokens accumulate in database indefinitely.

**Solution**: Add periodic cleanup job:

```ruby
# app/jobs/cleanup_expired_tokens_job.rb
class CleanupExpiredTokensJob < ApplicationJob
  queue_as :low_priority

  def perform
    # Hard delete tokens expired/deleted more than 30 days ago
    ApiToken.unscoped
            .where("deleted_at < ? OR expires_at < ?", 30.days.ago, 30.days.ago)
            .delete_all
  end
end
```

Schedule via `config/sidekiq_cron.yml`:
```yaml
cleanup_expired_tokens:
  cron: "0 3 * * *"  # Daily at 3 AM
  class: CleanupExpiredTokensJob
```

**Testing**:
- [ ] Verify old tokens are deleted
- [ ] Verify recent tokens are preserved
- [ ] Verify job runs on schedule

---

### Phase 5 Implementation Order

| Priority | Item | Effort | Risk | Status |
|----------|------|--------|------|--------|
| 1 | 5.1 Markdown Token Exposure | Low | High | Pending |
| 2 | 5.2 Bug Fix (note→token) | Low | Medium | Pending |
| 3 | 5.3 Remove Token String Lookup | Low | Medium | Pending |
| 4 | 5.4 Restrict Full Token Retrieval | Low | Medium | Pending |
| 5 | 5.5 Hash Stored Tokens | Medium | Medium | Future |
| 6 | 5.6 Token Rotation Endpoint | Medium | Low | Future |
| 7 | 5.7 Cleanup Job | Low | Low | Future |

---

### Phase 5 Files to Modify

| File | Changes |
|------|---------|
| `app/views/api_tokens/show.md.erb` | Use obfuscated token |
| `app/controllers/api/v1/api_tokens_controller.rb` | Fix bug, remove token lookup, restrict full_token |
| `app/models/api_token.rb` | Remove/restrict full_token include, add hashing (future) |
| `config/routes.rb` | Add rotation endpoint (future) |
| `app/jobs/cleanup_expired_tokens_job.rb` | New file for cleanup (future) |

---

## Phase 6: Admin User Suspension/Locking

**Added**: 2026-01-27
**Status**: ✅ Completed (2026-01-28)

This phase adds the ability for tenant admins to suspend or lock specific user accounts through the admin UI.

### Implementation Summary

All items in this phase have been implemented:

1. **User Suspension Fields (6.1)**: Added `suspended_at`, `suspended_by_id`, `suspended_reason` columns via migration `20260128072608_add_suspension_to_users.rb`. Added `suspended?`, `suspend!`, `unsuspend!`, and `suspended_by` methods to User model.

2. **Block Suspended Users (6.2)**: Added suspension checks in both OAuth callback (`sessions_controller.rb:205-210`) and application controller via `check_user_suspension` before_action. Suspended users are immediately logged out and shown a 403 page explaining their suspension.

3. **Security Audit Logging (6.3)**: Added `log_user_suspended`, `log_user_unsuspended`, and `log_suspended_login_attempt` methods to SecurityAuditLog.

4. **Admin UI (6.4)**: Created user management pages at `/admin/users` and `/admin/users/:handle`. HTML and Markdown views show user list with suspension badges, user details with suspend/unsuspend actions. Self-suspension is prevented.

5. **Markdown API Actions (6.5)**: Added routes and action definitions for `suspend_user` and `unsuspend_user` actions in actions_helper.rb.

**Files modified:**
- `db/migrate/20260128072608_add_suspension_to_users.rb` (new)
- `app/models/user.rb`
- `app/controllers/sessions_controller.rb`
- `app/controllers/application_controller.rb`
- `app/controllers/admin_controller.rb`
- `app/services/security_audit_log.rb`
- `app/services/actions_helper.rb`
- `config/routes.rb`
- `app/views/admin/users.html.erb` (new)
- `app/views/admin/users.md.erb` (new)
- `app/views/admin/show_user.html.erb` (new)
- `app/views/admin/show_user.md.erb` (new)
- `app/views/sessions/403_suspended.html.erb` (new)

**Tests added:**
- User model suspension tests in `test/models/user_test.rb`
- Admin controller suspension tests in `test/controllers/admin_controller_test.rb`
- Authentication security suspension tests in `test/integration/authentication_security_test.rb`

### Current State

| Level | Suspension Field | Location | UI |
|-------|------------------|----------|-----|
| Tenant | `suspended_at`, `suspended_reason` | `app/models/tenant.rb` | AppAdmin API only |
| User | None | N/A | None |

Tenant suspension exists for the AppAdmin API (used for billing/payment issues), but there is no user-level suspension that tenant admins can use to manage problematic users within their tenant.

---

### 6.1 Add User Suspension Fields

**Risk Level**: Low
**Effort**: Low
**Location**: New migration, `app/models/user.rb`

**Migration**:
```ruby
class AddSuspensionToUsers < ActiveRecord::Migration[7.0]
  def change
    add_column :users, :suspended_at, :datetime
    add_column :users, :suspended_by_id, :uuid
    add_column :users, :suspended_reason, :string
    add_index :users, :suspended_at
  end
end
```

**Model Methods** (in `user.rb`):
```ruby
def suspended?
  suspended_at.present?
end

def suspend!(by:, reason:)
  update!(
    suspended_at: Time.current,
    suspended_by_id: by.id,
    suspended_reason: reason
  )
end

def unsuspend!
  update!(
    suspended_at: nil,
    suspended_by_id: nil,
    suspended_reason: nil
  )
end
```

**Testing**:
- [x] Verify `suspended?` returns correct boolean
- [x] Verify `suspend!` sets all fields
- [x] Verify `unsuspend!` clears all fields

---

### 6.2 Block Suspended Users from Login

**Risk Level**: Medium
**Effort**: Low
**Location**: `app/controllers/sessions_controller.rb`, `app/controllers/application_controller.rb`

**Problem**: Suspended users should not be able to access the application.

**Solution**: Add suspension check to authentication flow.

1. In `sessions_controller.rb` (OAuth callback):
```ruby
# After finding the user
if user.suspended?
  SecurityAuditLog.log_suspended_login_attempt(user: user, ip: request.remote_ip)
  flash[:alert] = "Your account has been suspended. Please contact the administrator."
  redirect_to "/login"
  return
end
```

2. In `application_controller.rb` (for already-logged-in users):
```ruby
before_action :check_user_suspension

def check_user_suspension
  return unless current_user&.suspended?
  reset_session
  redirect_to "/login", alert: "Your account has been suspended."
end
```

**Testing**:
- [x] Verify suspended user cannot log in
- [x] Verify suspended user is logged out if already in session
- [x] Verify suspension is logged to security audit log
- [x] Verify appropriate error message is shown

---

### 6.3 Add Security Audit Logging

**Risk Level**: Low
**Effort**: Low
**Location**: `app/services/security_audit_log.rb`

**Add new event types**:
```ruby
def self.log_user_suspended(user:, suspended_by:, reason:, ip:)
  log(
    event: "user_suspended",
    user_email: user.email,
    user_id: user.id,
    suspended_by_email: suspended_by.email,
    suspended_by_id: suspended_by.id,
    reason: reason,
    ip: ip
  )
end

def self.log_user_unsuspended(user:, unsuspended_by:, ip:)
  log(
    event: "user_unsuspended",
    user_email: user.email,
    user_id: user.id,
    unsuspended_by_email: unsuspended_by.email,
    unsuspended_by_id: unsuspended_by.id,
    ip: ip
  )
end

def self.log_suspended_login_attempt(user:, ip:)
  log(
    event: "suspended_login_attempt",
    user_email: user.email,
    user_id: user.id,
    ip: ip
  )
end
```

**Testing**:
- [x] Verify suspension events appear in security dashboard
- [x] Verify login attempts by suspended users are logged

---

### 6.4 Admin UI for User Management

**Risk Level**: Low
**Effort**: Medium
**Location**: `app/controllers/admin_controller.rb`, new views

**New Routes** (in `config/routes.rb`):
```ruby
# Within admin routes
get '/admin/users', to: 'admin#users'
get '/admin/users/:handle', to: 'admin#show_user'
post '/admin/users/:handle/suspend', to: 'admin#suspend_user'
post '/admin/users/:handle/unsuspend', to: 'admin#unsuspend_user'
```

**Controller Actions** (in `admin_controller.rb`):
```ruby
def users
  @page_title = 'Users'
  @users = @current_tenant.users.includes(:tenant_users)
  respond_to do |format|
    format.html
    format.md
  end
end

def show_user
  @user = @current_tenant.users.find_by!(handle: params[:handle])
  @page_title = @user.display_name
  respond_to do |format|
    format.html
    format.md
  end
end

def suspend_user
  user = @current_tenant.users.find_by!(handle: params[:handle])

  # Prevent self-suspension
  if user.id == @current_user.id
    flash[:alert] = "You cannot suspend your own account."
    redirect_to admin_user_path(user.handle)
    return
  end

  # Prevent suspending other admins (optional policy decision)
  if @current_tenant.is_admin?(user) && !is_main_tenant?
    flash[:alert] = "Only platform admins can suspend tenant admins."
    redirect_to admin_user_path(user.handle)
    return
  end

  user.suspend!(by: @current_user, reason: params[:reason])
  SecurityAuditLog.log_user_suspended(
    user: user,
    suspended_by: @current_user,
    reason: params[:reason],
    ip: request.remote_ip
  )

  flash[:notice] = "User #{user.display_name} has been suspended."
  redirect_to admin_user_path(user.handle)
end

def unsuspend_user
  user = @current_tenant.users.find_by!(handle: params[:handle])

  user.unsuspend!
  SecurityAuditLog.log_user_unsuspended(
    user: user,
    unsuspended_by: @current_user,
    ip: request.remote_ip
  )

  flash[:notice] = "User #{user.display_name} has been unsuspended."
  redirect_to admin_user_path(user.handle)
end
```

**Views** (new files):
- `app/views/admin/users.html.erb` - List of users with suspension status badges
- `app/views/admin/users.md.erb` - Markdown version for LLM
- `app/views/admin/show_user.html.erb` - User details with suspend/unsuspend actions
- `app/views/admin/show_user.md.erb` - Markdown version for LLM

**UI Elements**:
- User list shows suspension status badge (red "SUSPENDED" badge)
- User detail page shows:
  - Suspended status with reason and date
  - Who suspended the user
  - Suspend button (with reason field) for active users
  - Unsuspend button for suspended users
- Confirmation dialog before suspension

**Testing**:
- [x] Verify user list shows all tenant users
- [x] Verify suspension status badge appears
- [x] Verify suspend action works with reason
- [x] Verify unsuspend action works
- [x] Verify self-suspension is prevented
- [x] Verify admin suspension policy is enforced
- [x] Verify markdown API works

---

### 6.5 Add Markdown API Actions

**Risk Level**: Low
**Effort**: Low
**Location**: `app/controllers/admin_controller.rb`, `config/routes.rb`

**Routes**:
```ruby
# Markdown API actions for user management
get '/admin/users/:handle/actions', to: 'admin#actions_index_user'
get '/admin/users/:handle/actions/suspend_user', to: 'admin#describe_suspend_user'
post '/admin/users/:handle/actions/suspend_user', to: 'admin#execute_suspend_user'
get '/admin/users/:handle/actions/unsuspend_user', to: 'admin#describe_unsuspend_user'
post '/admin/users/:handle/actions/unsuspend_user', to: 'admin#execute_unsuspend_user'
```

**Action Definitions** (in `app/services/actions_helper.rb`):
```ruby
{
  "suspend_user" => {
    description: "Suspend a user account, preventing them from logging in",
    params: {
      reason: { type: "string", required: true, description: "Reason for suspension" }
    }
  },
  "unsuspend_user" => {
    description: "Unsuspend a user account, allowing them to log in again",
    params: {}
  }
}
```

**Testing**:
- [x] Verify LLM can list available actions
- [x] Verify LLM can describe suspend action
- [x] Verify LLM can execute suspend action
- [x] Verify LLM can execute unsuspend action

---

### 6.6 Email Notifications (Optional Enhancement)

**Risk Level**: Low
**Effort**: Medium
**Location**: New mailer

**Problem**: Users may not know why they can't log in.

**Solution**: Send email notification when suspended/unsuspended.

```ruby
# app/mailers/user_suspension_mailer.rb
class UserSuspensionMailer < ApplicationMailer
  def suspended(user:, reason:, tenant:)
    @user = user
    @reason = reason
    @tenant = tenant
    mail(to: user.email, subject: "Your account has been suspended")
  end

  def unsuspended(user:, tenant:)
    @user = user
    @tenant = tenant
    mail(to: user.email, subject: "Your account has been reactivated")
  end
end
```

**Testing**:
- [ ] Verify email is sent on suspension
- [ ] Verify email is sent on unsuspension
- [ ] Verify email contains correct information

---

### Phase 6 Implementation Order

| Priority | Item | Effort | Risk | Status |
|----------|------|--------|------|--------|
| 1 | 6.1 User Suspension Fields | Low | Low | Pending |
| 2 | 6.2 Block Suspended Users | Low | Medium | Pending |
| 3 | 6.3 Security Audit Logging | Low | Low | Pending |
| 4 | 6.4 Admin UI | Medium | Low | Pending |
| 5 | 6.5 Markdown API Actions | Low | Low | Pending |
| 6 | 6.6 Email Notifications | Medium | Low | Future/Optional |

---

### Phase 6 Files to Create/Modify

| File | Changes |
|------|---------|
| `db/migrate/XXXXXX_add_suspension_to_users.rb` | New migration |
| `app/models/user.rb` | Add suspension methods |
| `app/controllers/sessions_controller.rb` | Block suspended login |
| `app/controllers/application_controller.rb` | Check suspension on requests |
| `app/controllers/admin_controller.rb` | User management actions |
| `app/services/security_audit_log.rb` | New event types |
| `app/services/actions_helper.rb` | New action definitions |
| `config/routes.rb` | New admin routes |
| `app/views/admin/users.html.erb` | New view |
| `app/views/admin/users.md.erb` | New view |
| `app/views/admin/show_user.html.erb` | New view |
| `app/views/admin/show_user.md.erb` | New view |
| `test/controllers/admin_controller_test.rb` | User suspension tests |
| `test/models/user_test.rb` | Suspension method tests |

---

## References

- [OWASP Session Management Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Session_Management_Cheat_Sheet.html)
- [OWASP Authentication Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Authentication_Cheat_Sheet.html)
- [OWASP API Security Top 10](https://owasp.org/API-Security/editions/2023/en/0x00-header/)
- [NIST Digital Identity Guidelines](https://pages.nist.gov/800-63-3/)
- [Rails Security Guide](https://guides.rubyonrails.org/security.html)
