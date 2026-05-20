# Bill humans with API tokens at $3/month

> **Implementation status (handoff note for the next review pass)**
>
> All work below is **implemented but UNCOMMITTED** on branch `signup-invite-gate-ux` (last commit: `5904c13`). Run `git status` to see the touched files. The plan below has been amended where the implementation deviated.
>
> **Three notable deviations from the original plan**:
>
> 1. **Token creation now goes through Stripe Checkout BEFORE the token exists**, not after. Original plan was auth-time gate only (token created freely, just inert until billed). User requested stronger UX: clicking "Create Token" with no subscription redirects to Stripe; token is created in a new `finalize` action only after `handle_checkout_return` confirms payment. New route: `GET /u/:user_handle/settings/tokens/finalize`. Pending token params live in `session[:pending_token_creation]`.
> 2. **`confirm_billing` checkbox is gone**. Stripe Checkout IS the confirmation. The form just shows a notice and submits.
> 3. **Dev 2FA bypass shipped alongside** ([app/models/omni_auth_identity.rb](../../app/models/omni_auth_identity.rb)) so test accounts don't need real TOTP setup. Quadruple-guarded: `Rails.env.development?` + `!Rails.env.production?` + `ENV["DEV_2FA_BYPASS_CODE"]` set + code matches. Value lives only in operator's local `.env`.
>
> **Key edge cases handled** (each has a test):
> - Pending AI agent loophole: a parent with an unbilled pending agent CANNOT create a token for that agent (the API auth gate exempts agent-owned tokens, so this would otherwise reopen the loophole). Both `create` and `execute_create_api_token` refuse with a clear message.
> - Sync gap: `sync_subscription_quantity!` is called in 3 places (`create`, `finalize`, `execute_create_api_token`) via a shared `sync_subscription_for_new_billable!` helper. Without this, an already-subscribed user creating a token wouldn't see their Stripe quantity update.
> - Stale `pending_token_creation` on Stripe cancel: `finalize` clears the session and redirects to settings (not /billing) so the user has a clean slate to retry.
> - Expires_at must be stashed at form-submit time — `duration_param` reads from request params which aren't present on the finalize GET.
> - Billing gate exempts `ApiTokensController` (controller handles its own Stripe redirect; otherwise the gate would intercept the POST and bounce to /billing).
> - Markdown / API surface refuses outright when billing is needed (no Stripe Checkout possible in a browserless surface) — points the parent to set up billing in the browser.
>
> **Open concerns I'd want a second pair of eyes on**:
> - The `return_to` value passed through Stripe → BillingController#handle_checkout_return → safe_return_path? validation. Verified it works for relative paths.
> - The 19 tests in [test/controllers/api_tokens_controller_test.rb](../../test/controllers/api_tokens_controller_test.rb) cover most paths; the full create-→-Stripe-→-finalize integration test was skipped (would require heavy Stripe webhook mocking) — each leg is tested individually.
> - Multi-tab race: documented but not fixed (only the latest `pending_token_creation` survives the session).
> - When `billable_quantity` goes to 0 on token delete, `sync_subscription_quantity!` early-returns (Stripe doesn't allow quantity 0). Pre-existing for agents/collectives, not specific to this change.
>
> **Test state**: 447 tests pass across [test/controllers/api_tokens_controller_test.rb](../../test/controllers/api_tokens_controller_test.rb), [test/integration/api_auth_test.rb](../../test/integration/api_auth_test.rb), [test/integration/api_tokens_test.rb](../../test/integration/api_tokens_test.rb), [test/integration/markdown_ui_test.rb](../../test/integration/markdown_ui_test.rb), [test/integration/billing_gate_test.rb](../../test/integration/billing_gate_test.rb), [test/controllers/billing_controller_test.rb](../../test/controllers/billing_controller_test.rb), [test/models/user_test.rb](../../test/models/user_test.rb), [test/models/omni_auth_identity_test.rb](../../test/models/omni_auth_identity_test.rb), [test/controllers/ai_agents_controller_test.rb](../../test/controllers/ai_agents_controller_test.rb). Sorbet clean.

## Context

The current pricing is "humans free, AI agents and additional collectives $3/month each." This creates an abuse vector: instead of paying $3/month for an AI agent, a user could create a free "human" account, generate an API token for it, and run AI logic through that token — effectively getting an agent at human-account prices (free).

To close the loophole: any human user that has at least one active API token costs $3/month, mirroring AI agent pricing. Humans without tokens stay free. The vast majority of users don't need an API token, so the impact on normal signups is minimal.

## Definitions

- **Active API token**: `deleted_at IS NULL AND (expires_at IS NULL OR expires_at > NOW())` ([api_token.rb:136-148](../../app/models/api_token.rb#L136))
- **External token**: a token not marked `internal: true` (internal tokens are ephemeral per-task tokens issued by the runner; they should not count toward billing)
- **Billable token holder**: a `User` with `user_type == "human"`, **not** a sys/app admin, with at least one active external token in a tenant where `stripe_billing` is enabled

**Sys/app admins are not customers and are exempt from all billing.** They have global roles ([has_global_roles.rb](../../app/models/concerns/has_global_roles.rb)) that mark them as platform operators. This change makes that exemption explicit by short-circuiting `billable_quantity` for admin users.

## Approach

Three pieces:

1. **Billable count**: `User#billable_quantity` adds `+1` when the user is a human with at least one active external token in a billing-enabled tenant. Flat surcharge — owning 5 tokens still adds 1, not 5. (Token quantity is bounded at 50 per user/tenant anyway, and the abuse scenario is solved by gating *any* token access, not by per-token pricing.)

2. **Enforcement**: API requests authenticated by a human-owned token must be rejected when the user is not billing-active. We choose **auth-time gate** over a token-level `pending_billing_setup` column (see "Why auth-time gate" below).

3. **Surface awareness**: token creation form discloses the $3/month cost, `/billing` page includes "API access" as a billable item when the user has active tokens, settings pages explain that tokens activate after billing setup.

### Why auth-time gate (not a `pending_billing_setup` column on `api_tokens`)

The agents/collectives pending pattern fits resources that have a creation step which then needs activation. API tokens are simpler: the question "is this token usable right now?" is answered cleanly by "does the user have active billing?" — we don't need to record a separate per-token state. Benefits:

- No schema migration
- No `activate_pending_resources!` change to flip token flags
- If the user lapses (subscription expires), their tokens automatically stop working without us needing to sweep `pending_billing_setup` back to true
- The token's own `expires_at` and `deleted_at` remain the only token-level state

Trade-off: we lose the explicit "pending" badge in the UI. We compensate with a clear notice on the token's show page when the user is not billing-active.

## Changes

### 1. `User#billable_quantity` adds the token surcharge

**File:** [app/models/user.rb](../../app/models/user.rb)

```ruby
def billable_quantity
  # Sys/app admins are platform operators, not customers — exempt entirely.
  return 0 if sys_admin? || app_admin?

  tenant_ids = billing_tenant_ids
  return 0 if tenant_ids.empty?

  active_billable_agent_count(tenant_ids) +
    active_billable_collective_count(tenant_ids) +
    (counts_self_for_api_access? ? 1 : 0)
end

# True when this human user has at least one active external API token in a
# billing-enabled tenant. AI agents are billed via active_billable_agent_count;
# their tokens are not separately surcharged.
sig { returns(T::Boolean) }
def counts_self_for_api_access?
  return false unless human?
  return false if sys_admin? || app_admin?
  tenant_ids = billing_tenant_ids
  return false if tenant_ids.empty?

  api_tokens.external
    .where(tenant_id: tenant_ids, deleted_at: nil)
    .where("expires_at IS NULL OR expires_at > ?", Time.current)
    .exists?
end
```

Update the comment block above `billable_quantity` to reflect the new rule:

> Humans are free unless they hold an active external API token (same $3/month as an AI agent — closes the loophole where a "human" account could front for agent-style usage). AI agents and additional non-main collectives are always billed. Sys/app admins are exempt from all billing as platform operators.

### 2. API auth-time enforcement

**File:** [app/controllers/api/v1/](../../app/controllers/api/v1/) base controller (or wherever `current_user` is resolved from `ApiToken`)

After the token is validated and `current_user` is set, add:

```ruby
if current_user.human? && current_user.requires_stripe_billing?(current_tenant)
  return render status: :forbidden, json: {
    error: "billing_required",
    message: "Your API token is inactive — set up billing at #{billing_show_url} to activate it.",
  }
end
```

`User#requires_stripe_billing?(tenant)` already exists at [user.rb:566-568](../../app/models/user.rb#L566) and now correctly returns true when `billable_quantity > 0 && !stripe_customer.active?`. With this change, that becomes the gate.

Notes:
- Agents are exempt by `human?` check — agents authenticate as `user_type=ai_agent`; their billing is the parent's responsibility and is gated when the agent is created (existing pending-agent pattern).
- Internal tokens (per-task runner tokens) are exempt because they're issued only for already-active agents, and the agent's own setup state was already verified.

### 3. Token creation requires explicit billing confirmation (mirrors AI agent / collective creation)

**Pattern reference**: AI agent and collective creation already use a `confirm_billing` checkbox + controller check ([ai_agents_controller.rb:332](../../app/controllers/ai_agents_controller.rb#L332), [collectives_controller.rb:633](../../app/controllers/collectives_controller.rb#L633), [collectives/new.html.erb:144](../../app/views/collectives/new.html.erb#L144), markdown views: [ai_agents/new.md.erb:18](../../app/views/ai_agents/new.md.erb#L18)). Token creation should follow the same pattern.

**File:** [app/views/api_tokens/new.html.erb](../../app/views/api_tokens/new.html.erb)

When the form is shown for a human owner on a `stripe_billing`-enabled tenant AND the user is not yet a billable token holder (i.e., this would be their first), add:

- A pricing notice above the submit button: "Creating an API token adds **$3/month** to your subscription, prorated for the current billing period. Tokens activate once billing is set up."
- A required `confirm_billing` checkbox: "I understand this token costs $3/month."

When the user already has an active billable token, the surcharge is already in effect — no checkbox needed; just an info line: "API access is already on your subscription ($3/mo)."

**File:** [app/controllers/api_tokens_controller.rb#create](../../app/controllers/api_tokens_controller.rb#L34)

Before creating the token, when the human owner would become newly billable, require `params[:confirm_billing] == "1"`:

```ruby
if @showing_user.human? &&
   @current_tenant.feature_enabled?("stripe_billing") &&
   !@showing_user.app_admin? && !@showing_user.sys_admin? &&
   !@showing_user.counts_self_for_api_access? &&
   params[:confirm_billing] != "1"
  flash[:alert] = "You must confirm you understand API access costs $3/month."
  redirect_to new_api_token_path(...) and return
end
```

**File:** [app/views/api_tokens/new.md.erb](../../app/views/api_tokens/new.md.erb) (if it exists; mirror agent/collective .md.erb if needed)

Mirror the confirmation language for the LLM-facing markdown variant.

For AI agent token creation: no pricing disclosure needed — the agent itself is already billed, the token is incidental.

### 4. Token show page surfaces "inactive until billing"

**File:** [app/views/api_tokens/show.html.erb](../../app/views/api_tokens/show.html.erb)

When `@showing_user.human? && @showing_user.requires_stripe_billing?(@current_tenant)`, render an inline warning:

> This token is not yet active — set up billing to start using it.

with a link to `/billing`.

### 5. Token deletion triggers `sync_subscription_quantity!`

**File:** [app/controllers/api_tokens_controller.rb#destroy](../../app/controllers/api_tokens_controller.rb#L51)

After the existing `@token.delete!`, call:

```ruby
StripeService.sync_subscription_quantity!(@showing_user) if @showing_user.human? && @showing_user.stripe_customer&.active?
```

So a user who deletes their last token sees the surcharge drop on the next invoice.

Alternative: add an `after_destroy`/`after_update` callback on `ApiToken` for cleanliness. The controller-level call is fine for now since deletion happens in exactly one place.

### 6. `/billing` page shows the API surcharge on the user row

**File:** [app/views/billing/_inventory_table.html.erb](../../app/views/billing/_inventory_table.html.erb)

Modify the user row's price cell to reflect the new rule:

```erb
<td style="text-align: right;">
  <% if @current_user.counts_self_for_api_access? %>
    $3/mo <span class="pulse-muted">(API access)</span>
  <% else %>
    <span style="color: var(--color-fg-muted);">free</span>
  <% end %>
</td>
```

No separate "API access" line — it's tied to the user's own row since the surcharge is on the human, not on individual tokens. (Token count is bounded at 50 per tenant; per-token pricing would be misleading.)

Mirror the change in [app/views/billing/show.md.erb](../../app/views/billing/show.md.erb) — the user row currently hardcodes "free"; make it show "$3/mo (API access)" when applicable.

### 7. Tests

**File:** `test/models/user_test.rb`

- `billable_quantity` is 0 for a human with no tokens (existing behavior preserved)
- `billable_quantity` is 1 for a human with 1 active external token
- `billable_quantity` is 1 for a human with 5 active external tokens (flat, not per-token)
- `billable_quantity` doesn't count internal (runner-issued) tokens
- `billable_quantity` doesn't count expired or deleted tokens
- `billable_quantity` doesn't count tokens in non-billing tenants
- `counts_self_for_api_access?` returns false for AI agents (even if they have tokens)
- `counts_self_for_api_access?` returns false for sys_admin and app_admin users (even with tokens)
- `billable_quantity` is 0 for a sys_admin / app_admin user, even with agents/collectives/tokens
- `stripe_billing_setup?` becomes false after creating a first token on a billing tenant

**File:** `test/integration/api_v1_*_test.rb` (or wherever API auth is tested)

- Authenticated request from a human-owned token returns 403 with `error: "billing_required"` when the user has no active subscription
- Same request returns 200 when the user has an active subscription
- AI-agent-owned tokens work regardless of human's personal billing state (only the agent's parent's subscription matters, which is enforced elsewhere)
- Internal tokens are not affected

**File:** `test/controllers/api_tokens_controller_test.rb`

- Token deletion calls `StripeService.sync_subscription_quantity!` for a human owner with an active subscription
- Token creation page shows the $3/mo disclosure when stripe_billing is enabled and user is human
- Token creation page does NOT show pricing when stripe_billing is disabled

**File:** `test/controllers/billing_controller_test.rb`

- `/billing` shows "$3/mo (API)" for a human with active tokens but no agents or extra collectives
- `/billing` total includes the API surcharge

**File:** `test/integration/billing_gate_test.rb`

- The billing gate fires on the next HTML navigation after a human creates their first API token (existing gate behavior — confirms the pattern works end-to-end with the new billable rule)

## Files to modify

| File | Change |
|---|---|
| `app/models/user.rb` | Add `counts_self_for_api_access?`; update `billable_quantity` |
| `app/controllers/api/v1/...` | Gate API auth on `requires_stripe_billing?` for human-owned tokens |
| `app/controllers/api_tokens_controller.rb` | Call `sync_subscription_quantity!` on token destroy |
| `app/views/api_tokens/new.html.erb` | Pricing disclosure for human token creation |
| `app/views/api_tokens/show.html.erb` | "Inactive until billing" warning |
| `app/views/billing/_inventory_table.html.erb` | User row shows "$3/mo (API)" when applicable |
| `app/views/billing/show.html.erb` | Update copy to mention API access as a billable category |
| `app/views/billing/show.md.erb` | Mirror the HTML view changes |
| `test/models/user_test.rb` | New billable_quantity tests for the token cases |
| `test/integration/api_v1_*_test.rb` | API auth gate tests |
| `test/controllers/api_tokens_controller_test.rb` | Creation + deletion side-effect tests |
| `test/controllers/billing_controller_test.rb` | /billing display tests |

## Existing code to reuse

- `User#requires_stripe_billing?(tenant)` ([user.rb:566](../../app/models/user.rb#L566)) — already returns true when `billable_quantity > 0 && !active subscription`. No change needed; the new rule plugs in cleanly.
- `StripeService.sync_subscription_quantity!` ([stripe_service.rb](../../app/services/stripe_service.rb)) — already handles quantity changes when called.
- Billing gate's `session[:billing_return_to]` (recent change in [application_controller.rb](../../app/controllers/application_controller.rb)) — the user creates a token, gets redirected to /billing, completes Stripe, lands back on the token settings page.

## Migration: existing humans with active tokens

There are no current paying users, but existing dev/test environments may have humans with active tokens. After this change:

- Their `billable_quantity` becomes ≥1.
- Their tokens stop working via the API gate until they set up billing.
- On their next HTML navigation in the browser, the billing gate fires and they get redirected to `/billing` (with the existing return_to + flash UX).

This is acceptable since there are no production paying users. If we wanted to soften the cutover for future deployments:
- Option A: a one-time grace window where tokens still work for N days while a flash banner warns the user to set up billing.
- Option B: revoke all human-owned tokens at deploy time and let users recreate them (less surprising for the API consumer, but disruptive).

**Recommendation: ship straight, no migration code.** If the dev DB has stale tokens, manually delete them or set up billing for the affected user during testing.

## Resolved design decisions

| Question | Decision |
|---|---|
| Token form: inline notice or `confirm_billing` checkbox? | **Checkbox + required param** — mirror the existing AI agent / collective pattern ([ai_agents_controller.rb:332](../../app/controllers/ai_agents_controller.rb#L332), [collectives/new.html.erb:144](../../app/views/collectives/new.html.erb#L144)). |
| Inventory table: separate "API access" row or fold into user row? | **Fold into user row** — surcharge is on the human, not on individual tokens. |
| AI agent token forms: pricing disclosure? | **No.** Agent is already billed; the token is incidental. |
| Sys/app admin billing? | **Fully exempt** — they're platform operators, not customers. `billable_quantity` returns 0 for them across the board, not just for tokens. |
| Bot defenses on token creation? | **Separate scope, separate PR.** Tracked in [auth-bot-defenses.md](auth-bot-defenses.md). |

## Verification

1. Write tests first (red-green TDD).
2. Run targeted test files:
   ```bash
   docker compose exec web bundle exec rails test \
     test/models/user_test.rb \
     test/controllers/api_tokens_controller_test.rb \
     test/integration/billing_gate_test.rb \
     test/controllers/billing_controller_test.rb
   ```
3. Manual smoke test in Docker:
   - Sign up fresh human, confirm they remain free with no `/billing` redirect.
   - Visit `/u/<handle>/settings/tokens/new`, confirm pricing notice appears.
   - Submit form to create a token, see the show page warn it's inactive.
   - Try the token against `/api/v1/notes` → get 403 with `billing_required`.
   - Set up billing via `/billing`, confirm `return_to` brings you back to the token settings page.
   - Retry the API call → 200.
   - Delete the token, verify subscription quantity drops on Stripe.
4. Static analysis: rubocop, sorbet, the tenant/debug/secrets checks.

## Out of scope (deferred)

- Per-token pricing (e.g., scaling cost with token count or scopes)
- Admin UI to mark a token billing-exempt (paralleling `billing_exempt` on agents/collectives)
- Grandfather/grace migration for existing tokens
- Bot/rate-limit defenses (separate plan: [auth-bot-defenses.md](auth-bot-defenses.md))
