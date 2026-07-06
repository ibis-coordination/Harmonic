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

**AI agent usage billing.** A separate prepaid credit balance covers LLM token usage. Routing is decided per task at dispatch: agents whose tenant has `stripe_billing` enabled and whose owner has an active billing customer run through the Stripe AI Gateway (`llm.stripe.com`, billed against the prepaid balance); all other agents (including system agents like Trio) run through LiteLLM at the operator's cost. Users top up via `/billing/topup` (requires an active subscription); Stripe deducts per LLM call, and task dispatch is blocked when the balance is empty. This is independent of the per-identity subscription. See the enablement runbook below.

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

## AI Gateway Enablement Runbook

How LLM usage billing turns on for a production tenant. Prerequisite: the Stripe account is enrolled in the AI Gateway preview (`llm.stripe.com`).

**Restricted key permissions.** Two keys, minimal scopes. Every permission maps to a specific code path — when adding a new Stripe API call, extend the matching key's permissions and this table.

`STRIPE_GATEWAY_KEY` — used exclusively as the Bearer token for `llm.stripe.com` requests (agent-runner):

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
   - Create the two restricted keys per the permission tables above (`STRIPE_GATEWAY_KEY` → Rails and agent-runner; `STRIPE_API_KEY` → Rails only).
   - Create the pricing plan (Dashboard → Pricing plans → Create → "Billing for LLM tokens" template): select the models to offer and set the **markup percentage** — this is the pricing decision. Set its `bpp_...` id as `STRIPE_PRICING_PLAN_ID`.
3. **Ask Stripe to enable zero-balance rejection** (token-billing-team@stripe.com) so the gateway itself refuses requests once a customer's balance is empty — our dispatch preflight checks at task start, not per LLM call, and balance deduction is aggregated periodically rather than real-time.
4. **Deploy** with the vars set. No behavior changes yet — routing stays on LiteLLM until a tenant qualifies.
5. **Verify health:** `rails billing:gateway_health` should show all three vars present and list active customers with balances and subscription status.
6. **Enable the flag:** `tenant.enable_feature_flag!("stripe_billing")` for the target tenant. From the next dispatch, that tenant's billed agents route through the gateway. Before flipping it on a tenant, confirm no *other* tenant already has the flag plus active billing customers — their agents would start requiring credits too.
7. **Smoke test:** top up a small amount at `/billing/topup` (this also creates the pricing-plan subscription), run an agent task, confirm the balance dropped (`billing:gateway_health`) and the agent-runner logged `llm_request` lines with `"gateway_mode":"stripe_gateway"`. Full checklist: `test/manual/billing/gateway_enablement.manual_test.md`.

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
