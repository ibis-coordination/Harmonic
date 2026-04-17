# Stripe AI Gateway & Usage-Based Billing

## Overview

This plan covers **Layer 2** of Harmonic's billing system: prepaid credit-based billing for AI Agent LLM usage via Stripe's AI Gateway. Layer 1 (the $3/month per-identity subscription) is fully implemented — see `docs/BILLING.md` for details.

**Layer 2 concept**: Users who run AI Agents must fund a prepaid credit balance before usage can occur. There is no after-the-fact billing for token usage — users pay upfront and costs are drawn down as agents run. Implemented using [Stripe Billing Credits](https://docs.stripe.com/billing/subscriptions/usage-based/billing-credits) (Credit Grants). Balance management is handled entirely by Stripe.

**LLM routing**: Stripe's AI Gateway (`llm.stripe.com`) serves as both the LLM routing layer and the metering layer. It accepts OpenAI-compatible HTTP requests, routes to providers (Anthropic, OpenAI, Gemini), and automatically meters token usage per customer. Stripe can reject requests when a customer has no credit remaining.

**Key finding from SDK source**: The gateway is `POST https://llm.stripe.com/chat/completions` with `Authorization: Bearer <stripe_key>` and `X-Stripe-Customer-ID: cus_xxx` headers. Standard OpenAI request/response format. Model names use `provider/model` format (e.g., `anthropic/claude-sonnet-4`).

---

## Status: What's Already Built

The LLM call chain has been fully wired for dual-mode operation. All of the following is implemented, tested, and on the `stripe-integration` branch:

### LLM pipeline (complete)

- **`StripeModelMapper`** (`app/services/stripe_model_mapper.rb`) — maps LiteLLM model names to Stripe gateway format (e.g., `default` → `anthropic/claude-sonnet-4`). Has `to_stripe(model)` and `supported?(model)` class methods. Raises `UnsupportedModelError` for unknown models.

- **`LLMClient`** (`app/services/llm_client.rb`) — accepts `gateway_mode` (`:litellm` or `:stripe_gateway`) and `stripe_customer_id`. In stripe mode: routes to `llm.stripe.com`, maps model via `StripeModelMapper`, sends `Authorization: Bearer <STRIPE_GATEWAY_KEY>` and `X-Stripe-Customer-ID` headers, posts to `/chat/completions` (no `/v1` prefix). Handles 402 (payment required). Raises `ArgumentError` if stripe mode without customer ID.

- **`AgentNavigator`** (`app/services/agent_navigator.rb`) — accepts `stripe_customer_id` param, passes through to `LLMClient.new`.

- **`AgentQueueProcessorJob`** (`app/jobs/agent_queue_processor_job.rb`) — resolves `billing_customer` from agent, stamps `stripe_customer_id` on task run (immutable attribution), passes `billing_customer.stripe_id` (cus_xxx) to `AgentNavigator`. Skips local `LLMPricing.calculate_cost` when stripe gateway is active. Still records token counts locally for dashboards.

- **`AutomationExecutor`** (`app/services/automation_executor.rb`) — billing gate checks for automation-triggered runs. Fails run if agent is pending billing, suspended, archived, or lacks active billing customer.

### Billing infrastructure (complete)

- **`StripeCustomer` model** — polymorphic billable, links users to Stripe customers.
- **`StripeService`** — find_or_create_customer, checkout, portal, webhook handling, quantity sync.
- **Webhook controller** — signature verification, event dispatch.
- **Billing controller** — billing dashboard, checkout flow, resource management.
- **Application-level billing gate** — redirects unsubscribed users.
- **Per-identity subscription** — $3/month per user + agent + collective, with proration, exemptions, cross-tenant support.

### Environment variables (already configured)

- `STRIPE_API_KEY` — restricted key for backend operations
- `STRIPE_WEBHOOK_SECRET` — webhook signature verification
- `STRIPE_PRICE_ID` — recurring Price for $3/month subscription (uses legacy Price API, `price_` prefix)
- `STRIPE_GATEWAY_KEY` — **left blank** (see open questions below)
- `LLM_GATEWAY_MODE` — defaults to `litellm`

---

## Remaining Work: What Needs to Be Built

### Phase A: Credit Balance Management

**`StripeService` additions:**

1. `create_credit_topup_checkout(stripe_customer:, amount_cents:, success_url:, cancel_url:)` — creates a Checkout Session for a one-time payment to add credits. Uses `mode: "payment"` with a dynamically created `Stripe::Price` (`unit_amount: amount_cents, currency: "usd", product: ENV["STRIPE_CREDIT_PRODUCT_ID"]`) and `quantity: 1`. Metadata `{ type: "credit_topup" }` for webhook disambiguation. **Security: amount is NOT stored in metadata** — Credit Grant amount is always derived from `session.amount_total`.

2. `create_credit_grant(stripe_customer:, amount_cents:)` — creates a Stripe Billing Credit Grant. Amount must always be derived from `session.amount_total` (the actual payment amount), never from user-provided data.

3. `get_credit_balance(stripe_customer:)` — fetches available credit balance from Stripe's Credit Balance Summary API. Used for billing page display and pre-flight checks.

**Webhook additions:**

4. `checkout.session.completed` handler must disambiguate by `session.mode`:
   - `mode == "subscription"`: existing behavior (activate subscription)
   - `mode == "payment"` + metadata `type: "credit_topup"`: create Credit Grant using `session.amount_total`. Idempotent — skip if grant with matching `checkout_session_id` metadata already exists.

**New env vars needed:**

- `STRIPE_CREDIT_PRODUCT_ID` — Stripe Product ID (`prod_...`) representing "AI Agent Credits." Create this product once in the Stripe dashboard.
- `STRIPE_MAX_TOPUP_CENTS` — maximum credit top-up amount per transaction (default: $500 / 50000 cents)

### Phase B: Credit Top-Up UI

**Routes:**

- `post "billing/topup" => "billing#topup"` (new)

**`BillingController` additions:**

1. `topup` action — creates checkout session for one-time credit purchase. Server-side validation: amount must be a positive integer in cents, minimum $1 (100 cents), maximum configurable via `STRIPE_MAX_TOPUP_CENTS`. Requires active subscription first.

2. `show` action updates — add credit balance section:
   - Fetch balance via `StripeService.get_credit_balance`
   - Handle credit top-up checkout return (disambiguate from subscription checkout by `session.mode`)
   - Graceful fallback if balance API fails: "Balance unavailable — try refreshing"

**View updates:**

3. `billing/show.html.erb` — add "AI Agent Credits" section below subscription section:
   - Current credit balance display
   - "Add Funds" button with amount selector
   - Clear messaging when balance is $0.00

4. `billing/show.md.erb` — matching markdown API view

### Phase C: Pre-Flight Balance Check

1. **`AgentQueueProcessorJob`** — before starting a task, call `StripeService.get_credit_balance(billing_customer)`. If balance is zero, fail the task with error: "Insufficient credit balance. Add funds at /billing before running agents." This is best-effort — the gateway 402 is the authoritative enforcement. The app-level check provides a better error message.

2. **Agent page warnings** — when `stripe_billing` enabled and credit balance is zero:
   - `ai_agents/index.html.erb` — billing/credit status banner
   - `ai_agents/new.html.erb` — warning: "Add funds to run agents" (agent creation is free)
   - `ai_agents/run_task.html.erb` — disable submit with message pointing to `/billing`

### Phase D: Stripe Gateway Activation

1. Obtain `STRIPE_GATEWAY_KEY` (requires AI Gateway permission in Stripe restricted key UI)
2. Set `LLM_GATEWAY_MODE=stripe_gateway` in production
3. Smoke test: agent run → request goes to `llm.stripe.com` → credits drawn down → verify in Stripe dashboard

---

## Open Questions

### 1. Stripe AI Gateway availability

The plan notes from March 2026 state that `llm.stripe.com` appeared to still be in preview/beta — there was no "AI Gateway" permission available in Stripe's restricted key UI. **Before starting any Layer 2 work, verify the gateway is GA and the restricted key permission exists.** The entire implementation depends on this.

### 2. Pricing Plans vs legacy Prices

The original plan used Stripe Pricing Plans (`bpp_` prefix) with `checkout_items`. The actual Layer 1 implementation pivoted to the legacy Price API (`price_` prefix) with `line_items` and `mode: "subscription"`. The credit top-up checkout should use the same legacy approach for consistency (`mode: "payment"` with a dynamically created Price).

### 3. `LLM_GATEWAY_MODE` granularity

Currently a global env var. Should it be a feature flag instead? A per-tenant flag would allow rolling out the gateway to specific tenants first. However, this adds complexity — the LLM pipeline currently reads the env var at construction time, not from tenant context.

### 4. Partial credit exhaustion during multi-step tasks

If a task has multiple LLM steps and credits run out mid-task, subsequent steps get 402s from the gateway. The current `LLMClient` handles 402 by returning a "Payment required" error, which would fail the current step. The navigator would then record the partial result. Is this acceptable, or should there be a minimum balance threshold check?

### 5. Model map completeness

`StripeModelMapper` currently maps only 5 models. When the gateway goes live, the map needs to include all models the app supports. Models not in the map raise `UnsupportedModelError` at construction time, which fails the task. Consider whether unmapped models should fall back to litellm instead of failing.

---

## Reference

### Stripe Documentation

- [Billing for LLM tokens](https://docs.stripe.com/billing/token-billing) — AI Gateway concept, metering, prepaid credit support
- [Billing Credits](https://docs.stripe.com/billing/subscriptions/usage-based/billing-credits) — Credit Grants, prepaid balance management, automatic drawdown
- [Set up billing credits](https://docs.stripe.com/billing/subscriptions/usage-based/billing-credits/implementation-guide) — Implementation guide
- [Credit Grant API](https://docs.stripe.com/api/billing/credit-grant) — API reference
- [Restricted API keys](https://docs.stripe.com/keys) — Key management and permissions

### Key Files (already implemented)

| File | Layer 2 Role |
|------|-------------|
| `app/services/stripe_model_mapper.rb` | Maps LiteLLM model names → Stripe gateway format |
| `app/services/llm_client.rb` | Dual-mode LLM client (litellm / stripe_gateway) |
| `app/services/agent_navigator.rb` | Passes stripe_customer_id to LLMClient |
| `app/jobs/agent_queue_processor_job.rb` | Billing gate, customer ID threading, run stamping |
| `app/services/automation_executor.rb` | Billing gate for automation-triggered runs |

### Key Files (need modification for Layer 2)

| File | Changes Needed |
|------|---------------|
| `app/services/stripe_service.rb` | Add credit grant, balance check, top-up checkout methods |
| `app/controllers/billing_controller.rb` | Add topup action, credit balance display, top-up checkout return |
| `app/views/billing/show.html.erb` | Add credit balance section and top-up UI |
| `app/views/billing/show.md.erb` | Matching markdown view |
| `app/controllers/stripe_webhooks_controller.rb` | No changes — already delegates to StripeService |
| `config/routes.rb` | Add `post "billing/topup"` route |

### Dev Environment

- `LLM_GATEWAY_MODE=litellm` — all LLM calls go through local LiteLLM, no Stripe gateway involvement
- `stripe_billing` feature flag defaults to off per tenant
- `STRIPE_GATEWAY_KEY` left blank until gateway is GA
