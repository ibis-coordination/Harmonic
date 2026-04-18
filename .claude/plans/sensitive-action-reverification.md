# Sensitive Action Re-verification

## Status

In progress. First consumer: admin panel access hardening.

## Problem

Some actions are sensitive enough to warrant proving the user is still
who they say they are, even within an active session. Examples:

- Accessing admin panels (sys_admin, app_admin, tenant_admin)
- Changing email address
- Changing password or disabling 2FA
- Creating or revoking API tokens
- Deleting an account or collective

A compromised session (e.g., stolen cookie, unattended browser) shouldn't
grant free access to these operations. The industry-standard mitigation
is **step-up authentication**: require the user to re-verify their
identity before proceeding.

## Key discovery

Every user — including GitHub OAuth users — already has an
`OmniAuthIdentity` record (created at OAuth login to reserve the email).
This record has all the OTP fields (`otp_secret`, `otp_enabled`, etc.).
So any user can set up TOTP, and the existing setup flow works for
everyone. No model changes are needed.

## Design

### Core abstraction: `RequiresReverification`

A controller concern that checks whether the user has recently verified
their identity via TOTP. Agnostic to what the protected resource is —
any controller can include it and gate any action.

### Scoped timestamps

Re-verification is **scoped** so that verifying for one purpose doesn't
satisfy a different purpose. Each consumer specifies a scope name:

```ruby
before_action -> { require_reverification(scope: "admin") }
before_action -> { require_reverification(scope: "destructive") }, only: [:destroy]
```

Session keys are `session[:reverified_at_<scope>]`. A verification for
scope "admin" does not satisfy scope "destructive" and vice versa.

**Timeout:** Configurable via `REVERIFICATION_TIMEOUT` env var (default
1 hour / 3600 seconds). Shared across all scopes — the window length
is the same, but the timestamps are independent.

### Flow

1. User hits a controller action protected by `require_reverification`
2. Concern checks `session[:reverified_at_<scope>]`:
   - Present and within timeout → allow
   - Missing or expired → store return URL and scope in session,
     redirect to `/reverify`
3. If user has no 2FA set up → redirect to 2FA setup page with flash
   explaining that 2FA is required for this action
4. User enters TOTP code at `/reverify`
5. On success: stamp `session[:reverified_at_<scope>]`, redirect to
   stored return URL
6. On failure: show error with retry (lockout follows existing OTP
   lockout rules on `OmniAuthIdentity`)

### What it skips

- **API token requests:** Tokens are already a separate credential.
  The concern checks `api_token_present?` and skips.
- **Users without a session:** No session = no re-verification needed
  (they'll hit login first).

## Implementation

### Files to create

**`app/controllers/concerns/requires_reverification.rb`**

```ruby
module RequiresReverification
  extend ActiveSupport::Concern

  private

  def require_reverification(scope: "default")
    return if api_token_present?

    identity = current_user&.omni_auth_identity
    unless identity&.otp_enabled
      flash[:alert] = "Two-factor authentication is required for this action."
      redirect_to two_factor_setup_path
      return
    end

    session_key = :"reverified_at_#{scope}"
    timeout = ENV.fetch("REVERIFICATION_TIMEOUT", 3600).to_i
    verified_at = session[session_key]

    if verified_at.present? && Time.at(verified_at) > timeout.seconds.ago
      return # recently verified
    end

    session[:reverification_return_to] = request.original_url
    session[:reverification_scope] = scope
    redirect_to reverify_path
  end
end
```

**`app/controllers/reverification_controller.rb`**
- Inherits from `ApplicationController`
- `is_auth_controller?` returns `true` (bypasses collective membership checks)
- `show` — renders TOTP code entry form, shows lockout state if locked
- `verify` — validates TOTP via `identity.verify_otp(code)`, stamps
  scoped session key, redirects to return URL
- Logs success/failure to `SecurityAuditLog`

**`app/views/reverification/show.html.erb`**
Simple TOTP code entry form following existing 2FA verify page styling.
Shows the scope context ("You're accessing: Admin Panel") if available.

### Files to modify

**`config/routes.rb`**
```ruby
get 'reverify' => 'reverification#show'
post 'reverify' => 'reverification#verify'
```

**`app/services/security_audit_log.rb`**
Add `log_reverification_success` and `log_reverification_failure`.

**Admin controllers (first consumer):**
```ruby
# system_admin_controller.rb, app_admin_controller.rb
include RequiresReverification
before_action -> { require_reverification(scope: "admin") }
```

### Tests

**`test/controllers/concerns/requires_reverification_test.rb`**
- No `reverified_at_<scope>` → redirects to `/reverify`
- Fresh timestamp within timeout → allows access
- Expired timestamp → redirects to `/reverify`
- API token request → skips re-verification
- User without 2FA → redirects to 2FA setup
- Different scopes have independent timestamps
- Custom timeout via env var

**`test/controllers/reverification_controller_test.rb`**
- GET `/reverify` renders form
- POST with valid TOTP → stamps session, redirects to return URL
- POST with invalid TOTP → shows error, stays on page
- POST when locked out → shows lockout message
- Unauthenticated user → redirects to login

## Future consumers

Each just adds a `before_action` with the appropriate scope:
- Email change: `scope: "email_change"`
- 2FA disable: `scope: "security_settings"`
- Account deletion: `scope: "destructive"`
- API token creation: `scope: "api_tokens"`

## Non-goals

- Password confirmation as an alternative to TOTP (future enhancement)
- Per-scope timeout configuration (single global timeout is sufficient)
- WebAuthn/passkey support (future enhancement)
- Re-verification for AI agents (token auth, not sessions)
