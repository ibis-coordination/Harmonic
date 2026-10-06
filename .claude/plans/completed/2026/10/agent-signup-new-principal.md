# Agent signup: principals who are not members yet

Status: implemented (branch `agent-signup-new-principal`). Extends the shipped agent signup (`.claude/plans/completed/2026/10/agent-signup-and-principal-claim.md`), which only emails a claim link when the named address belongs to an existing, eligible member.

## Goal

An agent names a human who has no account on this tenant — maybe no Harmonic account at all. One emailed link walks that human through whatever stands between them and the claim page (registration, email verification, 2FA, joining the tenant), then the claim proceeds exactly as it does for a member today. The agent's side of the protocol does not change.

## The rule that bounds everything: a signup is never an invite

The signup endpoint is anonymous. If a signup could admit a stranger to a tenant, `require_invite` would be bypassable with one curl. So:

- **Open tenant** (`require_invite` off): anyone can join by logging in, so emailing a stranger a link that ends in registration adds nothing the tenant has not already opened. Email goes out.
- **Invite-only tenant** (the default): a stranger is emailed only when the signup carries a usable invite code, which a member issued. Without one, no email is sent; the signup is unclaimable, same as an unmatched address today.

The tenant's membership policy is the only switch. No new feature flag. The agent-facing copy states the policy unconditionally (the `/invite-required` page already makes it public), so the response never reveals whether an address matched.

## Who is the addressee

Today the addressee is `principal_user_id`, resolved at signup time, which is why a non-member is unresolvable. Change: the addressee is **whoever proves control of the named mailbox**.

- New column `principal_email_digest` (NOT NULL): keyed HMAC of the lowercased, stripped email, keyed like the pairing code digest with its own purpose string. Deterministic, so it supports lookup; not reversible, so a stranger's address supplied by an anonymous caller is still not stored.
- `principal_user_id` becomes a historical record, written at claim or decline (who acted), not resolved at start.
- Addressee check at claim: `current_user.human? && current_user.email_verified? && digest(current_user.email) == signup.principal_email_digest`. Verified email is required **regardless of the tenant's `require_verified_email` setting**: it is the proof of addressee identity. Without it, anyone could register with the named address and reach the claim page.
- The pending-per-principal cap (3) and the "agents waiting for you" notice on `/ai-agents` key on the digest of the current user's email. A user who changes their email mid-flow loses sight of a pending signup; it expires in 24h.

Trade-off accepted: registration cannot prefill the email (we do not have it). The human types their address; the digest check at claim confirms it.

Agent signup is merged but unreleased, so production does not have the table yet; the column can be NOT NULL without a backfill. Dev rows get deleted before migrating.

## When the email is sent

Compute at signup time, from the address, the tenant and the optional invite:

| Address belongs to | Open tenant | Invite-only, invite attached | Invite-only, no invite |
|---|---|---|---|
| an eligible member (today's rule) | send | send | send |
| a Harmonic user not on this tenant | send | send | no |
| nobody | send | send | no |
| a user who is suspended, deleting, non-human, or two users share the address case-insensitively | no | no | no |

An existing user with an unverified email is now emailed (today: silently dropped); the claim page sends them to verify. The response to the agent is identical in every row.

`deliver_later` carries the raw address as a job argument, as every mailer to a typed-in address does. Nothing else retains it.

## Invite codes

`start_agent_signup` gains an optional `invite_code` param. At signup: look up `Invite.tenant_scoped_only(tenant.id).find_by(code:)`; usable when not expired, `collective_invitable?`, and shareable (`invited_user` nil). Store `invite_id` (FK, nullify). An unusable code is an error response, "That invite code is not valid or has expired", the same words `/invite-required` shows. That makes the anonymous endpoint an invite-code validity oracle; invite codes are random shareable links that `/join?code=` already validates publicly, and the per-IP throttle (10/hour) applies.

The intended scenario: a member sends a friend an invite link; the friend hands it to their agent ("set us both up"); one signup carries both.

## Carrying the claim through the gates

The claim page stays the single destination; each gate is a detour that returns to it. The claim controller is an ordinary controller (not `is_auth_controller?`), so the app's membership, activation, billing, session and suspension gates already run on it. What each does for a non-member, and the hooks that bring them back:

1. **Login / registration**: the `prepend_before_action` stashes the claim path per tenant for any visitor who is logged out, not a member, or not activated, and the invite the signup carries as the pending invite. Logged out → `/login` → register or log in → callback. `SessionsController#redirect_to_resource_or_invite_or_root` consumes the claim stash for non-members too.
2. **Membership** (`validate_authenticated_access`, unchanged): open tenant → `add_user!`; invite-only → `/invite-required`, which finds the pending invite and shows the confirmation. `SignupController#accept_invite` redirects to the consumed claim stash before falling back to the collective page. A non-member with no invite sits at the invite-code form; the stash waits.
   - The controller keeps one membership guard for the case the gate skips (login-optional tenants). In practice the activation gate turns non-members away there first, so only operators reach it; a logged-in non-member of a login-optional open tenant is stuck at `/activate` today regardless of agent signup, which is outside this change.
3. **Activation** (`check_activation_gate`, unchanged): sets `session[:activation_return_to]` and `/activate` returns there when the checklist is done. The emailed confirmation link deliberately clears that return path, so `/activate`'s done-branch consumes the claim stash first; the claim page re-stashes while the addressee is unactivated.
   - Tenants that disabled `require_verified_email` leave the email item off `/activate`, but the claim still needs it: a guard page on the claim ("Verify your email to claim this agent", with the resend button) covers that case.
4. **Billing** (`check_stripe_billing_gate`, unchanged): a human with no Stripe customer sets up billing before seeing the claim page; one with a customer but a lapsed subscription gets `billing_setup_required` from the claim itself. Both existed.
5. **Reverification** (exists): `api_tokens` scope; a user with no 2FA is sent to set it up and comes back.

## Abuse surface added

Anonymous callers can now make Harmonic email arbitrary addresses on open tenants, and on invite-only tenants when they hold an invite. That is already true of `/register` and password reset on every site; the differences and their bounds:

- **Email bombing one address.** Today's per-email throttle (3/day) is keyed per tenant; re-key it globally (drop `tenant.id`) so one address gets at most 3 claim emails a day across all tenants.
- **Mass mailing distinct strangers from one tenant** (deliverability, spam reports). New per-tenant cap on signups per day (100, `RateLimits`), applied to every signup, member or not, so exceeding it is not a membership oracle. Error response names the cap, not the address.
- **Phishing.** Copy stays fixed, nothing agent-supplied appears, the only link is the tenant's own claim URL, and the claim requires a pairing code the agent gave the human out of band. Same footing as the member case.
- **Tenant operators as spammers.** A tenant admin who enables the flag on an open tenant can cause claim emails to strangers at 100/day/tenant, with fixed copy naming their tenant. Same operator could already run an open-registration tenant; the cap bounds it.

## What does not change

Pairing code, poll secret, 24h windows, pickup, cleanup job (30-day retention; the digest is not PII), capability lists, audience lock-in, anonymous action sweep. No new actions.

## Agent-facing copy

- `start_agent_signup` describe and result: "Your human principal gets an email at the address you named. If they have no account here yet, the link walks them through creating one. Give them the pairing code." On invite-only tenants, unconditionally: "This tenant requires an invite to join. If your principal is not a member yet, include their invite code as `invite_code`."
- `/agent-signups` index states the tenant's policy in the same words.
- Mailer: same fixed copy for members and strangers, plus one line: "If you do not have an account on {domain} yet, you will create one at the link."

## Work list (TDD, one branch `agent-signup-new-principal`)

1. Migration: `principal_email_digest` string NOT NULL, `invite_id` FK (nullify); index `[tenant_id, principal_email_digest, state]` replacing the principal_user_id one.
2. `AgentSignup`: digest helper, `addressed_to?(user)`, `deliverable?`-style decision from the table above, invite validation, cap and open-pending lookups by digest, `claim!`/`decline!` record `principal_user`.
3. `AgentSignupsController`: `invite_code` param, global per-email key, per-tenant daily cap, copy.
4. `AgentSignupMailer.claim(email, public_id, tenant)`.
5. `AgentSignupClaimsController`: stash the signup's invite alongside the claim path for unactivated visitors too, membership guard, unverified-email guard page, addressee via digest.
6. `SessionsController` stash consumption for non-members; `SignupController#accept_invite` and `ActivationController#show` return to the claim.
7. `AiAgentsController#index` pending list by digest.
8. Tests: model matrix (table above), mailer to a stranger, controller (invite code valid/invalid/expired/user-specific, tenant cap, invite-only sends nothing, open tenant sends), claims controller (auto-join on open, invite redirect with code, activation return, unverified guard, existing user from another tenant), sessions + signup controller redirects, integration test `register → confirm email → 2FA → join → claim → token` on an invite-only tenant with an invite code.
9. Docs: `/help/agents` and `/help/privacy` (an agent can cause one email to an address with no account), `docs/ARCHITECTURE.md` "Agent Signup", `docs/CONTROLLED_VOCABULARY.md` if a term is added, manual checklist new sections (open tenant stranger; invite-only with code; invite-only without code).

## Out of scope

Provisional agents (usable before any claim) remain a separate idea; this path changes nothing about when an agent becomes usable. Admin view of pending signups. Prefilling registration with the named address.
