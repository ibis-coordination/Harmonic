# Billing

This document covers how billing works in Harmonic: what costs money, the collective tier model, and the data flow between Harmonic and Stripe.

Billing is **per-tenant, off by default** via the `stripe_billing` feature flag. Self-hosted instances run with billing disabled — all the gating logic below short-circuits and every feature is available freely. Everything in this doc describes the billing-enabled path used by `harmonic.social`.

## What Costs Money

The unit price is **$3/month per billable identity**. A user has one Stripe subscription whose `quantity` recomputes from the user's billable resources across all billing-enabled tenants:

| Resource | When billable |
|----------|---------------|
| Human user account | Free by default. $3/month when the user holds an active API token or a notification webhook (closes the loophole where a human account could front for agent-style API usage). Holding both still adds only +1 — see `User#counts_self_for_paid_human_features?`. |
| AI agent | $3/month each, while active (not archived, not suspended). |
| Collective | Free by default (`tier = "free"`). $3/month when explicitly upgraded (`tier = "paid"`). Each tenant's main collective is always free. |

**Exemptions.** Sys/app admins are exempt from all billing as platform operators. Any resource can be marked `billing_exempt: true`, which excludes it from the quantity: on an agent or collective it exempts that resource; on a human user it exempts the user's own personal-programmatic-access line (their agents and collectives still bill normally — exemption never cascades). App admins toggle exemption from the admin UI (audit-logged): user/agent exemption on the admin user page, collective exemption on the admin tenant page (`/app-admin/tenants/:subdomain`).

**Why this shape.** A non-zero cost per identity discourages bad actors that rely on free or untraceable accounts (scam accounts, spam accounts, agents-fronting-as-humans). Humans without API access can join freely so the social layer doesn't have a price gate. Self-hosting remains an unrestricted alternative.

**AI agent usage billing.** A separate prepaid credit balance covers LLM token usage. Routing is decided per task at dispatch: agents on a `stripe_billing` tenant that are billed (not system agents) run through Harmonic's LLM gateway, which relays to the Stripe AI Gateway (`llm.stripe.com`) and bills a payer's prepaid balance per call; all other agents (including system agents like Trio) run through LiteLLM at the operator's cost. The payer is resolved per call: a member of the agent's funding collective if it has one, otherwise the agent's principal. Users top up via `/billing/topup` (requires an active subscription). This is independent of the per-identity subscription. See [LLM Gateway](#llm-gateway) for the payer-resolution, ledger, and spend-control mechanics, and the enablement runbook below for turning it on.

Under the hood this uses Stripe's token billing (pricing plans + meter events): the first top-up also subscribes the customer to the LLM-tokens pricing plan (`STRIPE_PRICING_PLAN_ID`), which is what turns metered usage into billing — usage draws down credit grants (top-ups plus any included-usage credits the plan grants), and overage past the balance invoices at cycle end with the plan's markup. Dispatch refuses gateway tasks for customers without the plan subscription so usage can never run unbilled.

## Collective Tier State Machine

Every collective has a `tier` column with three states. Paid features (automations, Trio AI assistant, file attachments) require the paid tier.

```
   ┌─────────────────────────── upgrade!(actor:) ──────────────────────────────┐
   ▼                                                                            │
[free] ───── upgrade!(actor:) ─────► Stripe Checkout ──webhook──► [paid] ──── downgrade!(actor:) ──┐
   ▲                                                                │                              │
   │                          subscription cancel / payment fail ───┘                              │
   │                                       ▼                                                       │
   │                                   [lapsed] ──── subscription restored (auto) ──► [paid]       │
   │                                       │                                                       │
   └─────────────────── downgrade!(actor:) ┴───────────────────────────────────────────────────────┘
```

- **`upgrade!(actor:)`** — owner-only. If the actor has an active Stripe customer (or the collective is billing-exempt, or the actor is an admin), flips inline. Otherwise raises `BillingRequired`; the controller redirects to Stripe Checkout, and `confirm_upgrade!` runs on completion.
- **`mark_lapsed!`** — fired by `customer.subscription.deleted` and inactive `customer.subscription.updated` events (and by quantity sync when it discovers the subscription is inactive on Stripe's side). Just flips the column. Runtime gates (`Collective#tier_unlocks_paid_features?`, the automation dispatcher / scheduler / webhook receiver) skip lapsed collectives so paid features pause without touching configuration.
- **`restore_from_lapsed!`** — automatic when the user's Stripe subscription becomes active again. All of the user's lapsed collectives restore at once. No extra clicks.
- **`downgrade!(actor:)`** — owner-only. Disables enabled automations, clears paid feature flags, deactivates the trio agent. Clean slate for any future re-upgrade.

Allowed transitions are enforced by `VALID_TIER_TRANSITIONS` and a validation; the model raises on invalid moves.

## Data Flow with Stripe

Harmonic uses Stripe Checkout for payment collection, the Stripe billing portal for user-facing subscription management, and Stripe webhooks for state sync.

**Outbound (Harmonic → Stripe):**

- **Checkout sessions** — created by `StripeCheckoutService` (collective upgrade flow, with `metadata.collective_id` so the webhook knows which collective to confirm) and `BillingController#setup` (initial per-user billing setup). Stripe handles payment collection and returns the user via `success_url`.
- **Subscription quantity sync** — `StripeService.sync_subscription_quantity!(user)` recomputes the user's total billable quantity and writes it to the Stripe subscription item. Called after every state change that affects quantity (agent create/archive, collective upgrade/downgrade, API token issuance/revocation, notification webhook create/delete, billing-exempt toggle). The pattern is *recompute, don't increment* — eliminates race conditions and makes the daily reconciliation job a true safety net. When the quantity drops to zero, the subscription is cancelled with `prorate: true, invoice_now: true` so unused time (and any pending proration credits) lands on the customer balance instead of being forfeited; the balance offsets a future resubscription.
- **Billing portal sessions** — created on demand at `/billing/portal` so the user can update payment method, cancel, etc. inside Stripe's hosted UI.
- **Credit grants** — for the AI agent usage layer, created on top-up checkout completion.

**Inbound (Stripe → Harmonic):**

Webhook events are received at `/stripe/webhooks`, verified via HMAC signature, and dispatched by `StripeService`:

| Event | Effect |
|-------|--------|
| `checkout.session.completed` | Activates the `StripeCustomer` and stores the subscription ID. If `metadata.collective_id` is set, calls `confirm_upgrade!` on that collective. If the customer was previously inactive, auto-restores all of the user's lapsed collectives. |
| `customer.subscription.updated` | Tracks active state (`active` / `trialing` / `past_due` count as active). On inactive→active transition, restores lapsed collectives. On active→inactive transition, suspends agents and lapses paid collectives. |
| `customer.subscription.deleted` | Same as the active→inactive path above: deactivates the `StripeCustomer`, suspends agents, lapses paid collectives. |
| `invoice.payment_failed` | Logged; no immediate state change (Stripe retries on its own schedule). |

Webhook handlers are idempotent and ignore stale events (e.g., a delayed webhook for a previous subscription doesn't deactivate the user's resources after they've resubscribed).

The synchronous return path from Stripe Checkout (`BillingController#handle_checkout_return`, hit when the user is redirected back to `/billing?checkout_session_id=...`) duplicates the key webhook effects so the user lands on a fully-up-to-date page without waiting for the async webhook. Both paths converge on the same idempotent model methods.

**Reconciliation.** `BillingReconciliationJob` runs daily as a safety net: corrects quantity drift between the database and Stripe, recovers stuck pending agents, etc.

## Gates and Enforcement

Two layers enforce billing at request time:

- **Application-level billing gate** (`ApplicationController#check_stripe_billing_gate`) — redirects a human user without active billing to `/billing` for any human-only surface. Exempts auth controllers, billing controllers, webhooks, API controllers, non-human users, user settings (so users can manage their account before paying), and the API-token and notification-webhook controllers (which run their own Stripe Checkout flows).
- **Collective tier gate** (`Collective#tier_unlocks_paid_features?`) — short-circuits paid-feature access whenever the collective isn't on the paid tier. Used by `trio_enabled?`, `file_attachments_enabled?`, the automation dispatcher, the automation scheduler, the incoming-webhook receiver, and the per-toggle filter in collective settings updates. Always returns true for main collectives and for tenants without `stripe_billing` (self-hosted).

Background workers (agent task execution, automation execution) have their own per-resource billing checks so suspended agents and pending resources don't run.

### Agent task dispatch: two independent gates

`AgentRunnerDispatchService#dispatch` enforces two separate billing gates before an agent task runs on a `stripe_billing` tenant (both skipped for system agents like Trio, which are never charged, and for pool-funded agents — an agent with a funding collective draws from the collective's members rather than a personal billing customer, so the per-call payer resolution in [LLM Gateway](#llm-gateway) replaces both checks). They correspond to the two things a run costs, and a **free account** interacts with them differently — this is the distinction to keep straight:

- **(a) The per-identity Harmonic fee.** The agent's identity must be paid for: `billing_customer&.active? || ai_agent.parent&.billable_quantity&.zero?`. An agent's `billing_customer` is its principal's Stripe customer, so `active?` means the principal holds an active per-identity subscription — the norm. The `billable_quantity.zero?` clause is the **free-account exception**: a principal with nothing billable (an app admin, or an account whose resources are all `billing_exempt`) owes no per-identity fee and so legitimately never opens a subscription (`active?` is false but correct). It is a special case, not a reframe of the gate.
- **(b) LLM token funding.** Unconditional for **every** individually billed agent — free-account or paying alike. Requires that the principal's Stripe customer has a prepaid-credit (pricing-plan) subscription *and* a positive credit balance (`pricing_plan_subscription_id` present, `get_credit_balance > 0`). Tokens are metered through the external Stripe AI Gateway, whose price Harmonic does not set, so gate (a) being waived buys nothing here: a free account with no credits still fails at (b) with "Add credits at /billing."

So: **free account = gate (a) waived (owes Harmonic nothing), gate (b) always applies (LLM tokens come from the gateway).** All Harmonic resources are free for such an account; LLM tokens never are.

**What "free account" is — and is not.** There is no single "free account" boolean. The condition is emergent: `billable_quantity == 0` (see `User#billable_quantity`, which app admins hit unconditionally). Do **not** confuse this with the `billing_exempt` flag: `billing_exempt` on a human zeroes only that human's *own* `+1` personal-programmatic-access line (`counts_self_for_paid_human_features?`); their agents and collectives still bill, so a `billing_exempt` human can have `billable_quantity >= 1` and is *not* a free account. Free accounts are set by app admins (via the exemption toggles and admin status described under [Exemptions](#what-costs-money) above), never self-serve by users.

## LLM Gateway

The LLM gateway is how every billed LLM call reaches Stripe. It has one job — relay OpenAI-compatible requests to `llm.stripe.com` with the right `X-Stripe-Customer-ID` header — and deliberately no policy of its own. Rails decides who pays; the gateway relays and reports usage back.

**Architecture.** The `llm-gateway` service (in `agent-runner/src/gateway/`) is the only holder of `STRIPE_GATEWAY_KEY`; the agent-runner holds no Stripe credentials. Rails exposes three internal endpoints (`app/controllers/internal/llm_gateway_controller.rb`, IP-restricted via `INTERNAL_ALLOWED_IPS`):

| Endpoint | Caller | Purpose |
|----------|--------|---------|
| `POST /internal/llm-gateway/select-payer` | gateway, per task-run call | Resolve the payer for an internal agent task; opens a pending ledger row |
| `POST /internal/llm-gateway/select-payer-for-token` | gateway, per external call | Authenticate an `llm_gateway` API key, check the tenant's `llm_gateway` feature flag, resolve the payer |
| `POST /internal/llm-gateway/record-usage` | gateway, after each call | Complete the ledger row with token counts and cost |

**Payer resolution** (`LLMGateway::PayerResolver`) runs per call, pool-first:

1. If the agent has a **funding collective**, draw uniformly at random from the collective's consenting members who have an active billing customer, pass the balance gate, and are under the collective's draw ceiling. Random-per-call is deliberate: memoryless selection needs no ledger consultation for fairness, no join-time catch-up, and no locking; cost spreads evenly over time.
2. Otherwise the payer is the agent's own **billing customer** (its principal's).

Failures carry wire codes the gateway relays as OpenAI-shaped errors: `no_primary` / `funding_collective_unavailable` (403), `pool_exhausted` / `not_funded` / `balance_exhausted` (402), `spend_cap_exceeded` (429).

**Funding collectives** (`collective_type: "agent_funding"`) are the common-pool mechanism: members pool their own prepaid balances to fund the collective's agents. The type is chosen at creation and immutable, and such collectives are never billable themselves. Joining is consenting to fund (the join page says so) and requires active billing with prepaid credits; lapsed members are skipped in draws; leaving ends participation. Collective admins attach/detach agents from settings; an agent can be attached only while its principal is an active member. The collective never holds funds: each call bills exactly one member's own Stripe balance.

Visibility is deliberately asymmetric. The funding *relationship* is public: every funded agent's profile shows "Funded by ⟨collective⟩" — part of the agent's accountability story. The *pool* is closed: funding collectives are excluded from collective lists and pickers — including a member's own `/collectives` page (`Collective#listable?` is false for non-standard types; members navigate in via the "Funded by" link or by URL) — cannot mint shareable invite links (members join by direct invite only), and their roster and contents have ordinary member-only visibility.

**Usage ledger** (`LLMUsageRecord`). `select-payer` opens a row with `status: "pending"` and returns its `selection_id`; `record-usage` completes it (idempotent per selection). Semantics that other code depends on:

- `occurred_at` is selection time; `completed_at` is when cost landed. **All spend sums anchor on `completed_at`** — `occurred_at` exists for pending-row scans.
- A pending row younger than 15 minutes is a **reservation**: it counts as `GATEWAY_PENDING_RESERVE_CENTS` (default 25) in every spend sum, so concurrent in-flight calls are visible to the controls. Older pending rows deliberately stop reserving — a call whose usage never came back must not pin a payer at zero forever. There is no reaper job and no UI over the ledger yet; stale pending rows are inert and visible only in the database.
- A completed-but-unpriced call (catalog outage, missing rate) keeps `status: "pending"` with its token counts recorded, so a later `record-usage` can price it. Only costed rows are sealed by the idempotency guard. Failed calls finalize as `failed` regardless (nothing billed).
- Rows carry `origin_tenant_id` (not `tenant_id` — payer sums are cross-tenant, matching `StripeCustomer`'s posture) and `funding_collective_id` stamped at draw time, so per-pool attribution survives the agent later changing pools.

Cost is computed from `GatewayModelCatalog`'s per-million-token rates via `LLMGateway::UsageCost`. The gateway reports usage from the response body (non-streaming) or by scanning the SSE stream for the final usage chunk (streaming; it injects `stream_options.include_usage` unless the client explicitly disabled it).

**Balance gate** (`LLMGateway::BalanceGate` + `StripeBalanceSnapshot`). Payers are checked per call without a per-call Stripe fetch: effective balance = last snapshot − ledger spend completed since the snapshot − pending reservations, and the payer is funded while that exceeds `GATEWAY_BALANCE_BUFFER_CENTS` (default 25). Snapshots refresh from Stripe when older than `GATEWAY_BALANCE_SNAPSHOT_TTL_SECONDS` (default 600), are re-verified at most every 30s when a payer first reads as dry (so a stale snapshot can't reject a freshly topped-up customer for long), and are invalidated by top-ups. If Stripe is unreachable a stale snapshot keeps serving; a payer with no snapshot at all fails closed. Stripe's own zero-balance rejection (a relayed 402) remains the authoritative backstop — this gate exists to stop spend *before* the call, not to replace Stripe's answer.

**Spend caps**, both parsed through `MoneyParam` (the only dollars→cents parse; int4 range-checked) and both reset at midnight UTC:

- `users.llm_daily_spend_cap_cents` — per-agent daily total, set by the principal on the agent's settings page; exceeded → `spend_cap_exceeded` (429).
- `collectives.member_daily_draw_cap_cents` — funding-collective ceiling on what its agents may bill any single member per day; a member at the ceiling is skipped in draws (draws by *other* pools don't count against it).

**External ingress.** External agents call `POST https://llm.<HOSTNAME>/v1/chat/completions` (OpenAI-compatible, streaming supported) with an `llm_gateway`-type API key as the Bearer token. Caddy forwards only `/v1/*` to the gateway, so the internal relay path is unreachable from the edge. Rails authenticates the key per call, requires the tenant-level `llm_gateway` feature flag, and resolves the payer through the same pool-first logic. Guardrails: per-key in-memory rate limits (`GATEWAY_EXTERNAL_RPM`, default 20; `GATEWAY_EXTERNAL_RPD`, default 500) and a 1 MB body cap. The `llm_gateway` token type is a pure spend credential — no data access on any other surface; see [/help/api](../app/views/help/api.md.erb) for the token-type model.

## AI Gateway Enablement Runbook

How LLM usage billing turns on for a production tenant. Prerequisite: the Stripe account is enrolled in the AI Gateway preview (`llm.stripe.com`).

**Restricted key permissions.** Two keys, minimal scopes. Every permission maps to a specific code path — when adding a new Stripe API call, extend the matching key's permissions and this table.

`STRIPE_GATEWAY_KEY` — used exclusively as the Bearer token for `llm.stripe.com` requests. Held only by the `llm-gateway` service (the agent-runner sends billed calls there and holds no Stripe credentials):

| Permission | Access | Used by |
|------------|--------|---------|
| Billing → Meter events | Write | Every gateway LLM call (the gateway records token usage as meter events) |

`STRIPE_API_KEY` — all `Stripe::*` API calls from Rails:

| Permission | Access | Used by |
|------------|--------|---------|
| Customers | Write | `find_or_create_customer` (billing setup), email sync on user email change |
| Checkout Sessions | Write | Subscription setup, collective upgrade, credit top-up; `retrieve` on the checkout return path |
| Subscriptions | Write | Quantity sync (`Subscription.retrieve`, `SubscriptionItem.update`), cancel-at-zero-quantity |
| Invoices | Write | Proration invoice create/pay, upcoming-invoice preview, finalizing the final invoice on cancel |
| Products (incl. Prices) | Write | Ad-hoc `Price.create` per credit top-up checkout |
| Credit grants | Write | Credit grant creation on top-up completion |
| Credit balance summary | Read | Dispatch preflight balance check, `billing:gateway_health`, billing page |
| Customer portal | Write | `/billing/portal` session creation |
| PaymentIntents | Write | Off-session charge when the pricing-plan subscription has an amount due at subscribe time |
| Billing (v2 preview: profiles, cadences, intents, pricing plans) | Write | `ensure_pricing_plan_subscription!` — the token-billing preview endpoints; verified working under the restricted key's Billing scopes in test mode, re-verify on the live key |

Webhook verification (`/stripe/webhooks`) uses `STRIPE_WEBHOOK_SECRET` for signature checks — no key permission involved.

**Enable:**

1. **Run the setup script** from any machine (never store the secret key on the server):

   ```bash
   STRIPE_SECRET_KEY=sk_live_... HOSTNAME=<prod HOSTNAME> PRIMARY_SUBDOMAIN=<prod PRIMARY_SUBDOMAIN> \
     ./scripts/stripe-setup.sh
   ```

   `STRIPE_SECRET_KEY` is the account secret key, used only for this run — it is not an app env var and never goes on the server. The webhook URL derives from `HOSTNAME`/`PRIMARY_SUBDOMAIN` exactly as the app's own non-tenant URLs do (or pass an explicit URL as the first argument). The script idempotently creates or verifies the credit product, the $3/month identity price, and the webhook endpoint (printing `STRIPE_WEBHOOK_SECRET` on creation), verifies the pricing plan and gateway key when their env vars are provided, and prints the env-var block plus any remaining dashboard-only steps. Re-run it after each manual step until the manual-steps list is empty.
2. **Dashboard-only steps** (the script prints these with exact instructions):
   - Create the two restricted keys per the permission tables above (`STRIPE_GATEWAY_KEY` → llm-gateway service only; `STRIPE_API_KEY` → Rails only).
   - Create the pricing plan (Dashboard → Pricing plans → Create → "Billing for LLM tokens" template): select the models to offer and set the **markup percentage** — this is the pricing decision. Set its `bpp_...` id as `STRIPE_PRICING_PLAN_ID`.
3. **Ask Stripe to enable zero-balance rejection** (token-billing-team@stripe.com) so Stripe itself refuses requests once a customer's balance is empty. The app-side [balance gate](#llm-gateway) stops most dry-payer calls before they leave Harmonic, but its snapshot-minus-ledger estimate can drift from Stripe's real balance — the relayed 402 is the authoritative backstop. After enabling, smoke-test with a funded customer: rejection reads a different ledger than the credit-balance summary our gate reads, and has been observed refusing funded customers. If that happens, have Stripe disable it and rely on the app-side gate while the account issue is worked out.
4. **Deploy** with the vars set, and enable the `llm-gateway` service by setting
   `COMPOSE_PROFILES=stripe` in the server's `.env` (see the LLM Gateway section of
   docs/DEPLOYMENT.md — do not start it by name like litellm; it must be deploy-managed).
   Ensure `INTERNAL_ALLOWED_IPS` covers the gateway container (use the Docker network CIDR,
   not a single container IP). No behavior changes yet — routing stays on LiteLLM until a
   tenant qualifies.
5. **Verify health:** `rails billing:gateway_health` should show the llm-gateway reachable, both config vars present, and list active customers with balances and subscription status.
6. **Enable the flag:** `tenant.enable_feature_flag!("stripe_billing")` for the target tenant. From the next dispatch, that tenant's billed agents route through the gateway. Before flipping it on a tenant, confirm no *other* tenant already has the flag plus active billing customers — their agents would start requiring credits too.
7. **Smoke test:** top up a small amount at `/billing/topup` (this also creates the pricing-plan subscription), run an agent task, confirm the balance dropped (`billing:gateway_health`) and both the agent-runner and the llm-gateway logged `llm_request` lines with `"gateway_mode":"stripe_gateway"` (the runner's line shows the call reached the gateway; the gateway's line shows it reached Stripe). Full checklist: `test/manual/billing/gateway_enablement.manual_test.md`.

**Model names.** Model names match the Stripe gateway's `provider/model` scheme 1-to-1, and `config/litellm_config.yaml` uses the same names, so an agent's configured model (e.g. `anthropic/claude-sonnet-4.6`) works unchanged whether it routes through the gateway or LiteLLM. `StripeGatewayModelMapper` resolves blank/`default` to its default model and passes `provider/model` names through; names the gateway cannot proxy (local Ollama, Arcee Trinity) fail the task at dispatch with an explanatory error — update the agent's model or route the tenant back to LiteLLM.

**Rollback** (gateway outage, unexpected charges, key compromise):

1. `tenant.disable_feature_flag!("stripe_billing")` — new dispatches route to LiteLLM immediately. Note the blast radius: this disables *all* billing gates for the tenant (subscriptions, paid tiers), not just gateway routing. Acceptable for an incident; restore the flag once resolved.
2. If the key is compromised: revoke it in the Stripe dashboard and unset `STRIPE_GATEWAY_KEY`; in-flight gateway tasks fail with a clear error and can be re-run.
3. Already-purchased credits are unaffected — they sit on the customer's Stripe balance until routing is restored.

## Design Notes

**One subscription per user, cross-tenant.** A single Stripe subscription covers all billing-enabled tenants the user belongs to. `billing_tenant_ids` filters which tenants count.

**Quantity-based subscription.** A single Stripe Price with variable quantity, not a subscription-per-resource. Stripe handles proration, credits, and invoicing.

**Tier is a column, not a derived predicate.** Upgrade is a deliberate user action — never a side effect of toggling a feature. This replaces an earlier model where enabling Trio or file attachments silently moved a collective onto the paid plan (which surprised users).

**Lapse preserves state.** Subscription loss doesn't archive or destroy anything; it just pauses feature access. Restoring billing instantly resumes the prior configuration. Agents are suspended (not deleted) for the same reason — API tokens get revoked because they bypass the application-level gate, but the agent record stays.

**Identity and billing are separate concerns.** Accounts are created at authentication time, not at payment time. The gate prevents app usage until billing is active, but the user record exists immediately.
