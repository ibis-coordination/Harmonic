---
passing: false
last_verified: null
verified_by: null
---

# Test: Stripe AI Gateway Enablement

End-to-end verification that prepaid LLM credits flow correctly: top-up → agent run → balance deduction → clean failure at zero → recovery, plus a LiteLLM regression check. Run this on staging (or a test-mode tenant) before the production cutover, and again after cutover with a small real amount.

## Prerequisites

- Stripe account enrolled in the AI Gateway preview (`llm.stripe.com`)
- `STRIPE_GATEWAY_KEY` set on the llm-gateway service; `STRIPE_CREDIT_PRODUCT_ID` and `STRIPE_PRICING_PLAN_ID` set on Rails (see docs/BILLING.md runbook)
- `llm-gateway` service running (`stripe` compose profile) and healthy (`GET /health`)
- `rails billing:gateway_health` shows the llm-gateway reachable and both config vars present
- Tenant A: `stripe_billing` enabled, a user with an active subscription and one internal AI agent
- Tenant B: `stripe_billing` NOT enabled, with one internal AI agent (regression control)

## Test 1: Top-up

### Steps

1. As Tenant A's user, go to `/billing/topup` and purchase a small credit amount (e.g. $5)
2. Complete Stripe Checkout
3. Run `rails billing:gateway_health`

### Checklist

- [ ] Checkout completes and redirects back to `/billing`
- [ ] Balance shows the granted amount plus any included-usage credits from the pricing plan
- [ ] No `[NO PRICING PLAN SUBSCRIPTION]` marker for the customer (the top-up subscribed them)
- [ ] Stripe dashboard shows the customer subscribed to the pricing plan

## Test 2: Agent run bills the gateway

### Steps

1. Run a short task with Tenant A's agent
2. Watch agent-runner AND llm-gateway logs for `llm_request` lines
3. Run `rails billing:gateway_health` after completion

### Checklist

- [ ] Task completes successfully
- [ ] Runner log lines show `"gateway_mode":"stripe_gateway"`, a `task_run_id`, and a `provider/model`-format model name
- [ ] Gateway log lines show `"gateway_mode":"stripe_gateway"` with a 200 status (the relay reached Stripe)
- [ ] Meter events for the run appear in the Stripe dashboard (Usage-based billing → Meters) within seconds
- [ ] Balance drops by roughly the expected token cost (deduction is aggregated periodically — allow up to an hour, not instant)

## Test 3: Drain to zero fails cleanly

### Steps

1. Run agent tasks until the balance reaches zero (or revoke the remaining credit grant in the Stripe dashboard)
2. Attempt another agent task

### Checklist

- [ ] Task fails at dispatch with "Insufficient credit balance. Add funds at /billing before running agents."
- [ ] No `llm_request` line with `stripe_gateway` appears for the failed task (it never reached the gateway)
- [ ] The failure is visible to the user (task run page / chat error)

## Test 4: Top-up recovery

### Steps

1. Top up again at `/billing/topup`
2. Re-run the agent task

### Checklist

- [ ] Task dispatches and completes without operator intervention

## Test 5: Unmappable model fails at dispatch

### Steps

1. Set Tenant A's agent model to a LiteLLM-only name (e.g. `llama3`)
2. Attempt an agent task
3. Restore the agent's model afterward

### Checklist

- [ ] Task fails at dispatch naming the model and listing available ones
- [ ] After restoring a mapped model, tasks run again

## Test 6: LiteLLM regression (Tenant B)

### Steps

1. Run a task with Tenant B's agent
2. Watch agent-runner logs

### Checklist

- [ ] Task completes via LiteLLM (`"gateway_mode":"litellm"` in `llm_request` lines)
- [ ] No Stripe balance change for any customer
- [ ] System agent (built-in persona) tasks on Tenant A also log `"gateway_mode":"litellm"`
