# Auth-flow bot defenses (honeypot + rate limit + Turnstile)

## Context

The signup invite gate ([app/controllers/signup_controller.rb](../../app/controllers/signup_controller.rb)) accepts an invite code from anyone who can complete OAuth. The code-submit form (`POST /needs-invite`) is the most attractive bot target on the site: success grants tenant membership, and a sufficiently determined attacker can brute-force short or guessable invite codes. None of the auth-flow forms (signup, identity login, identity register, password reset) currently have honeypot fields or Turnstile challenges. Most have IP-based rate limits in [config/initializers/rack_attack.rb](../../config/initializers/rack_attack.rb), but `POST /needs-invite` does not.

Bot defenses to add, in increasing UX cost:

1. **Rate limits (Rack::Attack)** — server-side, mandatory backstop. Cheap, no UX impact.
2. **Honeypot field** — invisible input + min-time-to-submit. Catches naive bots. Zero UX cost for humans.
3. **Cloudflare Turnstile** — managed challenge before submit. Catches sophisticated bots. Small UX cost, dev/test no-op.

Scope (per user's decisions in chat):
- Apply to **all auth-flow forms**, not just signup.
- Turnstile uses **global ENV keys** (`TURNSTILE_SITE_KEY`, `TURNSTILE_SECRET_KEY`); no-op when unset (so dev/test/CI just work).
- Rate limit `POST /needs-invite` at **5/hour per IP + 10/hour per user**.

## Forms in scope

| Path | Method | Controller | Why protect |
|------|--------|------------|-------------|
| `/needs-invite` | POST | `Signup#confirm_invite` | Invite-code brute force |
| `/needs-invite/accept` | POST | `Signup#accept_invite` | Final tenant join |
| `/auth/identity/register` | POST | OmniAuth middleware → `OmniAuthIdentitiesController#failed_registration` on failure | Mass account creation |
| `/auth/identity/callback` | POST | OmniAuth middleware → `Sessions#oauth_callback` | Credential stuffing |
| `/password` (new reset) | POST | `PasswordResets#create` | Email enumeration / spam |
| `/password/reset/:token` | PATCH | `PasswordResets#update` | Token brute force |
| `/login/verify-2fa` | POST | `TwoFactorAuth#verify_submit` | 2FA code brute force |

OAuth-provider callbacks (Google, etc.) are redirects from the provider, not forms — they get rate limits only.

## Approach

Three layered defenses with **rack_attack** as the always-on backstop, **honeypot** as the zero-cost catch for unsophisticated bots, and **Turnstile** as the production-only challenge for everything else. The Turnstile and honeypot logic is shared via a single `BotProtection` concern, so each protected form is one before_action away from coverage.

A Rack middleware fronts the two OmniAuth-handled endpoints (`/auth/identity/register`, `/auth/identity/callback`) because those POSTs are consumed by middleware before any Rails controller runs. Everything else uses the concern directly.

## Changes

### 1. Rate limits — Rack::Attack

**File:** [config/initializers/rack_attack.rb](../../config/initializers/rack_attack.rb)

Add new throttles:

```ruby
# Invite-code submission: tight enough to make code brute-force impractical.
throttle('needs-invite/ip', limit: 5, period: 1.hour) do |req|
  req.ip if req.path == '/needs-invite' && req.post?
end

# Per-user backstop. A legitimate user fat-fingering their code 2-3 times is
# fine; 10/hour cuts off a bot that rotates IPs but uses one session.
throttle('needs-invite/user', limit: 10, period: 1.hour) do |req|
  if req.path == '/needs-invite' && req.post?
    req.env['rack.session']&.dig('user_id')
  end
end

# Final-join is already gated by a valid code from the previous step, but
# rate-limit it anyway to backstop session-hijack scenarios.
throttle('accept-invite/ip', limit: 10, period: 1.hour) do |req|
  req.ip if req.path == '/needs-invite/accept' && req.post?
end

# Identity registration — currently only the generic writes/ip throttle.
throttle('identity-register/ip', limit: 5, period: 1.hour) do |req|
  req.ip if req.path == '/auth/identity/register' && req.post?
end
```

The existing `req/ip` (300/min) and `writes/ip` (60/min) throttles already cover the broader request shape. These new throttles add tighter per-endpoint caps where the value-per-request is highest.

### 2. `BotProtection` concern

**File:** `app/controllers/concerns/bot_protection.rb` (new)

```ruby
# typed: true
module BotProtection
  extend ActiveSupport::Concern

  HONEYPOT_FIELD = "company_website".freeze  # plausible-but-irrelevant name
  HONEYPOT_TIMESTAMP_FIELD = "form_render_ts".freeze
  MIN_FORM_TIME_SECONDS = 2

  class_methods do
    # before_action :protect_from_bots, only: [:create]
    def protect_from_bots(**opts)
      before_action :run_bot_protection, **opts
    end
  end

  private

  def run_bot_protection
    return if bot_protection_disabled?

    if honeypot_failed? || submitted_too_fast?
      log_bot_signal(reason: "honeypot")
      redirect_back_on_bot_detected
      return
    end

    if turnstile_enabled? && !TurnstileVerifier.verify(token: params[:cf_turnstile_response], ip: request.remote_ip)
      log_bot_signal(reason: "turnstile")
      flash[:alert] = "We couldn't verify that you're human. Please try again."
      redirect_back_on_bot_detected
      nil
    end
  end

  def honeypot_failed?
    params[HONEYPOT_FIELD].to_s.present?
  end

  def submitted_too_fast?
    ts = params[HONEYPOT_TIMESTAMP_FIELD].to_s
    return false if ts.blank?  # missing => render path didn't set it; don't penalize
    rendered_at = Time.zone.at(ts.to_i) rescue nil
    return false if rendered_at.nil?
    Time.current - rendered_at < MIN_FORM_TIME_SECONDS
  end

  def turnstile_enabled?
    ENV["TURNSTILE_SECRET_KEY"].present?
  end

  def bot_protection_disabled?
    Rails.env.test? && ENV["FORCE_BOT_PROTECTION_IN_TEST"].blank?
  end

  def redirect_back_on_bot_detected
    flash[:alert] ||= "Submission could not be processed. Please try again."
    redirect_back(fallback_location: "/login")
  end

  def log_bot_signal(reason:)
    SecurityAuditLog.log_bot_signal(
      ip: request.remote_ip,
      path: request.path,
      reason: reason,
      user_id: session[:user_id],
    ) if defined?(SecurityAuditLog) && SecurityAuditLog.respond_to?(:log_bot_signal)
  end
end
```

Notes:
- Silent fail (redirect_back with generic flash) — do not tell a bot which signal tripped.
- `submitted_too_fast?` only fires when the timestamp field was rendered. A bot omitting the timestamp would fail the honeypot, so we don't need to penalize a missing timestamp.
- `bot_protection_disabled?` lets tests opt into the protection with `ENV["FORCE_BOT_PROTECTION_IN_TEST"]` for the unit tests of this concern; everywhere else it's a no-op in test.

### 3. `TurnstileVerifier` service

**File:** `app/services/turnstile_verifier.rb` (new)

```ruby
# typed: true
class TurnstileVerifier
  VERIFY_URL = "https://challenges.cloudflare.com/turnstile/v0/siteverify".freeze
  TIMEOUT_SECONDS = 3

  sig { params(token: T.nilable(String), ip: T.nilable(String)).returns(T::Boolean) }
  def self.verify(token:, ip:)
    return true if ENV["TURNSTILE_SECRET_KEY"].blank?  # disabled
    return false if token.blank?

    res = Net::HTTP.post_form(
      URI(VERIFY_URL),
      "secret" => ENV["TURNSTILE_SECRET_KEY"],
      "response" => token,
      "remoteip" => ip,
    )
    JSON.parse(res.body).fetch("success", false) == true
  rescue StandardError => e
    Rails.logger.warn("[TurnstileVerifier] verify failed: #{e.class}: #{e.message}")
    false  # fail closed — if Cloudflare is unreachable, reject the submission
  end
end
```

Fail-closed on network errors is the right call: a bot author can DoS our Turnstile dependency and bypass the check if we fail-open. Cloudflare's siteverify SLO is high enough that real-user impact should be negligible; we'll watch the logs.

### 4. Honeypot + Turnstile partials

**File:** `app/views/shared/_bot_protection_fields.html.erb` (new)

```erb
<%# Honeypot — hidden via off-screen positioning AND aria-hidden so screen readers skip it. %>
<div style="position:absolute;left:-9999px;width:1px;height:1px;overflow:hidden;" aria-hidden="true">
  <label for="company_website">Leave this field empty</label>
  <input type="text" name="company_website" id="company_website" tabindex="-1" autocomplete="off">
</div>
<input type="hidden" name="form_render_ts" value="<%= Time.current.to_i %>">
```

**File:** `app/views/shared/_turnstile_widget.html.erb` (new)

```erb
<% if ENV["TURNSTILE_SITE_KEY"].present? %>
  <script src="https://challenges.cloudflare.com/turnstile/v0/api.js" async defer></script>
  <div class="cf-turnstile" data-sitekey="<%= ENV["TURNSTILE_SITE_KEY"] %>" data-response-field-name="cf_turnstile_response" style="margin: 16px 0;"></div>
<% end %>
```

### 5. Per-form wiring

For each controller, add the concern + before_action and update the view to render the partials.

**[app/controllers/signup_controller.rb](../../app/controllers/signup_controller.rb)** — add:

```ruby
include BotProtection
protect_from_bots only: [:confirm_invite, :accept_invite]
```

**[app/controllers/password_resets_controller.rb](../../app/controllers/password_resets_controller.rb)** — add:

```ruby
include BotProtection
protect_from_bots only: [:create, :update]
```

**[app/controllers/two_factor_auth_controller.rb](../../app/controllers/two_factor_auth_controller.rb)** — add:

```ruby
include BotProtection
protect_from_bots only: [:verify_submit]
```

Honeypot only on 2FA — skip Turnstile to avoid double-friction after the user just authenticated; the existing rack_attack throttle handles brute force. (Implement by adding an option `protect_from_bots only: [:verify_submit], turnstile: false` and threading the flag into `run_bot_protection`.)

**Views to update** (insert `<%= render "shared/bot_protection_fields" %>` and `<%= render "shared/turnstile_widget" %>` inside the form tag):
- [app/views/signup/needs_invite.html.erb](../../app/views/signup/needs_invite.html.erb)
- [app/views/signup/confirm_invite.html.erb](../../app/views/signup/confirm_invite.html.erb) — the accept-invite form
- [app/views/password_resets/new.html.erb](../../app/views/password_resets/new.html.erb)
- [app/views/password_resets/show.html.erb](../../app/views/password_resets/show.html.erb)
- [app/views/two_factor_auth/verify.html.erb](../../app/views/two_factor_auth/verify.html.erb) — honeypot only
- [app/views/omni_auth_identities/_email_password_form.html.erb](../../app/views/omni_auth_identities/_email_password_form.html.erb)
- [app/views/omni_auth_identities/new.html.erb](../../app/views/omni_auth_identities/new.html.erb)

### 6. Rack middleware for OmniAuth endpoints

`POST /auth/identity/callback` and `POST /auth/identity/register` are consumed by OmniAuth middleware before any Rails controller runs, so the concern can't intercept them. Add a small middleware that runs *before* OmniAuth.

**File:** `app/middleware/omni_auth_bot_protection.rb` (new)

```ruby
# typed: true
class OmniAuthBotProtection
  PROTECTED_PATHS = %w[/auth/identity/register /auth/identity/callback].freeze

  def initialize(app)
    @app = app
  end

  def call(env)
    req = Rack::Request.new(env)
    return @app.call(env) unless req.post? && PROTECTED_PATHS.include?(req.path)
    return @app.call(env) if disabled?

    if honeypot_failed?(req) || (turnstile_enabled? && !TurnstileVerifier.verify(token: req.params["cf_turnstile_response"], ip: req.ip))
      SecurityAuditLog.log_bot_signal(ip: req.ip, path: req.path, reason: "middleware", user_id: nil) if defined?(SecurityAuditLog)
      return [302, { "Location" => req.path == "/auth/identity/register" ? "/auth/identity/register" : "/login", "Content-Type" => "text/html" }, ["Bot check failed"]]
    end

    @app.call(env)
  end

  private

  def honeypot_failed?(req)
    req.params["company_website"].to_s.present?
  end

  def turnstile_enabled?
    ENV["TURNSTILE_SECRET_KEY"].present?
  end

  def disabled?
    Rails.env.test? && ENV["FORCE_BOT_PROTECTION_IN_TEST"].blank?
  end
end
```

**File:** `config/application.rb` — register the middleware *before* `OmniAuth::Builder`:

```ruby
config.middleware.insert_before OmniAuth::Builder, OmniAuthBotProtection
```

(Verify the exact existing insertion point — there may already be `config.middleware.use OmniAuth::Builder`. If OmniAuth is added by an engine, use `insert_before` with the right key.)

### 7. Update audit log

**File:** [app/services/security_audit_log.rb](../../app/services/security_audit_log.rb) — add:

```ruby
sig { params(ip: T.nilable(String), path: String, reason: String, user_id: T.nilable(Integer)).void }
def self.log_bot_signal(ip:, path:, reason:, user_id:)
  log_event(
    event: "bot_signal_detected",
    ip: ip,
    metadata: { path: path, reason: reason, user_id: user_id },
  )
end
```

(Confirm the existing helper signatures and match them — this is illustrative.)

### 8. Env vars

**File:** `.env.example` — add:

```
TURNSTILE_SITE_KEY=
TURNSTILE_SECRET_KEY=
```

Document the no-op behavior: leave both blank in development and test; populate in production via the existing secret-management workflow.

## Tests

### `test/services/turnstile_verifier_test.rb` (new)
- Returns `true` when `TURNSTILE_SECRET_KEY` is blank (disabled mode).
- Returns `false` when token is blank.
- POSTs to siteverify with secret + token + remoteip; returns response.success.
- Returns `false` (fail-closed) on network error.
- Stub Net::HTTP via Mocha or WebMock.

### `test/controllers/concerns/bot_protection_test.rb` (new)
Use a stub controller that includes the concern. Set `ENV["FORCE_BOT_PROTECTION_IN_TEST"]=1` in the test setup.
- Submitting with empty honeypot + plausible timestamp → passes through.
- Submitting with filled honeypot → redirects back, logs `reason: "honeypot"`.
- Submitting with timestamp < 2s ago → redirects back.
- Submitting with no timestamp → does NOT trip the time check.
- With `TURNSTILE_SECRET_KEY` set and `TurnstileVerifier` stubbed to return false → redirects back, logs `reason: "turnstile"`.
- With `TURNSTILE_SECRET_KEY` unset → does not call verifier.

### `test/controllers/signup_controller_test.rb` (extend)
- `POST /needs-invite` with filled honeypot → redirects, no invite lookup performed.
- `POST /needs-invite/accept` with filled honeypot → redirects, no tenant join.
- Both run with `FORCE_BOT_PROTECTION_IN_TEST=1`; the existing happy-path tests stay green because the concern is a no-op without that env.

### `test/controllers/password_resets_controller_test.rb` (extend)
- `POST /password` with honeypot tripped → redirects without sending reset email.
- `PATCH /password/reset/:token` with honeypot tripped → redirects without updating password.

### `test/integration/omni_auth_bot_protection_test.rb` (new)
- `POST /auth/identity/register` with filled honeypot → 302, no `OmniAuthIdentity.create` call.
- `POST /auth/identity/callback` with filled honeypot → 302, no session creation.
- Both with empty honeypot → reach OmniAuth.
- Run with `FORCE_BOT_PROTECTION_IN_TEST=1`.

### `test/controllers/rack_attack_test.rb` or inline in [test/controllers/user_data_exports_controller_test.rb](../../test/controllers/user_data_exports_controller_test.rb) pattern
- Assert `needs-invite/ip`, `needs-invite/user`, `accept-invite/ip`, `identity-register/ip` throttles are registered (the existing test uses `Rack::Attack.throttles[...]`).
- Functional throttle test: 6 POSTs to `/needs-invite` from the same IP → 6th gets 429.

## Verification

1. Write tests first (red-green). Run targeted files:
   ```bash
   docker compose exec web bundle exec rails test \
     test/services/turnstile_verifier_test.rb \
     test/controllers/concerns/bot_protection_test.rb \
     test/controllers/signup_controller_test.rb \
     test/integration/omni_auth_bot_protection_test.rb
   ```
2. Manual smoke (in Docker, with `TURNSTILE_SITE_KEY`/`TURNSTILE_SECRET_KEY` set to Cloudflare test keys):
   - Submit `/needs-invite` normally → success.
   - Fill honeypot via devtools → redirect with generic flash, no code lookup in logs.
   - Submit `/needs-invite` 6× from the same IP → 429 on the 6th (rack_attack).
   - Turn off `TURNSTILE_SITE_KEY` → widget disappears, form still works, server-side check is a no-op.
3. Run [scripts/check-tenant-safety.sh](../../scripts/check-tenant-safety.sh) + RuboCop + Sorbet.
4. CI runs full suite.

## Out of scope (deferred)

- Per-tenant Turnstile keys (would need an admin UI).
- Behavioral / device-fingerprint signals (more invasive, higher false-positive risk).
- Phone or SMS verification (heavy friction; revisit if invite-code abuse continues despite Turnstile).
- Tightening 2FA verify with Turnstile (intentionally skipped — already gated by password + tight rack_attack).
- Surfacing rate-limit hits in admin UI (today they only go to `SecurityAuditLog`).

## Files to add / modify

| File | Change |
|------|--------|
| `config/initializers/rack_attack.rb` | Add 4 new throttles |
| `app/controllers/concerns/bot_protection.rb` | NEW — shared concern |
| `app/services/turnstile_verifier.rb` | NEW — Cloudflare siteverify wrapper |
| `app/middleware/omni_auth_bot_protection.rb` | NEW — pre-OmniAuth middleware |
| `config/application.rb` | Register the middleware before OmniAuth::Builder |
| `app/views/shared/_bot_protection_fields.html.erb` | NEW — honeypot + timestamp |
| `app/views/shared/_turnstile_widget.html.erb` | NEW — conditional widget |
| `app/services/security_audit_log.rb` | Add `log_bot_signal` |
| `app/controllers/signup_controller.rb` | Include concern, protect 2 actions |
| `app/controllers/password_resets_controller.rb` | Include concern, protect 2 actions |
| `app/controllers/two_factor_auth_controller.rb` | Include concern, protect verify_submit (honeypot only) |
| `app/views/signup/needs_invite.html.erb` | Render partials inside form |
| `app/views/signup/confirm_invite.html.erb` | Render partials inside form |
| `app/views/password_resets/new.html.erb` | Render partials |
| `app/views/password_resets/show.html.erb` | Render partials |
| `app/views/two_factor_auth/verify.html.erb` | Render honeypot only |
| `app/views/omni_auth_identities/_email_password_form.html.erb` | Render partials |
| `app/views/omni_auth_identities/new.html.erb` | Render partials |
| `.env.example` | Document `TURNSTILE_*` env vars |
| `test/services/turnstile_verifier_test.rb` | NEW |
| `test/controllers/concerns/bot_protection_test.rb` | NEW |
| `test/integration/omni_auth_bot_protection_test.rb` | NEW |
| `test/controllers/signup_controller_test.rb` | Extend with honeypot cases |
| `test/controllers/password_resets_controller_test.rb` | Extend with honeypot cases |
| Rack::Attack throttle test (extend existing pattern) | Assert new throttles are registered |
