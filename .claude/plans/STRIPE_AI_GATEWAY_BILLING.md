# Stripe AI Gateway Integration for Agent Billing

## Context

Harmonic's AI agents make LLM calls through LiteLLM, but there's no billing system — usage is tracked but never charged. Stripe's new AI Gateway (`llm.stripe.com`) can serve as both the LLM routing layer AND the billing layer in one integration. It accepts OpenAI-compatible HTTP requests, routes to providers (Anthropic, OpenAI, Gemini), and automatically meters token usage per customer. Stripe pays the LLM providers — no provider API keys needed in production.

**Billing model**: Individual users pay for all AI agents they own (via `parent_id`). Hard gate at agent creation — users must set up billing before creating their first AI agent. Monthly base fee + usage-based token charges. Dual mode — LiteLLM for dev, Stripe gateway for production.

**Signup flow**: User tries to create an AI agent → if `stripe_billing` flag is on and they don't have active billing → redirected to `/billing` (with return URL stored in session) → set up payment via Stripe Checkout (monthly base + metered usage subscription) → on return, billing controller verifies checkout session synchronously via Stripe API (don't wait for webhook) → user is redirected back to agent creation form → can now create and run agents. Webhook also arrives and is idempotent.

**Key finding from SDK source**: The gateway is `POST https://llm.stripe.com/chat/completions` with `Authorization: Bearer <stripe_key>` and `X-Stripe-Customer-ID: cus_xxx` headers. Standard OpenAI request/response format. Model names use `provider/model` format (e.g., `anthropic/claude-sonnet-4`).

**Approach**: Red-green TDD — write failing tests first, then implement to make them pass. Each phase starts with its test file(s).

### Data Model Design

Stripe customers are decoupled from users via a polymorphic `stripe_customers` table. This supports future group-level billing (collectives, tenants) while keeping the MVP simple (users only).

```
stripe_customers
├── id (PK)
├── billable_type (string) — "User", future: "Collective", "Tenant"
├── billable_id (bigint)
├── stripe_id (string, unique) — the Stripe cus_xxx ID
├── stripe_subscription_id (string)
├── active (boolean, default false)
└── timestamps

users (AI agents only)
└── stripe_customer_id (FK → stripe_customers.id) — who pays for this agent

ai_agent_task_runs
└── stripe_customer_id (FK → stripe_customers.id) — who paid for this run (immutable)
```

**Resolution chain**: `task_run.stripe_customer.stripe_id` → `cus_xxx` for the `X-Stripe-Customer-ID` header.

**Why this design**:
- **Decoupled from parent_id**: An agent's billing customer can differ from its parent user (future: collective pays for agents it sponsors).
- **Immutable run attribution**: `stripe_customer_id` on task runs is stamped at creation. Ownership transfer only affects future runs.
- **Polymorphic extensibility**: Adding collective or tenant billing later = new `StripeCustomer` records with different `billable_type`, no schema changes.
- **MVP simplicity**: For now, only `User` billables exist. All resolution logic uses this single path.

---

## Phase 1: Foundation

### 1.1 Add `stripe` gem
- **Gemfile** — add `gem "stripe"` near other service gems (~line 121)
- Run `bundle install` inside Docker

### 1.2 Migration: Stripe customers table and FKs
- **New file**: `db/migrate/YYYYMMDDHHMMSS_create_stripe_customers.rb`
  - Create `stripe_customers` table: `billable_type` (string, not null), `billable_id` (bigint, not null), `stripe_id` (string, unique index), `stripe_subscription_id` (string), `active` (boolean, default false), timestamps
  - Add polymorphic index on `[billable_type, billable_id]` (unique)
  - Add `stripe_customer_id` (bigint, nullable, FK → stripe_customers.id) to `users` — for AI agents to know who pays
  - Add `stripe_customer_id` (bigint, nullable, FK → stripe_customers.id) to `ai_agent_task_runs` — immutable billing attribution per run

### 1.3 Environment variables
- **`.env.example`** — add after LLM section:
  - `STRIPE_API_KEY` — Stripe restricted key (permissions: Customers write, Checkout Sessions write, Customer portal write, Subscriptions read, Invoices read, Prices read, Billing meters read)
  - `STRIPE_GATEWAY_KEY` — Separate restricted key for AI Gateway requests only (used as Bearer token to `llm.stripe.com`). **Note**: AI Gateway permission not yet available in Stripe restricted key UI as of March 2026 — leave blank for dev.
  - `STRIPE_WEBHOOK_SECRET` — webhook signature verification
  - `STRIPE_PRICING_PLAN_ID` — Stripe Pricing Plan ID (`bpp_...` prefix) that bundles the monthly base fee + metered token usage into a single plan. Replaces the previous separate `STRIPE_BASE_PRICE_ID` + `STRIPE_METERED_PRICE_ID` approach — Stripe's newer Pricing Plans system combines rate cards (usage-based) and license fees (recurring) into one object.
  - `LLM_GATEWAY_MODE=litellm` — `litellm` (default) or `stripe_gateway`
- **Key separation rationale**: The gateway key is sent on every LLM request to an external service. Using a separate restricted key limits blast radius if it leaks — it can only access the AI Gateway, not manage customers or subscriptions.
- **Pricing Plans vs legacy Prices**: Stripe's newer billing system uses Pricing Plans (`bpp_` prefix) instead of individual Price objects (`price_` prefix). Pricing Plans group multiple pricing components (rate cards for usage, license fees for fixed recurring charges) into a single entity. Checkout Sessions use `checkout_items` with `type: "pricing_plan_subscription_item"` instead of `line_items` with `price:`. This requires the preview API version header `Stripe-Version: 2025-09-30.preview;checkout_product_catalog_preview=v1`.

### 1.4 Stripe initializer
- **New file**: `config/initializers/stripe.rb` — set `Stripe.api_key` from `STRIPE_API_KEY` env (backend operations only; gateway key is read separately in `LLMClient`)

### 1.5 Feature flag
- **`config/feature_flags.yml`** — add `stripe_billing` (app_enabled: false, default_tenant: false)

### 1.6 StripeCustomer model — RED then GREEN
- **RED**: Write `test/models/stripe_customer_test.rb` first
  - `test "belongs to billable (polymorphic)"`
  - `test "validates uniqueness of billable (type + id)"`
  - `test "validates uniqueness of stripe_id"`
  - `test "active? returns correct status"`
- **GREEN**: `app/models/stripe_customer.rb`
  - `belongs_to :billable, polymorphic: true`
  - `has_many :ai_agents, class_name: "User", foreign_key: "stripe_customer_id"` (agents billed to this customer)
  - `has_many :task_runs, class_name: "AiAgentTaskRun", foreign_key: "stripe_customer_id"`
  - Validations: uniqueness of `[billable_type, billable_id]`, uniqueness of `stripe_id`

### 1.7 Model name mapper — RED then GREEN
- **RED**: Write `test/services/stripe_model_mapper_test.rb` first
  - `test "maps default to anthropic/claude-sonnet-4"`
  - `test "maps claude-sonnet-4-20250514 to anthropic/claude-sonnet-4"`
  - `test "maps claude-haiku-4 to anthropic/claude-haiku-4-5"`
  - `test "maps gpt-4o to openai/gpt-4o"`
  - `test "raises UnsupportedModelError for deepseek-r1"`
  - `test "raises UnsupportedModelError for gemma3"`
  - `test "raises UnsupportedModelError for llama3"`
  - `test "supported? returns true for known models"`
  - `test "supported? returns false for Ollama models"`
- **GREEN**: `app/services/stripe_model_mapper.rb`
  - Maps LiteLLM names to Stripe gateway format
  - `self.to_stripe(model)` and `self.supported?(model)` class methods

### 1.8 User model helpers — RED then GREEN
- **RED**: Add tests in `test/models/user_test.rb`
  - `test "stripe_billing_setup? returns true when user has active stripe customer"`
  - `test "stripe_billing_setup? returns false when user has no stripe customer"`
  - `test "stripe_billing_setup? returns false when stripe customer is inactive"`
  - `test "requires_stripe_billing? returns true when flag enabled and billing not set up"`
  - `test "requires_stripe_billing? returns false when flag disabled"`
  - `test "requires_stripe_billing? returns false when billing already set up"`
- **GREEN**: `app/models/user.rb`
  - `has_one :stripe_customer, as: :billable` (for human users — the customer record they own)
  - `belongs_to :billing_customer, class_name: "StripeCustomer", foreign_key: "stripe_customer_id", optional: true` (for AI agents — who pays)
  - `stripe_billing_setup?` — checks `stripe_customer&.active?`
  - `requires_stripe_billing?(tenant)` — takes tenant param, checks `tenant.feature_enabled?("stripe_billing") && !stripe_billing_setup?`
- **`app/models/ai_agent_task_run.rb`**
  - `belongs_to :billing_customer, class_name: "StripeCustomer", foreign_key: "stripe_customer_id", optional: true`

---

## Phase 2: LLMClient Dual Mode — RED then GREEN

### 2.1 RED: Tests in `test/services/llm_client_test.rb`
- `test "defaults to litellm gateway mode"`
- `test "uses stripe gateway mode from env"`
- `test "stripe mode uses llm.stripe.com base URL"`
- `test "stripe mode maps model via StripeModelMapper"`
- `test "stripe mode sends Authorization Bearer with STRIPE_GATEWAY_KEY"`
- `test "stripe mode sends X-Stripe-Customer-ID header"`
- `test "stripe mode raises ArgumentError when stripe_customer_id is nil"`
- `test "stripe mode posts to /chat/completions (no /v1 prefix)"`
- `test "litellm mode posts to /v1/chat/completions"`
- `test "litellm mode does not send Authorization header"`
- `test "handles 402 payment required in stripe mode"`
- `test "existing litellm tests still pass"` (verify no regressions)

### 2.2 GREEN: Modify `app/services/llm_client.rb`
- Add constructor params: `gateway_mode` (Symbol, from env), `stripe_customer_id` (String, optional — this is the Stripe `cus_xxx` ID, not the FK)
- `gateway_mode` defaults from `ENV["LLM_GATEWAY_MODE"]` → `:litellm` or `:stripe_gateway`
- **Validate**: raise `ArgumentError` if stripe mode and `stripe_customer_id` is nil
- In stripe mode: base_url = `https://llm.stripe.com`, model mapped via `StripeModelMapper` at construction time
- **`make_request`** changes:
  - LiteLLM: `POST /v1/chat/completions`, `Content-Type` only
  - Stripe: `POST /chat/completions`, add `Authorization: Bearer <STRIPE_GATEWAY_KEY>` + `X-Stripe-Customer-ID` headers
- Add 402 handling in `parse_response` for payment issues
- `chat()` public API signature unchanged — mode is set at construction time

---

## Phase 3: Thread Customer ID Through Call Chain — RED then GREEN

### 3.1 RED: Tests in `test/services/agent_navigator_test.rb`
- `test "passes stripe_customer_id to LLMClient when provided"`
- `test "does not pass stripe_customer_id when nil"`

### 3.2 GREEN: `app/services/agent_navigator.rb`
- Add `stripe_customer_id` param to constructor (this is the Stripe `cus_xxx` string), pass through to `LLMClient.new`

### 3.3 RED: Tests in `test/jobs/agent_queue_processor_job_test.rb`
- `test "fails task when stripe_billing enabled and agent has no billing customer"`
- `test "passes stripe_id to AgentNavigator when agent has active billing customer"`
- `test "stamps stripe_customer_id on task run at creation"`
- `test "runs normally when stripe_billing flag is disabled"`
- `test "skips LLMPricing.calculate_cost when stripe gateway active"`
- `test "still records token counts when stripe gateway active"`

### 3.4 GREEN: `app/jobs/agent_queue_processor_job.rb`
- In `run_task`: resolve billing customer from `task_run.ai_agent.billing_customer`
- **Stamp the run**: set `task_run.stripe_customer_id` = agent's `stripe_customer_id` at run start (immutable from this point)
- **Hard gate**: if `stripe_billing` feature flag enabled on tenant AND agent has no active `billing_customer`, fail the task with clear error message pointing to billing setup
- Pass `billing_customer.stripe_id` (the `cus_xxx` string) to `AgentNavigator.new`
- Skip `LLMPricing.calculate_cost` when Stripe gateway is active (Stripe handles billing)
- Still record `input_tokens`/`output_tokens`/`total_tokens` locally for dashboards

### 3.5 RED: Tests in `test/services/automation_executor_test.rb`
- `test "fails run when stripe_billing enabled and agent has no billing customer"`
- `test "runs normally when stripe_billing flag disabled"`

### 3.6 GREEN: `app/services/automation_executor.rb`
- In `execute_agent_rule`: after resolving `ai_agent`, check `ai_agent.billing_customer&.active?`
- If `stripe_billing` enabled and agent lacks active billing customer → `@run.mark_failed!` with billing error

### 3.7 RED: Tests in `test/controllers/ai_agents_controller_test.rb`
- `test "create redirects to billing when stripe_billing enabled and billing not set up"`
- `test "create stores return_to in session before redirect"`
- `test "create works normally when stripe_billing disabled"`
- `test "create works normally when billing is set up"`
- `test "create assigns current user's stripe customer to new agent"`
- `test "execute_create_ai_agent returns action error when billing not set up"`
- `test "execute_task redirects when billing not set up"`

### 3.8 GREEN: `app/controllers/ai_agents_controller.rb`
- In `create` and `execute_create_ai_agent` (line 250 and 281): check billing before creating agent
- If `stripe_billing` flag enabled on tenant AND `current_user.requires_stripe_billing?(current_tenant)`:
  - HTML: store current path in `session[:billing_return_to]`, redirect to `/billing` with flash message "Set up billing to create AI agents"
  - Markdown API: return action error with billing message
- **On successful creation**: set `agent.stripe_customer_id = current_user.stripe_customer.id` (new agent inherits creator's billing customer)
- In `new` (line 241): show billing prompt in the view if billing is not set up
- In `execute_task`: also check billing before running (defense in depth — user could have billing revoked after creating agent)

---

## Phase 4: Stripe Customer & Subscription Management — RED then GREEN

### 4.1 RED: `test/services/stripe_service_test.rb`
- `test "find_or_create_customer creates StripeCustomer record and Stripe customer"` (stub `Stripe::Customer.create`)
- `test "find_or_create_customer returns existing record if present"` (no Stripe API call)
- `test "find_or_create_customer is safe under concurrent calls"` (second call returns existing, no duplicate)
- `test "create_checkout_session creates session with pricing plan"` (stub `Stripe::Checkout::Session.create`, verify `checkout_items` format)
- `test "create_checkout_session includes checkout_session_id template in success_url"`
- `test "create_portal_session creates billing portal session"` (stub `Stripe::BillingPortal::Session.create`)
- `test "handle_webhook checkout.session.completed activates billing"`
- `test "handle_webhook customer.subscription.updated deactivates on cancel"`
- `test "handle_webhook customer.subscription.deleted deactivates billing"`
- `test "handle_webhook invoice.payment_failed logs warning"`
- `test "handle_webhook ignores unknown event types"`

### 4.2 GREEN: `app/services/stripe_service.rb`
- `find_or_create_customer(billable)` — returns existing `StripeCustomer` if present (via `billable.stripe_customer`); otherwise creates Stripe Customer via API, creates `StripeCustomer` record with `stripe_id`, returns it. Uses DB unique index on `[billable_type, billable_id]` as concurrency guard.
- `create_checkout_session(stripe_customer:, success_url:, cancel_url:)` — creates Checkout Session using **Stripe Pricing Plans API**:
  - Uses `checkout_items` (not `line_items`) with `type: "pricing_plan_subscription_item"`
  - References single `STRIPE_PRICING_PLAN_ID` (a `bpp_...` ID that bundles base fee + metered usage)
  - Requires preview API version header: `Stripe-Version: 2025-09-30.preview;checkout_product_catalog_preview=v1`
  - Format:
    ```ruby
    Stripe::Checkout::Session.create({
      customer: stripe_customer.stripe_id,
      checkout_items: [{
        type: "pricing_plan_subscription_item",
        pricing_plan_subscription_item: {
          pricing_plan: ENV.fetch("STRIPE_PRICING_PLAN_ID"),
        },
      }],
      success_url: success_url,
      cancel_url: cancel_url,
    }, {
      stripe_version: "2025-09-30.preview;checkout_product_catalog_preview=v1",
    })
    ```
  - The `success_url` includes `?checkout_session_id={CHECKOUT_SESSION_ID}` (Stripe template variable) so billing can be confirmed synchronously on return. Returns redirect URL.
  - **Note**: `mode: "subscription"` is omitted — Stripe infers it from the pricing plan type.
- `create_portal_session(stripe_customer:, return_url:)` — creates Billing Portal session for managing payment
- `handle_webhook_event(event)` — dispatches to handlers, looks up `StripeCustomer` by `stripe_id`:
  - `checkout.session.completed` → set `stripe_subscription_id`, `active = true`
  - `customer.subscription.updated` → update active status based on subscription state
  - `customer.subscription.deleted` → set `active = false`
  - `invoice.payment_failed` → log warning (Stripe retries; subscription.updated handles status)

### 4.3 RED: `test/controllers/stripe_webhooks_controller_test.rb`
- `test "receive with valid signature processes event"` (stub `Stripe::Webhook.construct_event`)
- `test "receive with invalid signature returns 400"`
- `test "receive with missing signature returns 400"`
- `test "receive delegates to StripeService.handle_webhook_event"`

### 4.4 GREEN: Webhook controller
- **`app/controllers/stripe_webhooks_controller.rb`** — inherits `ActionController::Base`, skips CSRF
- Verifies Stripe signature via `Stripe::Webhook.construct_event`, delegates to `StripeService.handle_webhook_event`

### 4.5 Routes
- **`config/routes.rb`** — add `post "stripe/webhooks" => "stripe_webhooks#receive"`

---

## Phase 5: Billing UI — RED then GREEN

### 5.1 RED: `test/controllers/billing_controller_test.rb`
- `test "show displays billing status when authenticated"`
- `test "show redirects unauthenticated user to login"`
- `test "show activates billing when checkout_session_id present"` (stub `Stripe::Checkout::Session.retrieve`)
- `test "show redirects to return_to after activating billing"`
- `test "show validates return_to is a relative path"` (rejects `https://evil.com`)
- `test "show does not activate billing for mismatched customer"`
- `test "setup creates customer and redirects to Stripe Checkout"` (stub Stripe)
- `test "setup passes return_to from session into success_url"`
- `test "portal redirects to Stripe Billing Portal"` (stub Stripe)

### 5.2 GREEN: Billing controller
- **`app/controllers/billing_controller.rb`**
- `show` — billing status page (active/inactive, list of user's agents). **Handles checkout return**: if `params[:checkout_session_id]` present and billing not yet active, verify the session synchronously via `Stripe::Checkout::Session.retrieve` and activate billing immediately (don't wait for webhook). If `params[:return_to]` present and billing is now active, redirect there — but **only if `return_to` is a relative path** (starts with `/`, no protocol/host — prevents open redirect).
- `setup` — calls `StripeService.find_or_create_customer(current_user)`, then redirects to Stripe Checkout. `success_url` includes `checkout_session_id={CHECKOUT_SESSION_ID}` and `return_to` from `session.delete(:billing_return_to)`. `cancel_url` returns to `/billing`.
- `portal` — redirects to Stripe Billing Portal for payment management

### 5.3 Routes
- `get "billing" => "billing#show"`
- `post "billing/setup" => "billing#setup"`
- `get "billing/portal" => "billing#portal"`

### 5.4 Views
- **`app/views/billing/show.html.erb`** — billing status, agent list, setup/manage buttons
- **`app/views/billing/show.md.erb`** — markdown version for agent dual-interface pattern

### 5.5 Billing gates on agent pages
- **`app/views/ai_agents/new.html.erb`** — if billing not set up, replace the creation form with a billing setup prompt + link to `/billing`
- **`app/views/ai_agents/run_task.html.erb`** — warning banner + disabled submit when billing not active (defense in depth for revoked billing)
- **`app/views/ai_agents/index.html.erb`** — billing status banner at top

### 5.6 Settings link
- **`app/views/users/settings.html.erb`** — add "Billing" link (visible when feature flag enabled)

---

## Edge Cases

| Scenario | Handling |
|----------|----------|
| User tries to create agent without billing | Controller blocks creation, redirects to `/billing`. Agent is never created. |
| Subscription lapses after agents already exist | Task run gate in `AgentQueueProcessorJob` checks `agent.billing_customer.active?` — fails task with billing error. Existing agents remain but can't run. |
| Subscription lapses mid-task-run | Task completes — billing checked at start only. If Stripe returns 402 during run, LLMClient returns error and task fails naturally. |
| Automation triggers agent without billing | `AutomationExecutor` checks `ai_agent.billing_customer&.active?` before creating task run, marks run as failed with billing error. |
| Agent configured with Ollama model + Stripe mode | `StripeModelMapper` raises `UnsupportedModelError` at LLMClient construction — task fails with clear message. |
| Same user owns agents across multiple tenants | Single `StripeCustomer` record for the user (polymorphic `billable`). All their agents point to it — one bill. |
| Agent billing customer transferred | Only future task runs get the new `stripe_customer_id`. Past runs retain original payer — immutable attribution. |
| Checkout completes but webhook hasn't arrived | `BillingController#show` verifies checkout session synchronously via Stripe API on return. Webhook arrives later and is idempotent. |
| LLMClient in stripe mode without customer ID | Raises `ArgumentError` at construction — caught early before any API call. |
| Concurrent billing setup requests | `find_or_create_customer` returns existing record if present; unique index on `[billable_type, billable_id]` prevents duplicates at DB level. |
| Open redirect via return_to param | `BillingController#show` validates `return_to` is a relative path (starts with `/`, no protocol). Rejects external URLs. |
| Dev environment without Stripe keys | `LLM_GATEWAY_MODE=litellm` (default) — everything works as before. Feature flag off = no billing checks. |

---

## Files Summary

**New files** (16):
- `db/migrate/..._create_stripe_customers.rb`
- `app/models/stripe_customer.rb`
- `config/initializers/stripe.rb`
- `app/services/stripe_model_mapper.rb`
- `app/services/stripe_service.rb`
- `app/controllers/stripe_webhooks_controller.rb`
- `app/controllers/billing_controller.rb`
- `app/views/billing/show.html.erb`
- `app/views/billing/show.md.erb`
- `test/models/stripe_customer_test.rb`
- `test/services/stripe_model_mapper_test.rb`
- `test/services/stripe_service_test.rb`
- `test/controllers/stripe_webhooks_controller_test.rb`
- `test/controllers/billing_controller_test.rb`

**Modified files** (12 code + 4 test):
- `Gemfile` — add stripe gem
- `.env.example` — add Stripe env vars (STRIPE_API_KEY, STRIPE_GATEWAY_KEY, STRIPE_WEBHOOK_SECRET, STRIPE_PRICING_PLAN_ID, LLM_GATEWAY_MODE)
- `config/feature_flags.yml` — add stripe_billing flag
- `config/routes.rb` — add webhook + billing routes
- `app/models/user.rb` — add `has_one :stripe_customer, as: :billable` + `belongs_to :billing_customer` + billing helpers
- `app/models/ai_agent_task_run.rb` — add `belongs_to :billing_customer` FK
- `app/services/llm_client.rb` — dual mode (gateway_mode, headers, endpoint)
- `app/services/agent_navigator.rb` — pass stripe_customer_id to LLMClient
- `app/jobs/agent_queue_processor_job.rb` — billing gate + customer ID threading + stamp run
- `app/services/automation_executor.rb` — billing gate for automation-triggered runs
- `app/views/ai_agents/new.html.erb` — billing gate on creation form
- `app/views/ai_agents/run_task.html.erb` — billing warning banner
- `test/models/user_test.rb` — stripe billing helper tests
- `test/services/llm_client_test.rb` — dual mode tests
- `test/services/agent_navigator_test.rb` — customer ID passthrough tests
- `test/controllers/ai_agents_controller_test.rb` — billing gate + agent customer assignment tests

---

## Setup Notes (from dev environment configuration, 2026-03-11)

### Stripe Account & Keys

- Stripe test account is set up under account ID `51SoyCf...` (visible in key prefixes)
- **`STRIPE_API_KEY`**: Created as a restricted key (`rk_test_...`) with permissions:
  - Write: Customers, Checkout Sessions, Customer portal
  - Read: Subscriptions, Invoices, Prices, Billing meters (for future usage display features)
- **`STRIPE_GATEWAY_KEY`**: Left blank. The AI Gateway (`llm.stripe.com`) appears to still be in preview/beta — there is no "AI Gateway" permission in Stripe's restricted key UI as of March 2026. The endpoint itself (`llm.stripe.com`) is not publicly documented. This key is only needed when `LLM_GATEWAY_MODE=stripe_gateway`, which is production-only.
- **`STRIPE_WEBHOOK_SECRET`**: Set from a previous Stripe setup (`whsec_...`)
- **`STRIPE_PRICING_PLAN_ID`**: Uses `bpp_test_...` prefix — this is a Stripe Pricing Plan that bundles the monthly base fee (license component) + metered token usage (rate card component) into a single plan. Replaces the previous separate `STRIPE_BASE_PRICE_ID` + `STRIPE_METERED_PRICE_ID` env vars. The old `price_` based IDs from the legacy pricing system are no longer needed.

### Stripe Pricing Plans (important API change)

Stripe's newer billing system uses **Pricing Plans** (`bpp_` prefix) instead of individual Price objects (`price_` prefix). This was discovered during dev setup — the plan originally assumed the legacy `price_` based line items approach, but the Stripe dashboard now creates Pricing Plans by default.

**Key differences from the original plan**:
- Checkout Sessions use `checkout_items` array (not `line_items`)
- Each item has `type: "pricing_plan_subscription_item"` with a nested `pricing_plan` ID
- Requires a **preview API version header**: `Stripe-Version: 2025-09-30.preview;checkout_product_catalog_preview=v1`
- A single Pricing Plan ID replaces the two separate price IDs (`STRIPE_BASE_PRICE_ID` + `STRIPE_METERED_PRICE_ID`)
- `mode: "subscription"` is inferred from the plan type and should be omitted
- Rate card components (usage-based metering) are included automatically — no special config needed at checkout
- License fee components may require `component_configurations` with quantities if the plan includes them

**Reference**: [Pricing Plans docs](https://docs.stripe.com/billing/subscriptions/usage-based/pricing-plans)

### Prior Stripe Work

An unmerged `feature/saas-mode` branch exists with a completely different, larger billing implementation (SubscriptionPlan, Subscription, BillingEvent models, billing services under `app/services/billing/`, etc.). That branch used different env var names (`STRIPE_SECRET_KEY`, `STRIPE_PRO_MONTHLY_PRICE_ID`). **We are ignoring that branch entirely** — this plan is a fresh implementation. The `.env` still contains some vars from that era (`STRIPE_SECRET_KEY`, `STRIPE_PUBLISHABLE_KEY`) which are unused by this implementation.

### Relevant Stripe Documentation

- [Billing for LLM tokens](https://docs.stripe.com/billing/token-billing) — AI Gateway concept, metering, but no endpoint/auth details
- [Add Stripe to agentic workflows](https://docs.stripe.com/agents) — Agent toolkit, MCP server
- [Stripe AI GitHub](https://github.com/stripe/ai) — SDK source, agent toolkit (no `llm.stripe.com` docs found here either)
- [Restricted API keys](https://docs.stripe.com/keys) — Key management and permissions
- [Pricing Plans](https://docs.stripe.com/billing/subscriptions/usage-based/pricing-plans) — New billing model using `bpp_` IDs, `checkout_items` API, combines rate cards + license fees

### Dev Environment Defaults

- `LLM_GATEWAY_MODE=litellm` — all LLM calls go through local LiteLLM, no Stripe gateway involvement
- `stripe_billing` feature flag defaults to off — no billing gates enforced unless explicitly enabled per tenant

---

## Verification

1. **Unit tests**: Run `./scripts/run-tests.sh` — all new and existing tests pass
2. **Type check**: `docker compose exec web bundle exec srb tc` — no new errors
3. **Lint**: `docker compose exec web bundle exec rubocop` — no violations
4. **Dev mode smoke test**: With `LLM_GATEWAY_MODE=litellm`, agents run as before (no Stripe required)
5. **Stripe mode smoke test**: With `LLM_GATEWAY_MODE=stripe_gateway` + valid Stripe keys + `stripe_billing` flag enabled:
   - User without billing → cannot create agent, redirected to `/billing`
   - User sets up billing via `/billing/setup` → redirected to Stripe Checkout (base fee + metered)
   - After checkout → redirected back to `/billing?checkout_session_id=...&return_to=...`
   - Billing controller verifies session synchronously → `StripeCustomer.active` set to true immediately
   - User is redirected back to agent creation form (return journey preserved)
   - User can now create agent (agent gets `stripe_customer_id` = user's StripeCustomer)
   - Agent run succeeds → task run stamped with `stripe_customer_id` → request goes to `llm.stripe.com` with correct `X-Stripe-Customer-ID` header
   - Verify in Stripe dashboard: meter events show up attributed to customer
6. **Webhook test**: Use Stripe CLI (`stripe listen --forward-to`) to verify webhook handling
7. **Ownership transfer test**: Change agent's `stripe_customer_id` → verify old runs retain original customer, new runs use new customer
