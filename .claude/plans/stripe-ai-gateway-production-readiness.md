# Stripe AI Gateway — Production Readiness

> **Status 2026-07-05:** Phases 2–6 implemented on branch `stripe-gateway-routing` (6 commits): `StripeGatewayModelMapper` + fail-fast dispatch mapping, per-task `llm_gateway_mode` stream field (Rails decides; runner env var is fallback-only), structured `llm_request` logs + `billing:gateway_health` rake task, BILLING.md runbook + `.env.example` vars, and `test/manual/billing/gateway_enablement.manual_test.md`. Remaining: Phase 1 dashboard steps (restricted key, product ID check, raw `llm.stripe.com` call — Dan), merge, then Phase 6 smoke test execution and Phase 7 cutover.

## Where we are

The Layer 2 credit-billing implementation from the [original plan](completed/2026/04/STRIPE_AI_GATEWAY_BILLING.md) shipped in v1.6.0 (April 2026). The code is feature-complete on paper — `StripeService.create_credit_topup_checkout` / `create_credit_grant_from_checkout` / `get_credit_balance` all exist ([stripe_service.rb:262](../../app/services/stripe_service.rb#L262)); the webhook disambiguates subscription vs credit-topup; the billing controller has a `topup` action; the views render a balance + Add Funds dropdown; the dispatcher does a preflight balance check ([agent_runner_dispatch_service.rb:71](../../app/services/agent_runner_dispatch_service.rb#L71)); the agent-runner LLM client routes to `llm.stripe.com` and sends the `X-Stripe-Customer-ID` header when `LLM_GATEWAY_MODE=stripe_gateway` ([LLMClient.ts:82-97](../../agent-runner/src/services/LLMClient.ts#L82)).

But it has never been turned on. Two months later, several gaps make a straight env-var flip unsafe.

---

## Production-blocking gaps

### 1. Model names sent to Stripe are in LiteLLM format, not Stripe format

The dispatcher publishes `model: ai_agent.agent_configuration["model"]` to the Redis stream ([agent_runner_dispatch_service.rb:152](../../app/services/agent_runner_dispatch_service.rb#L152)). The agent-runner forwards that string verbatim to the LLM endpoint ([LLMClient.ts:101](../../agent-runner/src/services/LLMClient.ts#L101)).

Users pick model names from [litellm_config.yaml](../../config/litellm_config.yaml) — `default`, `claude-sonnet-4`, `claude-haiku-4`, `gpt-4o`, etc. Stripe's AI Gateway expects `provider/model` strings (e.g. `anthropic/claude-sonnet-4-5`, `openai/gpt-4o`). The original plan accounted for this with `StripeModelMapper`, which was deleted somewhere during the agent-runner TypeScript migration. **No translation layer exists today.** Any agent run with `stripe_gateway` mode on will currently 400 from Stripe.

The default model is worse: `default` resolves to Arcee Trinity, which Stripe doesn't proxy at all. Even if we fix the format, switching the default tenant to gateway mode breaks every agent that hasn't explicitly chosen an Anthropic/OpenAI model.

### 2. Gateway routing is global but billing is per-tenant

`stripe_billing` is a per-tenant feature flag ([feature_flags.yml:64](../../config/feature_flags.yml#L64)). `LLM_GATEWAY_MODE` is a single process-wide env var read by both the Rails dispatcher and the agent-runner. The moment we set it to `stripe_gateway`, **every** tenant's agents route through Stripe — including tenants where `stripe_billing` is off and no `billing_customer` exists. For those, the dispatcher skips the preflight, no customer ID gets stamped, the request hits Stripe with a missing/empty `X-Stripe-Customer-ID`, and Stripe rejects it.

For a single-billed-tenant deployment (harmonic.social) this is fine — but we should make the routing decision per-task, not per-process, so this isn't a foot-gun later. The cleanest fix: the agent-runner already receives `stripe_customer_stripe_id` per task in the Redis stream payload ([agent_runner_dispatch_service.rb:155](../../app/services/agent_runner_dispatch_service.rb#L155)). It should pick the gateway based on whether that field is populated, not on a global env var.

### 3. Stripe AI Gateway availability was never re-verified

Open question #1 in the original plan: "is `llm.stripe.com` GA, and is the `AI Gateway` restricted-key permission visible in Stripe's UI?" That was the deployment blocker in March 2026, and there's no commit, doc, or runbook note suggesting it's been confirmed. We need to actually create the restricted key with that scope and confirm it works against a small test call before going any further.

### 4. No observability for gateway responses

`LLMClient.ts` catches 402 and rephrases it as "Payment required. Please check your billing setup." ([LLMClient.ts:122-124](../../agent-runner/src/services/LLMClient.ts#L122)) — but nothing distinguishes that from any other LLM failure in logs/metrics. No Sentry breadcrumb, no counter for 402/429/success, no health check, no rake task. If we flip the switch and 5% of requests start 402'ing because of, say, a credit-grant race or an unmapped model, we won't notice until users complain.

### 5. Untested integration since the MCP migration

Agent-runner went through a substantial refactor in mid-June (71aabfd2 and follow-ups) — direct REST → /mcp for agent-acting calls. The `LLMClient` path was preserved, but the gateway flow has not been exercised end-to-end since. The `agent_runner_dispatch_service_test.rb:321` test toggles the env var but doesn't actually hit Stripe.

### 6. Documentation and runbook gaps

- `.env.example` doesn't mention `STRIPE_CREDIT_PRODUCT_ID` or `STRIPE_MAX_TOPUP_CENTS` — the dispatcher will `KeyError` if `STRIPE_CREDIT_PRODUCT_ID` is unset.
- No deployment runbook documenting the order of operations (set key → set mode → smoke test).
- No rollback procedure documented.
- `docs/BILLING.md` describes Layer 2 as built but doesn't say it's off in prod.

---

## Plan

### Phase 1 — Stripe-side verification (do first, blocks everything)

> **Status 2026-07-05:** Access CONFIRMED — the harmonic.social Stripe account is in the LLM gateway private preview. Remaining Phase 1 items: create the restricted key (step 3), verify `STRIPE_CREDIT_PRODUCT_ID` (step 4), and make one successful raw call to `llm.stripe.com` (step 5). Also check what markup (if any) the gateway supports on passed-through token costs.

1. Log into the Stripe dashboard for the harmonic.social account.
2. Open Developers → API keys → Create restricted key. Confirm an "AI Gateway" permission row exists. If it doesn't, the rest of this plan parks until it does.
3. Create the restricted key with: AI Gateway (write), Billing Credit Grants (write), Billing Credit Balance Summary (read), Checkout (write — already used). Save as `STRIPE_GATEWAY_KEY`.
4. Verify `STRIPE_CREDIT_PRODUCT_ID` (`prod_UE7KI2m3xrm2eu` per `.env`) still exists and is named appropriately.
5. From a dev container, hit `POST https://llm.stripe.com/chat/completions` with the new key against a known good Anthropic model (no customer ID — just confirm the endpoint accepts the key). Document the exact request that succeeded.

### Phase 2 — Fix the model-name format gap

Bring back the translation layer. Two options:

**Option A (recommended): translate in Rails at dispatch time.** Add `StripeGatewayModelMapper` ([app/services/stripe_gateway_model_mapper.rb](../../app/services/stripe_gateway_model_mapper.rb)) that maps the LiteLLM-config names to Stripe gateway names. Translate inside `AgentRunnerDispatchService#publish_to_stream` *only when* the task will route through the gateway (see Phase 3). Unmapped models raise → task fails fast with "Model X is not available on the billing gateway. Choose Y." This is better than translating in TypeScript because the mapping table lives next to the rest of the Ruby billing logic and unit tests are cheaper.

**Option B:** translate in `LLMClient.ts`. Slightly closer to the wire but splits config between Ruby (which knows the litellm name space) and TS (which would need to be kept in sync).

Either way, decide the supported-model whitelist explicitly: Anthropic Claude family + OpenAI GPT-4o-class, at minimum. Arcee/Ollama/free-tier models are *not* available via gateway and must remain available only when the request routes to LiteLLM.

Also: change the per-tenant default model from `default` (Arcee Trinity) to a Stripe-routable model **when `stripe_billing` is on for that tenant** — otherwise every new agent in that tenant lands on an unsupported model. Either pick a sensible cross-tenant default (`claude-sonnet-4`) or surface the choice in the AI agent form when billing is on. The form already accepts the model — it's the default that's wrong.

### Phase 3 — Per-task gateway routing

Replace the global env-var decision with a per-task decision:

1. Rails: `AgentRunnerDispatchService` decides whether the task should route through Stripe. Today: `ENV.fetch("LLM_GATEWAY_MODE", "litellm") == "stripe_gateway"`. New: `tenant.feature_enabled?("stripe_billing") && billing_customer&.stripe_id.present?`.
2. Add a new Redis-stream field: `llm_gateway_mode` (`"stripe_gateway"` or `"litellm"`), set per task.
3. Agent-runner: `LLMClient` reads the mode from the task payload instead of from `Config`. The env var becomes a *default* for tasks that don't carry the field (and for legacy stream entries during rollout).
4. The preflight balance check moves from "is env var set?" to "is `stripe_billing` on for this tenant AND does this agent have a billing customer?" — i.e. the same condition that routes the task. No skew possible.

This change also fixes the documentation problem: `LLM_GATEWAY_MODE` stops being a global toggle and becomes deprecated. Drop it from production once everything is per-task.

### Phase 4 — Observability

Before flipping anyone in prod:

1. Agent-runner `LLMClient`: emit structured log lines on every LLM response with `status_code`, `model`, `stripe_customer_present`, `gateway_mode`, `duration_ms`, `prompt_tokens`, `completion_tokens`. Distinct lines for 402/429/5xx vs success.
2. Sentry: capture 402/5xx with breadcrumb including the same fields (no customer ID in the message body — only present/absent).
3. Add a rake task `billing:gateway_health` that does: count agents-with-billing-customer, count of agents with zero balance, last-24h dispatch failures by error message. Cheap; runs from cron.
4. Health endpoint or admin page widget that surfaces credit balance + last-known-good gateway response for the prod tenant.

### Phase 5 — Documentation and runbook

1. Update `.env.example` with `STRIPE_CREDIT_PRODUCT_ID` and `STRIPE_MAX_TOPUP_CENTS` (with comments referring to the Stripe dashboard).
2. Add `docs/BILLING.md` section: "Layer 2 enablement runbook" — order: (a) set `STRIPE_GATEWAY_KEY` secret in prod env, (b) deploy, (c) verify health rake task passes, (d) enable `stripe_billing` for the target tenant, (e) confirm a known test agent runs and draws balance.
3. Add a rollback section: revoke the restricted key in Stripe, flip `stripe_billing` off for the tenant, restart agent-runner — task routes fall back to LiteLLM, no in-flight requests get mid-flight 402.
4. Drop `LLM_GATEWAY_MODE` from docs once Phase 3 lands.

### Phase 6 — Staging smoke test

Stand up an end-to-end scenario in staging (or against a feature-flagged dev tenant) that:

1. Enables `stripe_billing` on the tenant.
2. Creates a paying user, runs the credit top-up checkout flow, verifies the Credit Grant lands in Stripe.
3. Creates an AI agent with a Stripe-supported model.
4. Runs a task. Verifies request reaches `llm.stripe.com`, response is 200, credit balance drops, agent run succeeds.
5. Drains the balance to ~$0, runs another task. Verifies preflight fails cleanly with the right error message and the UI matches.
6. Re-runs after top-up. Verifies the recovery path.
7. Confirms the LiteLLM fallback still works on a second tenant with `stripe_billing` off (regression check for Phase 3).

Capture the smoke-test as `test/manual/billing/gateway_enablement.manual_test.md` so we can re-run it pre-cutover.

### Phase 7 — Production cutover

1. Set `STRIPE_GATEWAY_KEY` in prod env via the secret store.
2. Deploy (Phase 2–4 code on main).
3. Run `billing:gateway_health` — confirm green.
4. Enable `stripe_billing` for the harmonic.social tenant.
5. Run the test agent end-to-end. Check Stripe dashboard for the Credit Grant draw.
6. Watch logs/Sentry for 24 hours. Rollback procedure is the documented one from Phase 5.

---

## Open questions

1. **Who's the first paying tenant?** harmonic.social is the obvious answer, but we should confirm whether anyone else has the Layer 1 subscription on prod today that would be affected by the Phase 3 routing change. (None, based on a code-only read, but worth confirming against the prod DB.)
2. **Should we set a non-zero minimum balance to dispatch?** Today preflight is "> 0 cents". If a multi-step task burns through $1 of balance mid-run, step N+1 gets a 402. The original plan flagged this as Open Question #4. Probably we accept this and document it in the user-facing copy ("top up before long agent runs"); not worth building a minimum-balance threshold yet.
3. **What's the right top-up minimum?** Code says $1; UI dropdown can be more conservative. Decide before Phase 5 docs land.
4. **Do we need a billing-admin tool to grant credits manually?** For comping or refunds. Not blocking, but easy to add a rake task / admin route now.
