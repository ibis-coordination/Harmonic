# Signup, billing, and onboarding flow

Umbrella plan for the signup-invite-gate-ux branch. The first three phases have shipped; the last (full account activation + onboarding checklist) is the next piece of work.

## Status

| Phase | What | Status |
|---|---|---|
| 1 | `/invite-required` page + two-step confirm flow | shipped |
| 2 | Humans-free pricing + billing-gate `return_to` resume | shipped |
| 3 | API-token billing (close the "free human as agent proxy" loophole) | shipped |
| 4 | **Full account activation**: invite + verified email + 2FA, surfaced as a checklist | planned |

---

## Phase 1 — `/invite-required` page (shipped)

**Problem**: when a user authenticated via OAuth without a valid invite, the app rendered a generic "Access Denied" page ([sessions/403_to_logout.html.erb](../../app/views/sessions/403_to_logout.html.erb), now deleted) with no explanation and no recovery path. Their `User` + `OauthIdentity` records were created and orphaned.

**Shipped**:

- **`/invite-required` landing page** ([app/views/signup/invite_required.html.erb](../../app/views/signup/invite_required.html.erb), [app/controllers/signup_controller.rb](../../app/controllers/signup_controller.rb)) — explains the gate, accepts a code, header is hidden (non-members shouldn't see tenant chrome).
- **Two-step confirm flow** ([app/views/signup/confirm_invite.html.erb](../../app/views/signup/confirm_invite.html.erb)): `POST /invite-required` validates the code and renders a "You're invited to join *X* in *Y*" confirmation page; `POST /invite-required/accept` performs the atomic tenant + collective join inside a single transaction. No orphan-`TenantUser` state if join partially fails.
- **`Tenant#require_invite?` reader wired up** ([app/models/tenant.rb](../../app/models/tenant.rb)). The setting was previously defined but never read.
- **`Invite` validation** ([app/models/invite.rb](../../app/models/invite.rb)) rejecting invites for main / private_workspace / chat collectives, plus `Invite#collective_invitable?` that `is_acceptable_by_user?` consults — defends against legacy invites that predate the validation.
- **`validate_authenticated_access` redirect bug** ([app/controllers/application_controller.rb](../../app/controllers/application_controller.rb)) — `redirect_to "/invite-required"` now `return`s, preventing fallthrough that created spurious main-collective memberships for non-tenant-members.
- **End-to-end test backfill** for invite-cookie survival across the OAuth round-trip ([test/integration/invite_signup_flow_test.rb](../../test/integration/invite_signup_flow_test.rb)) — previously untested.

**Commits**: `9ea9e2d`, `63a327c`.

---

## Phase 2 — humans-free pricing + billing-gate resume (shipped)

**Problem**: new users hit `/billing` immediately after signup (felt like a bait-and-switch, especially for invitees). The billing gate also lost the user's destination — Stripe Checkout returned them to `/billing` with no path back to what they were doing.

**Shipped**:

- **Humans-free pricing** ([app/models/user.rb](../../app/models/user.rb#L582)): `User#billable_quantity` no longer counts the user themselves. Only AI agents and additional non-main collectives are billed. `stripe_billing_setup?` returns true for users with zero billable resources → no billing gate for fresh signups.
- **`/billing` "Free account" framing** ([app/views/billing/show.html.erb](../../app/views/billing/show.html.erb), [show.md.erb](../../app/views/billing/show.md.erb), [_inventory_table.html.erb](../../app/views/billing/_inventory_table.html.erb)) — copy updated to reflect that joining is free and $3/mo only kicks in when you create an agent or extra collective.
- **Pricing disclosure dropped from signup** ([app/views/signup/invite_required.html.erb](../../app/views/signup/invite_required.html.erb), [confirm_invite.html.erb](../../app/views/signup/confirm_invite.html.erb)) — joining is free, no $3/mo notice needed.
- **Billing gate preserves `return_to`** ([app/controllers/application_controller.rb](../../app/controllers/application_controller.rb)) — when the gate intercepts a top-level HTML GET, it stashes `request.fullpath` in `session[:billing_return_to]` and a flash notice ("Set up billing to continue. We'll bring you back here when you're done."). After Stripe Checkout, `BillingController#handle_checkout_return` resumes there. JSON/XHR requests are filtered out so background polls (like `/notifications/unread_count`) don't clobber the saved destination.

**Commit**: `5904c13`.

---

## Phase 3 — API-token billing (shipped)

**Problem**: making humans free created a loophole — a user could create a fake "human" account, generate an API token, and run AI-style automation through it for free.

**Shipped**:

- **`User#counts_self_for_api_access?`** ([app/models/user.rb](../../app/models/user.rb)) — true when a human user has ≥1 active external API token in a billing-enabled tenant. Adds +1 to `billable_quantity` (flat surcharge, not per-token).
- **Sys/app admins fully exempt from billing** — short-circuited in `billable_quantity` since they're platform operators, not customers.
- **API auth-time gate** ([app/controllers/application_controller.rb](../../app/controllers/application_controller.rb), `api_authorize!`) — returns `403 { error: "billing_required", message: ... }` for human-owned external tokens when the user has no active subscription. AI-agent tokens and internal (runner) tokens pass through; agent billing is handled at agent creation.
- **`api_token_present?` exempts the billing gate** — without this, collective-scoped API paths like `/collectives/X/api/v1/...` were redirected to `/billing` instead of getting clean JSON 403s.
- **Token creation requires `confirm_billing`** ([app/controllers/api_tokens_controller.rb](../../app/controllers/api_tokens_controller.rb), [app/views/api_tokens/new.html.erb](../../app/views/api_tokens/new.html.erb)) — mirrors the AI agent / collective pattern. Skipped when the user is already a billable token holder (no new charge to confirm) or admin.
- **Token deletion calls `sync_subscription_quantity!`** so the surcharge drops on the next invoice when a user deletes their last token while subscribed.
- **Token show page warns** "not yet active — set up billing to activate it" when the user isn't billing-active.
- **`/billing` user row shows "$3/mo (API access)"** when applicable.

**Commit**: (pending — current uncommitted work on the branch).

---

## Phase 4 — activation gate (planned)

**Framing**: a general auth-time check, not signup-specific. Whenever a logged-in human user lands anywhere, we verify three preconditions; if any fail, they're sent to a `/activate` checklist page that guides them through the missing pieces. The mechanism is reusable for future "you must do X before continuing" gates (privacy-policy acceptance, T&C updates, etc.).

### The three checks

1. **Tenant access**: user has a `TenantUser` on the current tenant, **OR** they have a valid invite-code cookie (`current_invite` resolves to a still-acceptable invite). Invite acceptance itself is not changed by this phase — it remains a user action via the existing `/invite-required` flow, and is the ordinary path to satisfy this check.
2. **Verified email**: identity-managed (`OmniAuthIdentity#email_confirmed_at`) for email/password accounts; OAuth identities auto-mark verified at creation (we trust Google/GitHub's verified-email claim).
3. **2FA enabled**: `OmniAuthIdentity#otp_enabled` is true. Existing `/settings/two-factor` flow is the action; the checklist just links to it.

Checks 2 and 3 are gated by per-tenant flags: `Tenant#require_verified_email?` and `Tenant#require_2fa?`. Default true; falsy = skip that check for that tenant.

Sys/app admins are exempt from the activation gate (platform operators, not customers).

### Activation predicates

```ruby
# User
def email_verified?
  omni_auth_identity&.email_confirmed_at.present? || external_oauth_identities.exists?
end

def two_factor_enabled?
  omni_auth_identity&.otp_enabled || false
end

# OmniAuthIdentity
def email_verified?
  email_confirmed_at.present?
end
```

The composite "is this user activated for this tenant right now" check lives in the controller filter (because it depends on `current_invite`, which is per-request cookie state):

```ruby
def check_activation_gate
  return unless @current_user&.human?
  return if @current_user.sys_admin? || @current_user.app_admin?
  return if is_auth_controller?
  return if api_token_present?
  return if request.path.start_with?("/api/")
  return if exempt_controller_for_activation?  # activation, signup, two_factor_auth, email confirmation

  # Check 1
  has_access = @current_tenant.tenant_users.exists?(user: @current_user) ||
               (current_invite && current_invite.is_acceptable_by_user?(@current_user))
  return redirect_to_activate unless has_access

  # Check 2
  return redirect_to_activate if @current_tenant.require_verified_email? && !@current_user.email_verified?

  # Check 3
  return redirect_to_activate if @current_tenant.require_2fa? && !@current_user.two_factor_enabled?
end
```

`api_authorize!` gains a parallel `activation_required` 403 for human-owned external tokens AND for AI-agent-owned tokens when the agent's parent human is not fully activated. (Closes the loophole where a partly-activated user spawns an agent and uses the agent's tokens to bypass the gate.)

### The `/activate` checklist page

Single page with three items, each showing current status (✓ done, ○ pending) and an action link to the existing flow that satisfies it:

```
✓ Joined Marketing Team                — change collective
○ Verify your email                    — resend verification link
○ Enable two-factor authentication     — set up
```

- Header hidden (same pattern as `/invite-required`).
- Items hidden when their tenant flag is off.
- Once all checks pass, the page redirects to root (or to a stashed `return_to` from the gate).
- Reachable any time from the user menu while incomplete.

### Files to add / modify

| File | Change |
|---|---|
| `db/migrate/...` | `omni_auth_identities`: add `email_confirmed_at`, `email_confirmation_token`, `email_confirmation_sent_at`. `tenants`: add `require_2fa` (bool, default true), `require_verified_email` (bool, default true). |
| `app/models/omni_auth_identity.rb` | `email_verified?`, `send_email_confirmation!`, `confirm_email!(token)`. Existing TOTP machinery untouched. |
| `app/models/oauth_identity.rb` | On create, set the linked `OmniAuthIdentity#email_confirmed_at = created_at` for the matching email (trust the provider's claim). |
| `app/models/user.rb` | `email_verified?`, `two_factor_enabled?` predicates. |
| `app/models/tenant.rb` | `require_2fa?`, `require_verified_email?` readers. |
| `app/controllers/activation_controller.rb` (new) | `show` (checklist), `send_email_confirmation` (resend action). Mirrors `SignupController`'s `is_auth_controller? = true`. |
| `app/views/activation/show.html.erb` (new) | Checklist UI. |
| `app/controllers/email_confirmations_controller.rb` (new) | `GET /confirm-email/:token` flips `email_confirmed_at`. Token-authenticated, no login required. |
| `app/controllers/application_controller.rb` | Add `check_activation_gate` before_action after `check_stripe_billing_gate`. Add `activation_required` 403 in `api_authorize!`. |
| `app/mailers/email_confirmation_mailer.rb` (new or extend existing) | Sends the confirmation email at signup-time. |
| `config/routes.rb` | `get "/activate" => "activation#show"`, `post "/activate/send-confirmation" => "activation#send_email_confirmation"`, `get "/confirm-email/:token" => "email_confirmations#confirm"`. |

### Resolved design decisions

| Question | Decision |
|---|---|
| Trust OAuth `verified_email` claim? | **Yes.** Google/GitHub identities auto-mark `email_confirmed_at = created_at`. Only email/password identities need a confirmation round-trip. |
| What satisfies check #1? | **TenantUser membership OR valid invite-code cookie for an acceptable invite.** Invite acceptance is a separate user action, unchanged from today. |
| Per-tenant config? | **Yes.** `Tenant#require_2fa?` and `Tenant#require_verified_email?`, default true. Self-hosted instances can opt out. |
| AI agent tokens when parent not activated? | **Block.** `api_authorize!` checks parent's activation state for agent-owned tokens, mirrors human-token gate. |
| Existing user migration? | **Hard cutover.** Users without verified email or 2FA hit `/activate` on next request. No production paying users to grandfather. |
| Final invite acceptance? | **Unchanged.** The existing `/invite-required` → confirm → accept flow is the user action that creates `TenantUser`. The activation gate does not auto-accept invites. |

### Out of scope for phase 4

- Self-serve tenant creation
- Onboarding tour / explainer content (the checklist itself is the onboarding)
- "Skip 2FA for now" escape hatch — requirement is hard
- Multi-factor methods beyond TOTP (SMS, hardware keys) — future
- Org-level activation policies ("all members must have 2FA within 7 days") — future
- Reuse of the activation framework for privacy-policy / T&C acceptance — future, but the mechanism is built to extend
