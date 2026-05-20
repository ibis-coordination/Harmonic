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

## Phase 4 — full account activation (planned)

**Goal**: a freshly signed-up user is not "fully activated" until they have all three of:

1. A valid invite (= `TenantUser` exists)
2. A verified email
3. 2FA enabled

Until all three are satisfied, the account is "pending activation." Today, only the invite requirement is enforced. Email verification has no signup-time path (only an email-change confirmation flow exists). 2FA is optional and tucked away in settings.

This phase makes activation a coherent, visible state with a checklist UI.

### The three requirements

| # | Requirement | Today | What's new |
|---|---|---|---|
| 1 | Invite | Enforced at signup ([signup_controller.rb](../../app/controllers/signup_controller.rb)). Joining a tenant requires accepting a valid invite. | No change — already part of the activation checklist. |
| 2 | Verified email | Only OAuth flow implicitly verifies (provider asserts email ownership). Email-password signups don't verify at signup time — only email *changes* trigger a confirmation. See `confirm_email` action at [users_controller.rb:307](../../app/controllers/users_controller.rb#L307). | New: trigger a signup-time confirmation email for email/password accounts; mark `OmniAuthIdentity#email_confirmed_at` (new column) when the link is clicked. OAuth identities auto-mark verified on creation. |
| 3 | 2FA enabled | Optional. TOTP setup lives at `/settings/two-factor` ([two_factor_auth_controller.rb](../../app/controllers/two_factor_auth_controller.rb), [omni_auth_identity.rb#L206](../../app/models/omni_auth_identity.rb#L206) `enable_otp!`). Required only for elevated actions (via `require_reverification`). | Required during onboarding. The onboarding checklist links directly to the existing 2FA setup flow. |

### Activation state model

Add a derived predicate `User#fully_activated?` that returns true when **all three** requirements are met:

```ruby
def fully_activated?
  human? &&
    tenant_users.any? &&                       # 1. invite accepted (at least one tenant)
    email_verified? &&                         # 2. (new method — checks OAuth provider asserts OR confirmation timestamp)
    omni_auth_identity&.otp_enabled            # 3. 2FA enabled
end
```

Until `fully_activated?` is true:

- Browser navigation that lands on most pages redirects to `/activate` (the checklist page), similar to how the billing gate redirects to `/billing`.
- The checklist page exempts itself from this gate (same `is_auth_controller?` pattern used by `SignupController`).
- API access is also gated — human-owned tokens issued to not-fully-activated users get the same `billing_required`-style 403 (but with `error: "activation_required"`). This stops a partially-onboarded user from generating + using a token.

Sys/app admins are exempt from the activation gate (operators, not customers).

### The `/activate` checklist UX

A single page with three checkboxes, each linking to the action that satisfies it:

```
✓ Joined a collective                — Marketing Team
○ Verify your email                  — Resend verification link
○ Enable two-factor authentication   — Set up
```

- The page hides the app chrome (header), same pattern as `/invite-required` and `/confirm_invite`.
- Each item shows current status (checkmark, in-progress, or empty circle) and an action link.
- Once all three are checked, the page auto-redirects to root with a success flash ("Welcome to Harmonic.").
- Reachable any time from the user menu while incomplete.
- The checklist replaces (or precedes) the existing post-signup landing — the user goes from `/invite-required/accept` directly to `/activate` instead of straight to the collective homepage.

### Wiring summary

| File | Change |
|---|---|
| `db/migrate/...` | Add `email_confirmed_at` and `email_confirmation_token` columns to `omni_auth_identities` (email/password identities only). OAuth identities mark `email_confirmed_at = created_at` automatically. |
| `app/models/omni_auth_identity.rb` | `email_verified?` predicate; `send_email_confirmation!`, `confirm_email!(token)`; OAuth `find_or_create_from_auth` sets `email_confirmed_at`. |
| `app/models/user.rb` | `email_verified?` delegates to identity; `fully_activated?` predicate. |
| `app/controllers/activation_controller.rb` (new) | `show` (the checklist), `resend_email_confirmation`, mirrors `SignupController`'s auth-controller exemption. |
| `app/views/activation/show.html.erb` (new) | Three-item checklist. |
| `app/controllers/application_controller.rb` | New `check_activation_gate` before_action that redirects to `/activate` when `current_user && !current_user.fully_activated? && !is_auth_controller? && !api_token_present?`. Mirrors the billing-gate pattern (HTML-GET-only, save return_to, flash). |
| `app/controllers/application_controller.rb` (`api_authorize!`) | Add `activation_required` 403 for human-owned tokens issued to non-activated users. |
| `app/controllers/users_controller.rb` (or a new `email_confirmations_controller`) | `GET /confirm-email/:token` to flip `email_confirmed_at`. |
| `app/controllers/signup_controller.rb#accept_invite` | After successful invite acceptance, redirect to `/activate` (not the collective homepage) when `!fully_activated?`. |
| `app/views/two_factor_auth/setup.html.erb` | After successful enable, redirect to `/activate` if the user came from there (use return_to pattern). |

### Open questions to resolve before implementing phase 4

1. **OAuth providers and email verification**: should we *trust* the OAuth provider's `verified_email` claim, or always require our own confirmation email? Trusting Google/GitHub is standard; if we ever add a provider without this claim (e.g., a custom SSO), the trust assumption breaks.
2. **2FA recovery codes**: do we hand out recovery codes during onboarding setup, or defer to settings? Existing flow at [two_factor_auth_controller.rb](../../app/controllers/two_factor_auth_controller.rb) has `regenerate_codes` — we should make sure the onboarding setup surfaces them too.
3. **Existing users without 2FA**: this becomes a forced upgrade for them. Migration story: grandfathered (existing users keep working until next login), or hard-cutover (everyone hits `/activate` on next request)? Per the earlier humans-free decision the project has no production paying users, so a hard cutover is acceptable — but the dev / test environments will need a sweep.
4. **What does "joined a collective" actually mean for #1**: just `TenantUser` exists, or also `CollectiveMember` on at least one non-main collective? Current behavior (via the invite flow) creates both — but you could imagine a user who's a tenant member with only the auto-created private workspace. Probably require ≥1 non-main, non-private-workspace `CollectiveMember`.
5. **Per-tenant config**: should the three-requirement activation be a tenant setting (mirroring `require_invite`)? Some self-hosted instances might not want to require 2FA. Probably yes — `require_2fa` and `require_verified_email` flags, default true, falsy = skip that checklist item.
6. **AI agent tokens during onboarding**: an AI agent owned by a not-yet-activated human — should the agent's tokens work? Probably not (otherwise the loophole reopens: create a half-activated account, spin up an agent, use the agent's tokens). Need to bake this into the API auth gate.

### Out of scope for phase 4

- Self-serve tenant creation
- Onboarding video / tour / explainer content (the checklist itself is the onboarding)
- "Skip 2FA for now" escape hatch — requirement is hard
- Multi-factor methods beyond TOTP (SMS, hardware keys, etc.) — future
- Org-level activation policies (e.g., "all members must have 2FA within 7 days") — future
