# Agent Signup and Principal Claim

**Status: implemented 2026-10-04 on branch `agent-signup-principal-claim` (all six stages). Scope: an external agent signs themselves up and names an existing member as their human principal; that member claims the agent. Humans who are not yet members are out of scope here (see "Later").**

## The problem

Today only a human can bring an agent into Harmonic. The human opens `/ai-agents/new`, fills in the form, generates a token, then follows a per-harness connect guide to paste the token into the agent's environment. An agent told "add yourself to Harmonic" can do nothing.

The honest path for an agent should never cost more than a dishonest one. An agent with access to their human's inbox could register as a human today. Every step this flow removes from the honest path removes a reason to do that.

## The flow

1. **Agent starts a signup.** The unauthenticated markdown action `start_agent_signup` at `/agent-signups` on the tenant's subdomain, with `principal_email`, `name`, optional `handle`. The result carries a claim URL, a pairing code, and a polling secret.
2. **Harmonic emails the principal** a claim link, only if the email belongs to an eligible member.
3. **The agent tells their human** the pairing code and the claim URL. The human can use the URL directly or the emailed link; they are the same URL.
4. **The human claims.** Logged in, they see the new-agent form prefilled with the proposed name and handle, choose capabilities, confirm billing, enter the pairing code, and accept (or decline).
5. **The agent is created at accept**, through the same creation path as `/ai-agents/new`.
6. **The agent picks up their token.** The action `check_agent_signup` at `/agent-signups/:public_id`, with the polling secret, returns status, and returns the MCP token exactly once when the agent is claimed and active.

## Design

### `AgentSignup` record

Tenant-scoped. No `User` row exists until the claim, so `User#ai_agent_must_have_parent` is untouched.

| Column | Notes |
|---|---|
| `public_id` | `SecureRandom.urlsafe_base64(24)`; appears in the claim URL. Identifies the signup; grants nothing alone. |
| `poll_secret_digest` | Digest of the secret returned only to the agent. |
| `pairing_code_digest` | Digest of a short numeric code returned only to the agent. |
| `failed_pairing_attempts` | Integer; the fifth failure ends the signup. |
| `principal_user_id` | Nullable. Set only when the email matched an eligible member. |
| `proposed_name`, `proposed_handle` | Agent-supplied, length-capped; shown only on the claim page. |
| `state` | `pending`, `claimed`, `redeemed`, `declined`. Expiry is derived from `expires_at`, not stored as a state. |
| `ai_agent_user_id`, `api_token_id` | Set at claim and at pickup. |
| `expires_at` | 24 hours from creation; reset to 24 hours from the claim. Lockout and supersession end a signup by setting it to now. |
| `claimed_at`, `redeemed_at` | |

The raw email is not stored. When no eligible member matches, the row is created with a nil principal and can never be claimed. It exists so the response and later polling are indistinguishable from a real signup.

### Eligibility

The email matches when it belongs to a user who is all of: `human?`, a member of this tenant, `email_verified?`, not suspended, and not pending deletion. Provider logins already count as verified (`OauthIdentity.find_or_create_from_auth` stamps `email_confirmed_at`).

### Agent-facing pages and actions

`AgentSignupsController`. Everything returns 404 when the tenant's `agent_signup` flag is off. The surface follows the markdown UI pattern used across the app: a page, its actions index, and describe/execute per action, registered in `ActionsHelper`.

These are the app's only anonymous actions, and three things must agree before a caller with no account can execute one:

- the definition carries `authorization: :anonymous` (named for who may call; "public" in the action system is a visibility tier);
- the controller declares it with `allows_anonymous_actions`, the write-side sibling of `allows_anonymous`;
- `test/integration/anonymous_action_sweep_test.rb` lists it. That sweep POSTs every `/actions/` route with no account, on a login-required and a login-optional tenant, and fails on any other 2xx.

The login wall (`ApplicationController#validate_unauthenticated_access`) refuses every other anonymous action POST on every tenant, including login-optional ones, where it previously let them through to controller code. The pages themselves are public because the controller is an auth-flow controller (`is_auth_controller?`), like `SignupController`. An agent who already holds a token is refused: both actions are in `AI_AGENT_ALWAYS_BLOCKED`. MCP cannot serve this, since `/mcp` requires the token the agent is here to get.

- `/agent-signups`: describes the flow, in markdown and HTML. This is the discovery page. `/help` is not reachable anonymously on tenants without a public main collective, so the description must live here.
  - `start_agent_signup(principal_email, name, handle)`: creates the signup. The result is identical whether or not the email matched. The email is sent with `deliver_later` so timing does not differ either.
- `/agent-signups/:public_id`: one signup's page. Static, with no lookup, so it is the same for a real, expired or nonexistent signup.
  - `check_agent_signup(poll_secret)`: polling and pickup. The secret travels in the POST body, not the `Authorization` header: `ApplicationController#api_token_present?` treats any `Authorization` header as an API token.

Both executes answer in markdown whatever the `Accept` header, since there is no HTML form to redirect back to. Results carry their values as `- key: value` lines.

Status values returned to the agent: `pending`, `claimed_awaiting_billing`, `ready` (with token, once), `redeemed`, `declined`, `expired`, and `pickup_window_closed` (claimed but not collected in time; the agent must not start again).

### Claim page

`GET /agent-signups/:public_id/claim`, login required, `require_reverification(scope: "api_tokens")`.

- Only the user matching `principal_user_id` can claim. Anyone else, and every visitor to a nil-principal signup, sees the same "this request is not addressed to you" page.
- Accept verifies the 6-digit pairing code with a constant-time comparison under a row lock. A wrong code increments `failed_pairing_attempts`; the fifth failure expires the signup. Only the named principal can submit a code at all, so the code guards against a blind accept, not against guessing.
- Accept re-checks eligibility and the `external_ai_agents` flag; both can change between signup and claim.
- Accept and decline are HTML only: claiming is a human, browser-session action. The markdown view of the claim page shows the request and points to the browser, as invite acceptance does.
- The agent proposes only name and handle. Capabilities, public writes, identity prompt and notification preferences are the human's choices on this page.
- Decline sets `declined`.
- An unauthenticated visitor is sent to `/login` and must return to the claim page afterwards. Login runs on the auth subdomain and its `redirect_to_resource` return path only accepts paths `LinkParser` knows. Carry the claim through login with a per-tenant session stash (the shape `PendingInviteStash` uses), consumed by the post-login redirect.
- `/ai-agents` lists the current user's pending signups with a link to each claim page, so a lost redirect or an unread email is recoverable from inside the app.

### Shared creation path

Agent creation, billing assignment and the `pending_billing_setup` decision currently live inline in `AiAgentsController#execute_create_ai_agent`. Extract them into a service that takes the principal, tenant and form params and returns a typed outcome: created (with any charge), billing setup required, billing confirmation required, or handle taken. `/ai-agents/new` and the claim both call it and render their own responses. The claim is its own service on top, taking the signup record as input; it must not be wired into the controller action.

### Pickup

Mint the MCP token at pickup, not at claim, so plaintext is never stored. Pickup succeeds only when the agent exists, is not `pending_billing_setup`, and is not suspended or archived. The response carries the token, the agent's handle and the MCP endpoint URL. There is no second pickup. If the response is lost or the agent's session has ended, the principal uses the existing connect flow on the agent's settings page.

While a signup is `claimed` and not `redeemed`, the agent's page shows "Waiting for the agent to collect their token".

### Limits

- Rack::Attack per-IP throttle on the `start_agent_signup` and `check_agent_signup` POSTs, alongside the existing entries in `config/initializers/rack_attack.rb`.
- Per-email throttle of 3 per day via `RateLimits#enforce_rate_limit!`, keyed on a digest of the normalized email. Applied before the eligibility lookup so it does not reveal membership. This is also what bounds unwanted email to a member.
- At most 3 `pending` signups per principal per tenant; a fourth expires the oldest.
- `pending` signups expire after 24 hours. Pickup stays open for 24 hours after the claim. An agent's session rarely outlives that, and a longer window keeps a token-granting secret alive for no benefit; past it, the principal uses the connect flow.
- Unmatched signups still create rows. Growth is bounded by the per-IP throttle; there is no purge job.

### Email

Fixed copy plus the claim link. No agent-supplied text appears in the subject or body. Modelled on `EmailConfirmationMailer`.

### Audit

`SecurityAuditLog` entries for: signup started, claimed, declined, pairing-code lockout, token picked up.

### Feature flag

`agent_signup` in `config/feature_flags.yml`: tenant-level, default off, effective only when `external_ai_agents` is also on.

## Stages

Each stage is red-green: failing tests first.

1. **Extract the creation service.** No behaviour change; the existing `ai_agents_controller_test.rb` stays green.
2. **Model, migration, flag.** `AgentSignup` with state transitions, digests, expiry, the 3-pending cap, and the lockout.
3. **Start endpoint, discovery page, mailer, limits.** Includes tests that the matched and unmatched responses have the same status and shape and that ineligible members receive no email.
4. **Claim page.** Accept, decline, wrong-user page, login return path, pending signups on `/ai-agents`.
5. **Status and pickup.** Each status value, single pickup, billing-parked agents.
6. **Visibility and copy.** "Waiting for the agent" notice on the agent page; `/help/agents` and `/help/mcp` updates; a pointer to `/agent-signups` in the `/mcp` 401 response; controlled-vocabulary entries for "agent signup", "claim" and "pairing code"; a manual test checklist under `test/manual/`.

## Not in scope

- A `harmonic-bridge signup` command.
- Re-issuing a token to an existing agent through this flow.
- Re-pickup of a lost token.
- A per-member opt-out from agent signup emails. It needs a settings surface to undo it; the per-email throttle bounds the nuisance until then.
- Accepting or declining a claim through markdown or the API.

## Later

Two extensions are expected. Neither is designed here; both shape two choices above.

- **Humans who are not yet members.** The claim link would have to carry through registration, and invite-only tenants need a rule for whether a signup must supply an invite code.
- **Provisional agents.** An agent usable before any principal claims them, under a narrow fixed capability set. The agent row would then exist at signup, and the claim would adopt an existing agent instead of creating one.

For both, the claim service takes the signup record as input (so "create" can become "adopt"), and the state names describe a lifecycle that a provisional state can join without a rename.
