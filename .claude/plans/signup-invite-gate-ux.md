# Signup Invite-Gate UX

## Context

Signup is gated by collective invites. When a user authenticates via OAuth without a valid invite cookie, they get dropped on a generic "Access Denied" page ([app/views/sessions/403_to_logout.html.erb](../../app/views/sessions/403_to_logout.html.erb)) with no explanation of *why* they're blocked, no way to enter a code they might have, and no path forward. Their `User` and `OauthIdentity` records are created and then orphaned.

Three problems:

1. The 403 page is opaque — no mention of invites, no input affordance, no recovery path.
2. The `require_invite` tenant setting is defined ([tenant.rb:110](../../app/models/tenant.rb#L110)) but never read; the gate is hardcoded.
3. The invite-code memory mechanism (cookie set at [sessions_controller.rb:163](../../app/controllers/sessions_controller.rb#L163), read at [sessions_controller.rb:218](../../app/controllers/sessions_controller.rb#L218)) is load-bearing but has no end-to-end test for the unauth-user-clicks-invite-link → OAuth → join-collective path.

Orphan accounts will be kept as "pending" (no `TenantUser`) — recoverable later when the user returns with an invite. No new state machine is needed; the existing absence of `TenantUser` already represents this.

Self-serve tenant creation is **out of scope**.

## Approach

1. Replace the no-invite 403 path with a real "needs invite" page that explains the situation and accepts an invite code via a form.
2. Wire `Tenant#require_invite?` so the existing setting is enforced. When false, an authenticated user with no `tenant_user` is admitted and added to the tenant via the existing lazy creation in [application_controller.rb:469](../../app/controllers/application_controller.rb#L469).
3. Backfill the missing end-to-end test for invite-cookie survival across the OAuth round-trip, since we are now leaning on it as a documented affordance.

## Changes

### 1. `Tenant#require_invite?`

**File:** `app/models/tenant.rb`

Add a reader matching the `require_login?` pattern at [tenant.rb:304](../../app/models/tenant.rb#L304):

```ruby
sig { returns(T::Boolean) }
def require_invite?
  settings['require_invite'].to_s == 'false' ? false : true
end
```

Default-true matches the schema default at [tenant.rb:110](../../app/models/tenant.rb#L110) and preserves today's behavior.

No admin UI for toggling this in this PR — wiring the setting is enough to unblock the open-tenant case and tidy the dead code. A toggle UI can come later.

### 2. Gate logic — sessions controller

**File:** `app/controllers/sessions_controller.rb`

At [sessions_controller.rb:217-228](../../app/controllers/sessions_controller.rb#L217-L228), change the gate to respect `require_invite?` and redirect (not render) to the new explainer when blocked:

```ruby
tenant_user = tenant.tenant_users.find_by(user: @current_user)
is_accepting_invite = cookies[:collective_invite_code].present?
if tenant_user || is_accepting_invite || !tenant.require_invite?
  session[:user_id] = @current_user.id
  session[:logged_in_at] = Time.current.to_i
  session[:last_activity_at] = Time.current.to_i
  redirect_to_resource_or_invite_or_root
else
  session[:user_id] = @current_user.id  # keep them signed in so the explainer can show their identity + log out
  session[:logged_in_at] = Time.current.to_i
  session[:last_activity_at] = Time.current.to_i
  redirect_to needs_invite_path
end
```

Setting session before redirect lets the explainer page identify the user (for the "signed in as X" block and the log-out link) without re-running the OAuth dance.

### 3. Gate logic — application controller

**File:** `app/controllers/application_controller.rb`

At [application_controller.rb:456-470](../../app/controllers/application_controller.rb#L456-L470), the same path is hit on any subsequent request. Change the `render` to a redirect to the explainer when `require_invite?`, and short-circuit (auto-join the tenant) when the tenant is open:

```ruby
def validate_authenticated_access
  tu = @current_tenant.tenant_users.find_by(user: @current_user)
  if tu.nil?
    accepting_invite = current_invite && current_invite.collective == @current_collective
    if !@current_tenant.require_invite? && @current_tenant.require_login?
      @current_tenant.add_user!(@current_user)
    elsif @current_tenant.require_login? && controller_name != "sessions" && !accepting_invite
      redirect_to needs_invite_path
      return
    elsif accepting_invite && current_invite.is_acceptable_by_user?(@current_user)
      @current_tenant.add_user!(@current_user)
    end
  else
    @current_user.tenant_user = tu
  end
  # ... rest unchanged
end
```

Note the order: the `require_login? && require_invite?` check still gates open-but-login-required tenants. The `!require_invite?` branch is the new short-circuit. The `add_user!` call is the existing lazy creation — we're just letting it run for open tenants instead of blocking on it.

### 4. New route + controller action

**File:** `config/routes.rb`

```ruby
get "/needs-invite", to: "signup#needs_invite", as: :needs_invite
post "/needs-invite", to: "signup#accept_invite_code"
```

**File:** `app/controllers/signup_controller.rb` (new)

```ruby
# typed: true
class SignupController < ApplicationController
  skip_before_action :validate_authenticated_access
  before_action :require_signed_in_user

  def needs_invite
    @sidebar_mode = "none"
    if @current_tenant.tenant_users.exists?(user: @current_user)
      redirect_to root_path
      return
    end
    render "signup/needs_invite", layout: "application"
  end

  def accept_invite_code
    code = params[:code].to_s.strip
    invite = Invite.tenant_scoped_only(@current_tenant.id).find_by(code: code)
    if invite && invite.is_acceptable_by_user?(@current_user)
      @current_tenant.add_user!(@current_user) unless @current_tenant.tenant_users.exists?(user: @current_user)
      redirect_to "#{invite.collective.path}/join?code=#{invite.code}"
    else
      flash.now[:alert] = "That invite code is not valid or has expired."
      @sidebar_mode = "none"
      render "signup/needs_invite", layout: "application", status: :unprocessable_entity
    end
  end

  private

  def require_signed_in_user
    redirect_to "/login" unless @current_user
  end
end
```

Skipping `validate_authenticated_access` is the right move here — this controller's whole purpose is to handle the case where that filter would have bounced them. Same pattern that lets the existing 403 render without re-invoking the gate.

### 5. New view

**File:** `app/views/signup/needs_invite.html.erb` (new)

Replaces the no-invite path of [403_to_logout.html.erb](../../app/views/sessions/403_to_logout.html.erb). Layout matches the existing `pulse-auth-*` class pattern from that file.

Contents:
- Heading: "An invite is required to join *<tenant.name>*"
- Subtitle: short explanation that this community is invite-only and that codes come from existing members
- Invite-code form (POST `/needs-invite`, single `code` text input, submit button)
- Flash alert when the code is invalid
- "Signed in as <name> <email>" block (preserved from the 403 page)
- Log-out link
- Optional: a `mailto:` or link to a tenant-level support contact if one is configured (deferred — not all tenants will have one)

### 6. Delete the no-invite branch of `403_to_logout`

The existing `403_to_logout.html.erb` is still used for **suspended users** ([sessions_controller.rb:213](../../app/controllers/sessions_controller.rb#L213) uses `403_suspended`, but check if any other paths still use `403_to_logout`). Audit and:

- If `403_to_logout` is only used for the no-invite case → delete it.
- If it's used for other forbidden states → leave it for those, just stop routing the no-invite case to it.

```bash
grep -rn "403_to_logout" app/
```

### 7. Tests

**File:** `test/controllers/signup_controller_test.rb` (new)

- `GET /needs-invite` as authenticated user with no `tenant_user` renders the page.
- `GET /needs-invite` as authenticated user *with* a `tenant_user` redirects to root.
- `GET /needs-invite` unauthenticated redirects to `/login`.
- `POST /needs-invite` with a valid code → user is added to tenant, redirected to collective join page.
- `POST /needs-invite` with an invalid code → re-renders with flash alert, status 422.
- `POST /needs-invite` with an expired code → re-renders with flash alert.

**File:** `test/models/tenant_test.rb`

- `require_invite?` defaults to true.
- `require_invite?` returns false when explicitly set to `'false'`.

**File:** `test/controllers/sessions_controller_test.rb` (extend existing)

- `internal_callback` for a user with no `tenant_user` and no invite cookie on a `require_invite=true` tenant redirects to `/needs-invite`.
- `internal_callback` for the same user on a `require_invite=false` tenant proceeds to root (and `tenant_user` is created via the existing lazy path on the next request).

**File:** `test/integration/invite_signup_flow_test.rb` (new) — **the missing end-to-end test**

Simulates the full unauth-user-clicks-invite-link flow:

1. GET `/login?code=<valid_invite_code>` → asserts `collective_invite_code` cookie is set on the shared domain.
2. Simulate the OAuth callback by directly calling `sessions#internal_callback` with a token (using the existing test helpers / `encrypt_token`) → asserts the cookie is still present and the user is redirected to the collective join page.
3. Assert that after acceptance, the cookie is cleared and a `TenantUser` + `CollectiveMember` exist.
4. Negative case: same flow with an expired invite → user ends up at root or `/needs-invite`, no membership created.

This is the test that today's codebase is missing. It does not actually exercise the external OAuth provider — it exercises the cookie-survives-redirects-and-is-read-by-callback contract, which is the load-bearing part.

## Files to modify

| File | Change |
|------|--------|
| `app/models/tenant.rb` | Add `require_invite?` reader |
| `app/controllers/sessions_controller.rb` | Gate respects `require_invite?`; redirect to `/needs-invite` instead of render 403 |
| `app/controllers/application_controller.rb` | Same gate change in `validate_authenticated_access`; auto-join open tenants |
| `app/controllers/signup_controller.rb` | NEW — `needs_invite` + `accept_invite_code` actions |
| `app/views/signup/needs_invite.html.erb` | NEW — friendly explainer + invite-code form |
| `config/routes.rb` | Add `/needs-invite` GET + POST |
| `app/views/sessions/403_to_logout.html.erb` | Delete if unused after migration; otherwise leave for other forbidden states |
| `test/controllers/signup_controller_test.rb` | NEW |
| `test/controllers/sessions_controller_test.rb` | Add gate-redirect cases |
| `test/models/tenant_test.rb` | Add `require_invite?` cases |
| `test/integration/invite_signup_flow_test.rb` | NEW — end-to-end invite-cookie survival |

## Existing code to reuse

- `Invite.tenant_scoped_only` + `Invite#is_acceptable_by_user?` ([invite.rb:39-44](../../app/models/invite.rb#L39))
- `Tenant#add_user!` ([tenant.rb:248](../../app/models/tenant.rb#L248)) for lazy tenant membership creation
- `set_shared_domain_cookie` / `delete_collective_invite_cookie` ([sessions_controller.rb:284-309](../../app/controllers/sessions_controller.rb#L284))
- `pulse-auth-*` CSS classes from the existing 403 page
- `redirect_to_invite_if_allowed` ([sessions_controller.rb:252](../../app/controllers/sessions_controller.rb#L252)) — the existing acceptance path; the new `accept_invite_code` action mirrors it minus the cookie indirection

## Verification

1. Write tests (red-green TDD — write `signup_controller_test.rb`, `tenant_test.rb` updates, and `invite_signup_flow_test.rb` first, see them fail).
2. Implement changes; run targeted test files:
   ```bash
   docker compose exec web bundle exec rails test test/controllers/signup_controller_test.rb test/models/tenant_test.rb test/controllers/sessions_controller_test.rb test/integration/invite_signup_flow_test.rb
   ```
3. Manual smoke test in Docker:
   - Sign up via OAuth with no invite → land on `/needs-invite`, see tenant name + form.
   - Submit a bogus code → flash alert.
   - Submit a valid code → land on collective join page.
   - Log out and sign back in → still hits `/needs-invite` (record preserved as pending).
   - Toggle `require_invite=false` on a tenant via console → next signup auto-joins, no `/needs-invite` redirect.
4. Static analysis: `docker compose exec web bundle exec rubocop` + `docker compose exec web bundle exec srb tc`.
5. CI runs the full suite.

## Out of scope (deferred)

- Self-serve tenant creation from the `/needs-invite` page
- Admin UI for toggling `require_invite` per tenant
- `approval_required` signup mode (admins approve a pending queue)
- Onboarding flow for newly-admitted users (separate plan)
- Surfacing pending users to tenant admins ("X tried to sign up but has no invite")
