# Stripe Billing Integration

## Context

Harmonic is open source and free to self-host, but accounts on `harmonic.social` require paid billing. The billing system has two layers:

1. **Account subscription ($3/month)** — Every user on `harmonic.social` pays a flat monthly fee. This ensures identity verification (valid payment method), spam resistance (non-zero cost), and aligned incentives (no ads, no monetizing user data).

2. **AI Agent usage (prepaid balance)** — Completely separate from the account subscription. Users who create AI Agents must fund a prepaid credit balance before usage can occur. There is no after-the-fact billing for token usage — users pay upfront and costs are drawn down as agents run. Implemented using [Stripe Billing Credits](https://docs.stripe.com/billing/subscriptions/usage-based/billing-credits) (Credit Grants). Balance management is handled entirely by Stripe.

**LLM routing**: Stripe's AI Gateway (`llm.stripe.com`) serves as both the LLM routing layer and the metering layer. It accepts OpenAI-compatible HTTP requests, routes to providers (Anthropic, OpenAI, Gemini), and automatically meters token usage per customer. Stripe can reject requests when a customer has no credit remaining.

**Key finding from SDK source**: The gateway is `POST https://llm.stripe.com/chat/completions` with `Authorization: Bearer <stripe_key>` and `X-Stripe-Customer-ID: cus_xxx` headers. Standard OpenAI request/response format. Model names use `provider/model` format (e.g., `anthropic/claude-sonnet-4`).

**Feature flags**: `stripe_billing` controls all Stripe billing (both layers). When disabled, the app runs without billing — suitable for self-hosted instances. The `ai_agents` flag separately controls the internal task runner; the `api` flag controls external API access. These are independent of `stripe_billing`.

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
  - `STRIPE_API_KEY` — Stripe restricted key (permissions: Customers write, Checkout Sessions write, Customer portal write, Subscriptions read, Invoices read, Prices read, Billing meters read, Credit Grants write)
  - `STRIPE_GATEWAY_KEY` — Separate restricted key for AI Gateway requests only (used as Bearer token to `llm.stripe.com`). **Note**: AI Gateway permission not yet available in Stripe restricted key UI as of March 2026 — leave blank for dev.
  - `STRIPE_WEBHOOK_SECRET` — webhook signature verification
  - `STRIPE_PRICING_PLAN_ID` — Stripe Pricing Plan ID (`bpp_...` prefix) for the $3/month account subscription. Uses Stripe's newer Pricing Plans system.
  - `STRIPE_CREDIT_PRODUCT_ID` — Stripe Product ID (`prod_...` prefix) representing "AI Agent Credits." Used as the product for dynamically-priced one-time Checkout sessions when users top up credits. Create this product once in the Stripe dashboard.
  - `STRIPE_MAX_TOPUP_CENTS=50000` — Maximum credit top-up amount per transaction in cents (default: $500)
  - `LLM_GATEWAY_MODE=litellm` — `litellm` (default) or `stripe_gateway`
- **Key separation rationale**: The gateway key is sent on every LLM request to an external service. Using a separate restricted key limits blast radius if it leaks — it can only access the AI Gateway, not manage customers or subscriptions.
- **Pricing Plans vs legacy Prices**: Stripe's newer billing system uses Pricing Plans (`bpp_` prefix) instead of individual Price objects (`price_` prefix). Pricing Plans group multiple pricing components (rate cards for usage, license fees for fixed recurring charges) into a single entity. Checkout Sessions use `checkout_items` with `type: "pricing_plan_subscription_item"` instead of `line_items` with `price:`. This requires the preview API version header `Stripe-Version: 2025-09-30.preview;checkout_product_catalog_preview=v1`.

### 1.4 Stripe initializer
- **New file**: `config/initializers/stripe.rb` — set `Stripe.api_key` from `STRIPE_API_KEY` env (backend operations only; gateway key is read separately in `LLMClient`)

### 1.5 Feature flag
- **`config/feature_flags.yml`** — add `stripe_billing` (app_enabled: true, default_tenant: false). Controls all Stripe billing (both account subscription and AI Agent usage). Independent of `ai_agents` and `api` flags.

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
  - `stripe_billing_setup?` — checks `stripe_customer&.active?`. This means "has an active account subscription" (Layer 1). It does NOT check credit balance (Layer 2). Credit balance is enforced at task execution time by: (a) an app-level balance check in `AgentQueueProcessorJob` (best-effort, fails fast with clear error), and (b) the Stripe AI Gateway (authoritative 402 rejection).
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
- `test "fails task when stripe_billing enabled and credit balance is zero"`
- `test "passes stripe_id to AgentNavigator when agent has active billing customer and positive balance"`
- `test "stamps stripe_customer_id on task run at creation"`
- `test "runs normally when stripe_billing flag is disabled"`
- `test "skips LLMPricing.calculate_cost when stripe gateway active"`
- `test "still records token counts when stripe gateway active"`

### 3.4 GREEN: `app/jobs/agent_queue_processor_job.rb`
- In `run_task`: resolve billing customer from `task_run.ai_agent.billing_customer`
- **Stamp the run**: set `task_run.stripe_customer_id` = agent's `stripe_customer_id` at run start (immutable from this point)
- **Subscription gate**: if `stripe_billing` feature flag enabled on tenant AND agent has no active `billing_customer`, fail the task with clear error message pointing to billing setup
- **Credit balance gate**: if `stripe_billing` enabled AND Stripe gateway mode active, call `StripeService.get_credit_balance(billing_customer)` before starting the task. If balance is zero (or below a configurable minimum threshold), fail the task with error: "Insufficient credit balance. Add funds at /billing before running agents." This prevents wasting a task run attempt only to get a 402 on the first LLM call.
- Pass `billing_customer.stripe_id` (the `cus_xxx` string) to `AgentNavigator.new`
- Skip `LLMPricing.calculate_cost` when Stripe gateway is active (Stripe handles billing)
- Still record `input_tokens`/`output_tokens`/`total_tokens` locally for dashboards
- **Note**: The credit balance check is best-effort (balance could change between check and LLM call). The gateway 402 is the authoritative enforcement. The app-level check provides a better error message and avoids unnecessary task setup.

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

**Note**: These checks are defense-in-depth. The application-level billing gate (Phase 5) is the primary enforcement for human users — it prevents reaching agent pages without an active subscription. These controller-level checks serve as:
- A safety net if the application gate is bypassed (e.g., code change removes it)
- Enforcement for the markdown API interface (same routes, different format)
- A place to check billing-specific conditions beyond subscription status (e.g., agent-specific billing customer assignment)

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
- `test "create_subscription_checkout creates session with pricing plan"` (stub `Stripe::Checkout::Session.create`, verify `checkout_items` format)
- `test "create_subscription_checkout includes checkout_session_id template in success_url"`
- `test "create_credit_topup_checkout creates session for one-time credit purchase"` (stub Stripe)
- `test "create_credit_grant creates credit grant for customer"` (stub `Stripe::Billing::CreditGrant.create`)
- `test "get_credit_balance returns available balance from Stripe"` (stub Credit Balance Summary API)
- `test "create_portal_session creates billing portal session"` (stub `Stripe::BillingPortal::Session.create`)
- `test "handle_webhook checkout.session.completed activates billing for subscription"`
- `test "handle_webhook checkout.session.completed creates credit grant for top-up"`
- `test "handle_webhook customer.subscription.updated deactivates on cancel"`
- `test "handle_webhook customer.subscription.deleted deactivates billing"`
- `test "handle_webhook invoice.payment_failed logs warning"`
- `test "handle_webhook ignores unknown event types"`

### 4.2 GREEN: `app/services/stripe_service.rb`
- `find_or_create_customer(billable)` — returns existing `StripeCustomer` if present (via `billable.stripe_customer`); otherwise creates Stripe Customer via API, creates `StripeCustomer` record with `stripe_id`, returns it. Uses DB unique index on `[billable_type, billable_id]` as concurrency guard.
- `create_subscription_checkout(stripe_customer:, success_url:, cancel_url:)` — creates Checkout Session for the **$3/month account subscription** using Stripe Pricing Plans API:
  - Uses `checkout_items` (not `line_items`) with `type: "pricing_plan_subscription_item"`
  - References `STRIPE_PRICING_PLAN_ID` (a `bpp_...` ID for the account subscription)
  - Requires preview API version header: `Stripe-Version: 2025-09-30.preview;checkout_product_catalog_preview=v1`
  - The `success_url` includes `?checkout_session_id={CHECKOUT_SESSION_ID}` so billing can be confirmed synchronously on return.
  - **Note**: `mode: "subscription"` is omitted — Stripe infers it from the pricing plan type.
- `create_credit_topup_checkout(stripe_customer:, amount_cents:, success_url:, cancel_url:)` — creates Checkout Session for a **one-time payment** to add AI Agent usage credits. Uses `mode: "payment"` with a dynamically created `Stripe::Price` (`unit_amount: amount_cents, currency: "usd", product: ENV["STRIPE_CREDIT_PRODUCT_ID"]`) and `quantity: 1`. The product is a pre-configured Stripe Product representing "AI Agent Credits." Metadata `{ type: "credit_topup" }` is set for webhook disambiguation (but NOT the amount — amount is derived from the actual payment).
- `create_credit_grant(stripe_customer:, amount_cents:)` — creates a Stripe Billing Credit Grant on the customer. **Security: `amount_cents` must always be derived from `session.amount_total` (the actual payment amount), never from user-provided metadata.** Credits are automatically drawn down when metered AI Gateway usage generates invoices.
- `get_credit_balance(stripe_customer:)` — fetches the customer's current available credit balance from Stripe's Credit Balance Summary API. Used to display balance on the billing page.
- `create_portal_session(stripe_customer:, return_url:)` — creates Billing Portal session for managing subscription payment
- `handle_webhook_event(event)` — dispatches to handlers, looks up `StripeCustomer` by `stripe_id`:
  - `checkout.session.completed` → disambiguate by `session.mode`:
    - `mode == "subscription"`: set `stripe_subscription_id`, `active = true`
    - `mode == "payment"` + metadata `type: "credit_topup"`: create Credit Grant using `session.amount_total` as the grant amount (idempotent — skip if grant with matching `checkout_session_id` metadata already exists). **Never use metadata for the amount.**
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
- **Security note**: The endpoint is unauthenticated by design (Stripe sends the requests). Signature verification is the primary defense. Rate limiting is handled at the infrastructure level (e.g., Rack::Attack or reverse proxy) rather than in the controller — an attacker spamming invalid payloads would fail signature verification cheaply (HMAC comparison) before any DB work occurs.

### 4.5 Routes
- **`config/routes.rb`** — add `post "stripe/webhooks" => "stripe_webhooks#receive"`

---

## Phase 5: Account Signup Billing Gate

Layer 1 requires every account on `harmonic.social` to have an active $3/month subscription. This must be enforced at account creation time, not just at agent creation.

### Signup Flow (when `stripe_billing` enabled)

1. User completes identity provider authentication (OAuth / email+password)
2. User record is created with `stripe_billing_setup? == false`
3. On first authenticated request, middleware checks `stripe_billing` flag + `stripe_billing_setup?`
4. If billing not set up → redirect to `/billing` (not the agent creation page — the account-level billing page)
5. User sees the $3/month explanation and clicks "Set Up Billing"
6. Redirected to Stripe Checkout → completes payment → returned to `/billing`
7. Account is now active — user can use the app normally

**Key design decision**: The billing gate is at the *application level*, not the *registration level*. The user account exists before payment — it just can't do anything until billing is active. This avoids the complexity of integrating Stripe into the OAuth callback flow and keeps account creation and billing as separate concerns.

**Implementation**: Add a `before_action` in `ApplicationController` (or a concern) that checks `stripe_billing` + `stripe_billing_setup?` and redirects to `/billing`.

**Exemptions** (the gate must NOT apply to):
- `BillingController` — the user needs to reach this to set up billing
- Login/logout/authentication routes — user must be able to authenticate and sign out
- `StripeWebhooksController` — Stripe sends these, no user session involved
- API controllers (`Api::V1::BaseController` and subclasses) — AI agents and external integrations authenticate via API tokens, not browser sessions. Billing for API usage is enforced at the task execution layer, not the request layer.
- Non-human users (`current_user&.user_type != "human"`) — AI agents and collective identities don't have their own subscriptions. Their billing is handled through the `billing_customer` FK at task execution time.
- User settings/profile page — so users can view their account info and log out without being trapped

**Guard clause**: `return unless current_user&.human? && current_tenant&.feature_enabled?("stripe_billing") && !current_user.stripe_billing_setup?`

### 5.0 Tests for signup billing gate
- `test "authenticated human user without billing is redirected to /billing"`
- `test "authenticated human user with active billing can access app normally"`
- `test "billing controller is exempt from billing gate redirect"`
- `test "login/logout routes are exempt from billing gate"`
- `test "webhook endpoint is exempt from billing gate"`
- `test "API controllers are exempt from billing gate"`
- `test "AI agent users are exempt from billing gate"`
- `test "billing gate is not enforced when stripe_billing flag is off"`
- `test "user settings page is exempt from billing gate"`

---

## Phase 6: Billing UI — RED then GREEN

### 6.1 RED: `test/controllers/billing_controller_test.rb`
- `test "show displays billing status when authenticated"`
- `test "show redirects unauthenticated user to login"`
- `test "show activates billing when checkout_session_id present"` (stub `Stripe::Checkout::Session.retrieve`)
- `test "show creates credit grant when credit topup checkout_session_id present"`
- `test "show does not create duplicate credit grant for same checkout session"` (idempotency)
- `test "show redirects to return_to after activating billing"`
- `test "show validates return_to is a relative path"` (rejects `https://evil.com`)
- `test "show does not activate billing for mismatched customer"`
- `test "show displays credit balance and handles Stripe API failure gracefully"`
- `test "setup creates customer and redirects to Stripe Checkout"` (stub Stripe)
- `test "setup passes return_to from session into success_url"`
- `test "topup creates checkout session for credit purchase"` (stub Stripe)
- `test "topup rejects amounts below minimum"` (e.g., < $1)
- `test "topup rejects amounts above maximum"` (e.g., > $500)
- `test "topup rejects non-numeric or negative amounts"`
- `test "topup requires active subscription first"`
- `test "portal redirects to Stripe Billing Portal"` (stub Stripe)

### 6.2 GREEN: Billing controller
- **`app/controllers/billing_controller.rb`**
- `show` — billing status page showing two sections:
  - **Account subscription** — active/inactive status, manage link
  - **AI Agent credits** — current credit balance (fetched from Stripe Credit Balance Summary API), top-up button, list of user's agents
  - **Handles checkout return**: if `params[:checkout_session_id]` present, verify the session synchronously via `Stripe::Checkout::Session.retrieve`. For subscription checkout: activate billing immediately. For credit top-up: create Credit Grant. If `params[:return_to]` present and billing is now active, redirect there — but **only if `return_to` is a relative path** (starts with `/`, no protocol/host — prevents open redirect).
- `setup` — calls `StripeService.find_or_create_customer(current_user)`, then redirects to Stripe Checkout for the $3/month subscription. `success_url` includes `checkout_session_id={CHECKOUT_SESSION_ID}` and `return_to` from `session.delete(:billing_return_to)`. `cancel_url` returns to `/billing`.
- `topup` — creates a Stripe Checkout session for a one-time credit purchase. **Server-side validation**: amount must be a positive integer in cents, minimum $1 (100 cents), maximum $500 (50000 cents) — configurable via `STRIPE_MAX_TOPUP_CENTS` env var. Requires active subscription first (can't top up credits without an account). Checkout session metadata includes `{ type: "credit_topup" }` for webhook disambiguation. **Security: the amount is NOT stored in metadata** — when creating the Credit Grant, the amount is always derived from `session.amount_total` (the verified payment amount from Stripe), never from user-controlled data.
- `portal` — redirects to Stripe Billing Portal for managing subscription payment

**Webhook disambiguation** (issue: how does `checkout.session.completed` know if it's a subscription or credit top-up?):
- Subscription checkouts have `session.subscription` set (non-nil) and `session.mode == "subscription"`
- Credit top-up checkouts have `session.mode == "payment"` and metadata `type: "credit_topup"`
- The handler checks `session.mode` first, then metadata as confirmation

**Credit Grant idempotency**: Before creating a Credit Grant from a checkout return or webhook, check if a grant already exists with metadata `{ checkout_session_id: session.id }`. If so, skip creation. This prevents duplicate grants when both the synchronous return and the webhook fire for the same checkout.

**Credit balance display fallback**: If the Stripe Credit Balance Summary API call fails (network error, rate limit), the billing page shows "Balance unavailable — try refreshing" instead of erroring out. No caching of balance — it's always fetched live to avoid stale data.

### 6.3 Routes
- `get "billing" => "billing#show"`
- `post "billing/setup" => "billing#setup"`
- `post "billing/topup" => "billing#topup"`
- `get "billing/portal" => "billing#portal"`

### 6.4 Views
- **`app/views/billing/show.html.erb`** — Three states:
  - **Not set up**: Explanation of $3/month subscription, "Set Up Billing" CTA
  - **Active, no credits**: Subscription status (active, manage link). Credit balance section showing $0.00 with prominent "Add Funds" button and amount selector. Clear messaging: "Add funds to run AI agents."
  - **Active, with credits**: Subscription status. Credit balance display. "Add Funds" button (less prominent). List of user's AI agents with links.
- **`app/views/billing/show.md.erb`** — markdown version for agent dual-interface pattern (same three states)

### 6.5 Billing gates on agent pages

Three distinct states for agent pages when `stripe_billing` is enabled:

1. **No subscription** (`!stripe_billing_setup?`) — blocked by the application-level billing gate (Phase 5), so this state shouldn't normally be reachable on agent pages. If somehow reached, redirect to `/billing`.

2. **Subscription active, zero credits** — User can create agents (form is available), but a warning banner shows: "Your credit balance is $0.00. Add funds before running agents." with a link to `/billing`. The `run_task` form is disabled with a message pointing to the billing page to top up.

3. **Subscription active, positive credits** — Full access. No warnings.

- **`app/views/ai_agents/new.html.erb`** — if subscription not active, redirect to `/billing`. If subscription active but zero credits, show creation form with a warning banner about needing credits to run agents.
- **`app/views/ai_agents/run_task.html.erb`** — if zero credits, disable submit with message "Add funds to your credit balance before running tasks" + link to `/billing`. Defense in depth for both revoked billing and depleted credits.
- **`app/views/ai_agents/index.html.erb`** — billing/credit status banner at top when credits are zero

**UX rationale**: Users can create agents without credits (agent creation is free — it's just a record). But running agents requires credits. This avoids blocking the creation flow while making the funding requirement clear. The billing page after subscription setup shows the credit balance at $0.00 with a prominent "Add Funds" button, so users naturally encounter the top-up flow before trying to run anything.

### 6.6 Settings link
- **`app/views/users/settings.html.erb`** — add "Billing" link (visible when feature flag enabled)

### 6.7 Usage visibility
- Task run records continue to store `total_tokens`, `input_tokens`, `output_tokens` locally for display in the app (agent task history). In Stripe Gateway mode, `estimated_cost_usd` is nil — the app does not attempt to replicate Stripe's cost calculations.
- For detailed cost breakdowns and invoice history, users are directed to the Stripe billing portal via `/billing/portal`.
- **Future consideration**: Stripe's Usage Records API could be used to pull per-customer usage summaries for an in-app usage dashboard. Not in scope for this plan.

---

## Edge Cases

| Scenario | Handling |
|----------|----------|
| New user authenticates but hasn't paid | Application-level billing gate redirects all requests to `/billing`. Account exists but is inert until subscription is active. |
| User completes subscription but has zero credits | Can browse app and create agents. Cannot run agents — task execution blocked by gateway 402 or app-level balance check. Billing page prominently shows "Add Funds" CTA. |
| User tries to create agent without subscription | Application-level billing gate redirects to `/billing` before they can reach agent pages. |
| Subscription lapses after agents already exist | Task run gate in `AgentQueueProcessorJob` checks `agent.billing_customer.active?` — fails task with billing error. Existing agents remain but can't run. Application-level gate also blocks app access. |
| Credit balance reaches zero mid-task-run | Stripe AI Gateway rejects the LLM request with 402. `LLMClient` handles 402 gracefully, task fails with "Payment required" error. |
| Credit balance reaches zero between tasks | App-level check and/or gateway-level rejection prevents execution. User sees balance on `/billing` and can top up. |
| Subscription lapses mid-task-run | Task completes — billing checked at start only. If Stripe returns 402 during run, LLMClient returns error and task fails naturally. |
| Automation triggers agent without billing | `AutomationExecutor` checks `ai_agent.billing_customer&.active?` before creating task run, marks run as failed with billing error. |
| Agent configured with Ollama model + Stripe mode | `StripeModelMapper` raises `UnsupportedModelError` at LLMClient construction — task fails with clear message. |
| Same user owns agents across multiple tenants | Single `StripeCustomer` record for the user (polymorphic `billable`). All their agents point to it — one credit balance. |
| Agent billing customer transferred | Only future task runs get the new `stripe_customer_id`. Past runs retain original payer — immutable attribution. |
| Checkout completes but webhook hasn't arrived | `BillingController#show` verifies checkout session synchronously via Stripe API on return. Webhook arrives later and is idempotent. |
| LLMClient in stripe mode without customer ID | Raises `ArgumentError` at construction — caught early before any API call. |
| Concurrent billing setup requests | `find_or_create_customer` returns existing record if present; unique index on `[billable_type, billable_id]` prevents duplicates at DB level. |
| Duplicate credit grant (checkout return + webhook race) | Credit Grant creation checks for existing grant with matching `checkout_session_id` in metadata. If found, skips creation. Both paths are idempotent. |
| Top-up with invalid amount | Server-side validation rejects amounts < $1 or > $500 (configurable). Non-numeric and negative values rejected before hitting Stripe API. |
| Top-up amount tampering | Credit Grant amount derived from `session.amount_total` (Stripe-verified payment), never from user-controlled metadata. Attacker cannot inflate grant amount. |
| Top-up without active subscription | `topup` action requires `stripe_billing_setup?`. Redirects to `/billing` with flash message if subscription not active. |
| AI agent makes API request | Application-level billing gate exempts non-human users. Agent billing is enforced at task execution time via `billing_customer` FK. |
| API request from external integration | API controllers exempt from billing gate. API authentication + billing checks at the action/job level provide enforcement. |
| Credit balance API failure on billing page | Page renders with "Balance unavailable — try refreshing" instead of erroring. No cached balance — always fetched live. |
| Open redirect via return_to param | `BillingController#show` validates `return_to` is a relative path (starts with `/`, no protocol). Rejects external URLs. |
| Dev environment without Stripe keys | `LLM_GATEWAY_MODE=litellm` (default) — everything works as before. Feature flag off = no billing checks. |

---

## Files Summary

**New files** (14):
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

**Modified files** (13 code + 5 test):
- `Gemfile` — add stripe gem
- `.env.example` — add Stripe env vars (STRIPE_API_KEY, STRIPE_GATEWAY_KEY, STRIPE_WEBHOOK_SECRET, STRIPE_PRICING_PLAN_ID, STRIPE_CREDIT_PRODUCT_ID, STRIPE_MAX_TOPUP_CENTS, LLM_GATEWAY_MODE)
- `config/feature_flags.yml` — add stripe_billing flag
- `config/routes.rb` — add webhook + billing + topup routes
- `app/controllers/application_controller.rb` — add billing gate `before_action` (Phase 5)
- `app/models/user.rb` — add `has_one :stripe_customer, as: :billable` + `belongs_to :billing_customer` + billing helpers
- `app/models/ai_agent_task_run.rb` — add `belongs_to :billing_customer` FK
- `app/services/llm_client.rb` — dual mode (gateway_mode, headers, endpoint)
- `app/services/agent_navigator.rb` — pass stripe_customer_id to LLMClient
- `app/jobs/agent_queue_processor_job.rb` — billing gate (subscription + credit balance) + customer ID threading + stamp run
- `app/services/automation_executor.rb` — billing gate for automation-triggered runs
- `app/views/ai_agents/new.html.erb` — billing gate on creation form
- `app/views/ai_agents/run_task.html.erb` — billing warning banner
- `test/models/user_test.rb` — stripe billing helper tests
- `test/services/llm_client_test.rb` — dual mode tests
- `test/services/agent_navigator_test.rb` — customer ID passthrough tests
- `test/controllers/ai_agents_controller_test.rb` — billing gate + agent customer assignment tests
- `test/integration/billing_gate_test.rb` — application-level billing gate tests (Phase 5)

---

## Setup Notes (from dev environment configuration, 2026-03-11)

### Stripe Account & Keys

- Stripe test account is set up under account ID `51SoyCf...` (visible in key prefixes)
- **`STRIPE_API_KEY`**: Created as a restricted key (`rk_test_...`) with permissions:
  - Write: Customers, Checkout Sessions, Customer portal
  - Read: Subscriptions, Invoices, Prices, Billing meters (for future usage display features)
- **`STRIPE_GATEWAY_KEY`**: Left blank. The AI Gateway (`llm.stripe.com`) appears to still be in preview/beta — there is no "AI Gateway" permission in Stripe's restricted key UI as of March 2026. The endpoint itself (`llm.stripe.com`) is not publicly documented. This key is only needed when `LLM_GATEWAY_MODE=stripe_gateway`, which is production-only.
- **`STRIPE_WEBHOOK_SECRET`**: Set from a previous Stripe setup (`whsec_...`)
- **`STRIPE_PRICING_PLAN_ID`**: Uses `bpp_test_...` prefix — this is a Stripe Pricing Plan for the $3/month account subscription. AI Agent usage is billed separately via prepaid Credit Grants drawn down by metered AI Gateway usage.
- **`STRIPE_CREDIT_PRODUCT_ID`**: Create a Product in the Stripe dashboard called "AI Agent Credits" (or similar). This product is used for dynamically-priced one-time Checkout sessions when users top up their credit balance. A new `Stripe::Price` is created per checkout with the user's chosen amount.

### Stripe Pricing Plans (important API change)

Stripe's newer billing system uses **Pricing Plans** (`bpp_` prefix) instead of individual Price objects (`price_` prefix). This was discovered during dev setup — the plan originally assumed the legacy `price_` based line items approach, but the Stripe dashboard now creates Pricing Plans by default.

**Key differences from the original plan**:
- Checkout Sessions use `checkout_items` array (not `line_items`)
- Each item has `type: "pricing_plan_subscription_item"` with a nested `pricing_plan` ID
- Requires a **preview API version header**: `Stripe-Version: 2025-09-30.preview;checkout_product_catalog_preview=v1`
- `mode: "subscription"` is inferred from the plan type and should be omitted
- The Pricing Plan covers only the $3/month account subscription — AI Agent usage is handled separately via Credit Grants + AI Gateway metering, not via rate card components in the subscription

**Reference**: [Pricing Plans docs](https://docs.stripe.com/billing/subscriptions/usage-based/pricing-plans)

### Prior Stripe Work

An unmerged `feature/saas-mode` branch exists with a completely different, larger billing implementation (SubscriptionPlan, Subscription, BillingEvent models, billing services under `app/services/billing/`, etc.). That branch used different env var names (`STRIPE_SECRET_KEY`, `STRIPE_PRO_MONTHLY_PRICE_ID`). **We are ignoring that branch entirely** — this plan is a fresh implementation. The `.env` still contains some vars from that era (`STRIPE_SECRET_KEY`, `STRIPE_PUBLISHABLE_KEY`) which are unused by this implementation.

### Relevant Stripe Documentation

- [Billing for LLM tokens](https://docs.stripe.com/billing/token-billing) — AI Gateway concept, metering, prepaid credit support
- [Billing Credits](https://docs.stripe.com/billing/subscriptions/usage-based/billing-credits) — Credit Grants, prepaid balance management, automatic drawdown
- [Set up billing credits](https://docs.stripe.com/billing/subscriptions/usage-based/billing-credits/implementation-guide) — Implementation guide for Credit Grants
- [Credit Grant API](https://docs.stripe.com/api/billing/credit-grant) — API reference for creating and managing credit grants
- [Add Stripe to agentic workflows](https://docs.stripe.com/agents) — Agent toolkit, MCP server
- [Stripe AI GitHub](https://github.com/stripe/ai) — SDK source, agent toolkit (no `llm.stripe.com` docs found here either)
- [Restricted API keys](https://docs.stripe.com/keys) — Key management and permissions
- [Pricing Plans](https://docs.stripe.com/billing/subscriptions/usage-based/pricing-plans) — New billing model using `bpp_` IDs, `checkout_items` API

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
   - New user authenticates → immediately redirected to `/billing` (application-level gate)
   - User sees $3/month explanation, clicks "Set Up Billing" → Stripe Checkout
   - After checkout → returned to `/billing`, subscription activated synchronously
   - `/billing` shows subscription as active, credit balance as $0.00, prominent "Add Funds" button
   - User can now browse the app (billing gate satisfied)
   - User navigates to agent creation → form available, but warning: "Add funds to run agents"
   - User returns to `/billing`, tops up $10 → Stripe Checkout (one-time payment) → Credit Grant created → balance shows $10.00
   - User creates agent → agent gets `stripe_customer_id`
   - Agent run succeeds → task run stamped with `stripe_customer_id` → request goes to `llm.stripe.com` → credits drawn down
   - Verify in Stripe dashboard: meter events attributed to customer, credit balance decreases
   - Duplicate top-up return: refresh the checkout return URL → no duplicate Credit Grant created (idempotency)
6. **Webhook test**: Use Stripe CLI (`stripe listen --forward-to`) to verify webhook handling
7. **Ownership transfer test**: Change agent's `stripe_customer_id` → verify old runs retain original customer, new runs use new customer
