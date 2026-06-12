# Signup Flow Improvements

## Goal

Make the new-user signup path — invite → auth → email confirmation → 2FA → landing in the
collective — smooth end to end, with no dead ends. Three known problems motivate this plan:

1. The collective invite is never actually accepted after activation (user ends up a tenant
   member but not a collective member, with no path back to the invite).
2. Setting up TOTP 2FA on mobile is painful (QR code can't be scanned from the same device).
3. The OAuth signup route is thinly tested at the controller/integration level.

## Current Flow (verified against code)

A new user clicking an invite link goes through:

1. `GET /collectives/X/join?code=ABC` → unauthenticated → redirected to `/login?code=ABC`.
2. `SessionsController#redirect_to_auth_domain` sets the shared-domain cookie
   `collective_invite_code` and bounces to the auth subdomain
   ([sessions_controller.rb:161-172](../../app/controllers/sessions_controller.rb#L161-L172)).
3. User authenticates (GitHub OAuth or email/password "identity" provider). Email/password
   signups get a confirmation email auto-sent; GitHub emails are auto-verified
   ([oauth_identity.rb](../../app/models/oauth_identity.rb)).
4. Token handoff back to the tenant subdomain → `GET /login/callback` →
   `redirect_to_invite_if_allowed`
   ([sessions_controller.rb:257-274](../../app/controllers/sessions_controller.rb#L257-L274)):
   - looks up the invite from the cookie,
   - **deletes the cookie**,
   - adds the user to the **tenant** (`current_tenant.add_user!`),
   - redirects to `/collectives/X/join?code=ABC`.
5. The activation gate fires on that GET (user not fully activated), stashes
   `session[:activation_return_to] = "/collectives/X/join?code=ABC"`, and redirects to
   `/activate` ([application_controller.rb:1413-1437](../../app/controllers/application_controller.rb#L1413-L1437)).
6. User works through the checklist: invite (already satisfied — they're a tenant member now),
   email confirmation, 2FA setup.
7. When all items pass, `/activate` redirects to `activation_return_to` if present, else
   `root_path` ([activation_controller.rb:24-31](../../app/controllers/activation_controller.rb#L24-L31)).

## Problem 1: Invite never accepted after activation

`User#accept_invite!` (which creates the `CollectiveMember`) only runs when the user clicks
the accept button on the `/join` page ([user.rb:546-552](../../app/models/user.rb#L546-L552),
[collectives_controller.rb accept_invite](../../app/controllers/collectives_controller.rb)).
After activation, the user usually never gets back to that page:

- **The email confirmation link destroys the return path.** `EmailConfirmationsController#confirm`
  calls `session.delete(:activation_return_to)`
  ([email_confirmations_controller.rb:18](../../app/controllers/email_confirmations_controller.rb#L18))
  to clear "stale" return targets — but in the invite flow that return target is the only
  remaining pointer to the invite. After confirming email in the same browser, activation
  completes to `root_path` and the invite is lost.
- **Cross-device email confirmation loses it too.** If the user opens the confirmation link on
  another device, the original session's `activation_return_to` survives but the user often
  continues on the new device, where there is no session state at all.
- **The cookie is already gone.** `redirect_to_invite_if_allowed` deletes
  `collective_invite_code` before activation starts, so
  `ActivationController#pending_invite_for_current_tenant`
  ([activation_controller.rb:98-104](../../app/controllers/activation_controller.rb#L98-L104))
  can never recover it. Today this is masked because tenant membership satisfies the invite
  item — with the misleading copy "You have accepted your invite"
  ([activation_controller.rb:72-73](../../app/controllers/activation_controller.rb#L72-L73)),
  when the collective invite has not been accepted.

Net result: the user becomes a tenant member but never a collective member, and has no
visible path to the collective they were invited to.

### Design: explicit acceptance for both joins, tenant join deferred until the user says yes

Joining must be a deliberate confirmation. An upcoming **collective policies** feature will
let collectives require members to acknowledge/sign policies before joining, so acceptance
can never be automatic — and since tenant membership auto-adds the user to the main
collective, the *tenant* join needs the same explicit beat, not just the collective join.

The codebase already has the right acceptance UI: the `/invite-required` confirm/accept flow
([signup_controller.rb](../../app/controllers/signup_controller.rb)) shows a "wait, what am
I joining?" confirmation page and performs an **atomic tenant + collective join** in one
transaction. Today only manual code entry uses it; the invite-link path bypasses it,
silently `add_user!`-ing the user into the tenant during `/login/callback`
([sessions_controller.rb:266-269](../../app/controllers/sessions_controller.rb#L266-L269))
and leaving the collective join to a `/join` page the user usually never reaches again.

The fix: stop the silent tenant add and route invite-link users through the same
confirm/accept flow. Because `fully_activated_for?` requires a `TenantUser`
([user.rb:712](../../app/models/user.rb#L712)), the activation gate keeps firing until the
user explicitly accepts — convergence is guaranteed by construction, with no banner or
return-path bookkeeping. You are not "in" a require-invite tenant until you say yes. The
logged-in-but-no-TenantUser state already exists in production (the manual `/invite-required`
flow creates it), so this routes invite-link users into an existing state rather than
introducing a new one.

Concretely:

1. **`redirect_to_invite_if_allowed` stops adding the user to the tenant.** Instead it stores
   `session[:pending_invite_code] = invite.code` and redirects:
   - existing tenant members (invited to a second collective) → `/collectives/X/join?code=`
     exactly as today — they're activated, the gate never interferes, and this path already
     works;
   - everyone else → the confirm page, so the user reviews what they're joining immediately
     after authenticating, while the invite context is fresh. Acceptance creates the
     `TenantUser` + `CollectiveMember` atomically; the gate then walks them through email/2FA.
   Note the session cookie is shared across subdomains
   ([session_store.rb](../../config/initializers/session_store.rb) sets
   `domain: ".#{HOSTNAME}"`), so tenant isolation comes from always resolving the code via
   `Invite.tenant_scoped_only(current_tenant.id)`, not from where it's stored. What the
   session buys over the old cookie: it isn't deleted by the callback, and it's unaffected
   by the `activation_return_to` deletion in `EmailConfirmationsController#confirm`.
   Clear the key on acceptance or when the invite becomes permanently unacceptable.
2. **Give the confirm page a GET entry point.** `confirm_invite` is POST-only today; the
   redirect needs `GET /invite-required?code=ABC` (or equivalent) to render the confirmation
   view directly when a valid code is present (param or session). SignupController is
   gate-exempt, so this works before activation is complete.
3. **The activation checklist reads the pending invite from the session.**
   `pending_invite_for_current_tenant`
   ([activation_controller.rb:98-104](../../app/controllers/activation_controller.rb#L98-L104))
   switches from the (already-deleted) cookie to `session[:pending_invite_code]`. Item copy:
   satisfied-via-membership → "You have joined *Collective Name*"; satisfied-via-pending →
   "Invite to *Collective Name* found — review and accept it" with a button to the confirm
   page; neither → "Enter an invite code" as today. The current "You have accepted your
   invite" (shown to tenant members who never accepted the collective invite) goes away with
   the silent tenant add.
4. **`/activate` completion routes to the pending invite.** When `@all_satisfied` and a
   pending invite resolves, redirect to the confirm page, taking precedence over
   `activation_return_to`. This covers the user who abandoned the confirm page right after
   login, finished email/2FA, and would otherwise be dropped at `root_path`.
5. **Fix the `/join` page** — still the acceptance point for existing members, and it has
   latent bugs ([collectives_controller.rb:654-691](../../app/controllers/collectives_controller.rb#L654-L691)):
   - `CollectivesController#accept_invite` never checks `is_acceptable_by_user?` — an
     **expired invite can be accepted** via POST `/join` (the signup-controller path and the
     login-callback path both check; this one doesn't). An `invited_user` mismatch reaches the
     `raise` in `User#accept_invite!` and 500s instead of rendering a friendly error.
   - The already-a-member branch uses `render status: 400, text: ...` — `text:` hasn't been a
     valid render option since Rails 5.1, so a double-submit 500s.
6. **Resolve the `TODO: track invite accepted event`** ([user.rb:551](../../app/models/user.rb#L551))
   while in here — record acceptance (timestamp/user on the invite or an event) so support can
   debug invite issues, and so single-use semantics become possible later. This also lays
   groundwork for the policies feature, which will need an acceptance record to attach
   acknowledgements to.

The signup-controller guards (`redirect_to root_path if member`,
[signup_controller.rb:26](../../app/controllers/signup_controller.rb#L26)) stay as they are:
new users go through confirm/accept, existing members go through `/join`. The no-checklist
tenant (requires neither verified email nor 2FA) follows the same route — the gate fires
once on the no-TenantUser state, `/activate` shows only the invite item, and the confirm
page is one click away.

Behavior changes to call out (deliberate, will need existing tests updated):

- Authenticating with an invite link no longer makes you a tenant member by itself —
  `invite_signup_flow_test.rb` assertions about the auto-add must flip to assert the
  pending state and the confirm-page redirect instead.
- Users who abandon mid-flow are no tenant members at all (today they're members with a
  dangling collective invite). Re-login with no session recovers via `/invite-required`
  manual code entry — a clear ask, instead of today's silent half-joined state.

Edge cases to test (red-green):

- Accept immediately after auth, then email/2FA via the gate → lands back via
  `activation_return_to` (or `root_path` if the email link deleted it — acceptable, they're
  a full member either way).
- Abandon the confirm page, complete email/2FA first → `/activate` all-satisfied redirect
  lands on the confirm page; accepting completes the flow.
- Email confirmed on a different device → original session converges via the gate on its
  next request.
- Fresh login on a new device with no session → callback finds no `TenantUser` and no cookie
  → `/invite-required`, user re-enters the code.
- Invite expires or is revoked between login and confirm → friendly error on the confirm
  page, item reverts to "Enter an invite code"; session key cleared.
- Invite with mismatching `invited_user_id` → friendly rejection, not a 500.
- Expired invite POSTed to `/join` → rejected with a friendly message (today it's accepted).
- Already-a-member double-submit on `/join` → friendly notice (today it 500s on `render text:`).
- Existing activated member clicking an invite link to a second collective → straight to
  `/join`, accepts there (unchanged).
- User already a collective member (idempotent `find_or_create_by!` — already handled).

## Problem 2: 2FA setup is hard on mobile

A user signing up on their phone cannot scan the QR code with the same phone. The manual key
is hidden inside a collapsed `<details>` element
([setup.html.erb:23-33](../../app/views/two_factor_auth/setup.html.erb#L23-L33)) and rendered
as a raw 32-char string with no copy button.

Proposed improvements, smallest first:

1. **Add an `otpauth://` deep link** ("Open in authenticator app") button. On mobile this opens
   the user's installed TOTP app directly with the secret pre-filled — no scanning, no typing.
   The provisioning URI already exists (it's what the QR encodes); render it as a link.
2. **Make the secret copyable**: a one-tap "Copy key" button (Pulse clipboard pattern), with the
   key chunked for readability (`XXXX XXXX …`), matching how recovery codes are formatted.
3. **Reorder by device**: on small viewports show the deep link + copyable key first and tuck
   the QR code behind the disclosure; on desktop keep QR-first. CSS-only (media query +
   order) — no user-agent sniffing needed.
4. **Recovery codes on mobile**: verify the Copy/Download buttons in
   [show_recovery_codes.html.erb](../../app/views/two_factor_auth/show_recovery_codes.html.erb)
   work on mobile Safari/Chrome (download attribute support varies); ensure Copy is the
   primary affordance.

Bigger, separate-plan candidates (note here, don't block on them):

- **Email one-time codes** as a second 2FA method, or **passkeys/WebAuthn** as a phishing-resistant
  alternative that's dramatically easier on mobile. Today TOTP is the only method
  (recovery codes are the only fallback). If `require_2fa` tenants want low-friction signup,
  one of these is the real long-term answer.

## Problem 3: OAuth signup is under-tested

Model-level coverage of `OauthIdentity.find_or_create_from_auth` is good; controller/integration
coverage of the actual OAuth callback path is missing. Gaps found:

| Scenario | Coverage today |
|----------|----------------|
| New user signs up via GitHub callback (end-to-end through `oauth_callback`) | none |
| Existing user logs in via GitHub | none |
| Account linking: email/password account, later GitHub login with same email | model-only |
| Email/password signup with unconfirmed email, then GitHub link — confirmation state | none |
| Provider disabled on tenant → 403 ([sessions_controller.rb oauth_callback](../../app/controllers/sessions_controller.rb#L36-L89)) | none |
| GitHub OAuth user + 2FA (only the identity provider's 2FA path is tested) | none |
| OAuth avatar attachment (regression for the IOError fix, commit ee057035) | minimal |
| OAuth + invite cookie (the full Problem-1 flow) | partial — [invite_signup_flow_test.rb](../../test/integration/invite_signup_flow_test.rb) covers halves, not the activation handoff |

Proposed work: an integration test suite (`test/integration/oauth_signup_flow_test.rb`) using
OmniAuth test mode (`OmniAuth.config.mock_auth[:github]`) covering the rows above. The
Problem-1 fix should add its activation-handoff tests here too, so the whole
invite → OAuth → activate → collective-member journey is asserted in one place.

Also address while in this code:

- `# TODO check if user is allowed to access this tenant`
  ([sessions_controller.rb:190](../../app/controllers/sessions_controller.rb#L190)) — decide
  whether the post-token check is needed or the invite gate genuinely covers it, and either
  implement or replace the TODO with a comment explaining why it's safe.
- **Enforce 2FA at login for all providers** (decided). Today the verify-2fa redirect only
  fires for `provider == 'identity'`
  ([sessions_controller.rb:56-64](../../app/controllers/sessions_controller.rb#L56-L64)), so
  a GitHub user on a `require_2fa` tenant is forced through TOTP enrollment that their logins
  never check — the requirement is bypassable by choosing the OAuth login path, and GitHub's
  OAuth exposes no MFA claims that would let us verifiably delegate instead. Remove the
  provider condition: any user with `otp_enabled` gets the verify-2fa prompt after the OAuth
  callback, matching the GitLab default (their `allow_bypass_two_factor` equivalent — a
  per-tenant "trust this provider's MFA" setting — can come later if an operator asks).
  Reverification is unaffected: step-up gates read only `reverified_at_#{scope}` session
  keys, which login-time TOTP never writes, and both flows already share the same
  `otp_failed_attempts` lockout counter. Do NOT seed `reverified_at_*` at login — the
  resulting double-prompt (login, then first sensitive action) is the existing behavior for
  email/password users, and seeding would silently disable all step-up gates for the first
  hour of every session. Tests: GitHub login with TOTP enabled prompts; without TOTP doesn't;
  failed attempts at login and `/reverify` share the lockout.

Beyond the integration suite, there is **no E2E or manual-test coverage of signup at all** —
`e2e/tests/auth/` contains only login specs, and `test/manual/` has no signup/activation/2FA
checklist. Add a Playwright spec for the happy path (invite link → email/password signup →
confirm email → 2FA setup → land in collective; TOTP codes can be computed in-test with an
otplib-style helper) and a manual-test checklist for the cross-device variants that E2E can't
exercise well.

## Other friction observed (smaller, optional)

- **/activate doesn't live-update.** After clicking the email link (possibly in another tab),
  the user must manually refresh `/activate`. A small Stimulus poller (or Turbo refresh) that
  checks confirmation status and updates the checklist would remove a "did it work?" moment.
- **Email-confirmed page is a dead end cross-device.** The confirmation success page could say
  "Return to the tab/device where you were signing up" — or better, offer a "Continue" link
  that logs the flow forward when the session is present.
- **Checklist ordering**: email confirmation has a wait-for-email delay; showing it first and
  letting the user do 2FA while waiting is already possible, but the copy could encourage it.

## Suggested phasing

1. **Phase 1 — invite acceptance fix** (Problem 1). Highest impact; it's a correctness bug, not
   polish. Includes the integration tests for the full invite journey.
2. **Phase 2 — 2FA mobile UX** (Problem 2, items 1-4). Small view-layer changes, independently
   shippable.
3. **Phase 3 — OAuth test coverage + 2FA-at-login for all providers** (Problem 3). One
   deliberate behavior change (the verify-2fa provider condition); the rest is test coverage
   that may surface bugs which become their own fixes.
4. **Phase 4 (separate plan if pursued)** — alternative 2FA methods (email codes or passkeys),
   live-updating /activate.

## Open questions

- Should accepted invites become single-use or remain reusable? Tracking acceptance (Phase 1,
  item 6) is a prerequisite either way.
- Do we want `require_2fa` to default on for new tenants given the mobile friction, or soften
  it until Phase 4 lands an easier method?
