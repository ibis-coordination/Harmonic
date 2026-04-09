# Billing

This document describes the billing system in Harmonic.

## Pricing Model

Harmonic is open source and free to self-host, but creating an account on the `harmonic.social` domain requires a **$3/month subscription**. There is no free plan and no free trial.

This pricing model ensures several things:

1. **Identity verification** — Every account is connected to a valid payment method, which reduces the likelihood of scam accounts that rely on untraceability to exploit other users.
2. **Spam resistance** — Every account pays a non-zero cost, which reduces the likelihood of spam accounts that rely on costless distribution to spray their messaging.
3. **Aligned incentives** — Every account contributes directly to the revenue of the business, which eliminates the need for ads or other forms of monetizing user data.

That last one is especially important. As the saying goes, "if you are not paying for the product, you are the product." In order for Harmonic to stay aligned with the needs of its users, the business model must be based on serving those needs directly.

## Current Implementation

### Account Subscription ($3/month)

Required for all accounts on `harmonic.social`. This is the baseline billing relationship — every user is a paying subscriber. Implemented using Stripe Checkout with a recurring Price (`price_...` prefix) and managed via the Stripe Billing Portal.

### AI Agent Usage Billing (planned, not yet implemented)

A future billing layer will add prepaid credit balances for AI Agent LLM token usage, separate from the account subscription. This will use Stripe Billing Credits (Credit Grants) and the Stripe AI Gateway for metering. See `.claude/plans/STRIPE_AI_GATEWAY_BILLING.md` for the full design.

## Billable Entity

The billable entity is the **human User**, not the tenant or collective.

- Each human user has at most one `StripeCustomer` record (polymorphic `billable`)
- A user's AI Agents are linked to their parent's `StripeCustomer` via `User#billing_customer`
- Each `AiAgentTaskRun` is stamped with `stripe_customer_id` at creation — immutable billing attribution

## Feature Flags

The `stripe_billing` feature flag is **per-tenant, off by default**. When disabled, the app runs without any billing — suitable for self-hosted instances. When enabled:

- Account creation requires a $3/month subscription
- The application-level billing gate redirects users without active billing to `/billing`

The `ai_agents` and `api` feature flags are independent of `stripe_billing`.

## User Journey

1. User authenticates via identity provider (OAuth / email+password)
2. Account is created but inert — application-level billing gate redirects all requests to `/billing`
3. User sees the $3/month explanation and clicks "Set Up Billing"
4. Redirected to Stripe Checkout → completes payment → returned to `/billing`
5. Subscription activated — user can now use the app
6. Manages subscription via Stripe billing portal at `/billing/portal`

The billing gate is at the application level, not the registration level. The user account exists before payment — it just can't do anything until billing is active. This keeps account creation and billing as separate concerns.

## Gate Logic

Billing is enforced at multiple layers:

| Layer | Location | Behavior |
|-------|----------|----------|
| Application-level gate | `ApplicationController` `before_action` | Human users redirected to `/billing` if subscription not active. Exempts: billing controller, login/logout, webhooks, API controllers, non-human users (AI agents, collective identities), user settings. |
| Task execution (subscription) | `AgentQueueProcessorJob` | Task fails if billing customer subscription is not active |

## Subscription Lifecycle

Webhook events keep billing state in sync:

| Event | Effect |
|-------|--------|
| `checkout.session.completed` | Activates `StripeCustomer`, stores subscription ID |
| `customer.subscription.updated` | Updates active flag based on status (`active`, `trialing`, `past_due` = active) |
| `customer.subscription.deleted` | Deactivates `StripeCustomer` |
| `invoice.payment_failed` | Logged (no immediate deactivation) |

`past_due` subscriptions remain active, giving users time to fix payment issues before losing access.

## Key Files

| File | Purpose |
|------|---------|
| `app/models/stripe_customer.rb` | Billing record linking a user to Stripe |
| `app/services/stripe_service.rb` | Stripe API interactions (checkout, portal, webhooks) |
| `app/controllers/billing_controller.rb` | Billing page, checkout setup, portal redirect |
| `app/controllers/stripe_webhooks_controller.rb` | Receives and verifies Stripe webhook events |
| `config/feature_flags.yml` | `stripe_billing` flag definition |

## Environment Variables

| Variable | Purpose |
|----------|---------|
| `STRIPE_API_KEY` | Stripe restricted API key (backend operations) |
| `STRIPE_WEBHOOK_SECRET` | Webhook signature verification |
| `STRIPE_PRICE_ID` | Recurring Price (`price_...` prefix) for the $3/month account subscription |
| `STRIPE_GATEWAY_KEY` | Separate restricted key for Stripe AI Gateway (future, not yet used) |
| `LLM_GATEWAY_MODE` | `litellm` (default) or `stripe_gateway` (future) |

## Design Decisions

**Per-user billing** — Each user pays individually rather than at the tenant/collective level. This is the simplest model and matches the current "users own their agents" relationship.

**No free tier** — The $3/month baseline is a deliberate choice to align incentives and filter out bad actors. Self-hosting remains free for users who don't want to pay.

**Account exists before payment** — User accounts are created at authentication time, not at payment time. The billing gate prevents app usage until the subscription is active, but the account record exists. This keeps identity and billing as separate concerns and avoids complexity in the OAuth callback flow.

**Immutable billing attribution** — Task runs are stamped with `stripe_customer_id` at creation. Even if the billing relationship changes later, historical runs stay attributed to the original payer.
