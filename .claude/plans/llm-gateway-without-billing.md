# LLM gateway without billing

High-level plan. Not scoped for implementation until the stop-condition
question below is settled.

## Goal

Make the external LLM gateway (`llm.<HOSTNAME>/v1/chat/completions`) work on
deployments that have no Stripe billing — self-hosted Harmonic above all — by
letting it forward to the operator's LiteLLM instead of the Stripe AI Gateway.

Today the gateway requires a `stripe_billing` tenant with the `llm_gateway`
flag and a funded payer. None of that is architecturally necessary for the
gateway's other jobs: central key custody, per-agent attribution, revocation.

## What already exists

The stack is closer to this than it looks:

- **The internal lane is already dual-mode.** `LLMClient` takes
  `gatewayMode: "litellm" | "stripe_gateway"` — internal personas on
  non-billing tenants already go straight to LiteLLM, which already holds the
  operator's vendor keys. This mode extends that split to the *external*
  ingress; it introduces no new key custody.
- **Auth is billing-independent.** `llm_gateway` is a first-class `ApiToken`
  type; per-call authentication in Rails works regardless of payment
  processor.
- **Ingress hardening is billing-independent.** Per-key rate limits and the
  body cap live in the gateway handler, before any billing logic.
- **Usage recording works at cost zero.** `LlmUsageRecord` is a ledger row;
  nothing about it requires a nonzero price.

## The couplings to break

All modest; verified against the code 2026-07-26:

1. **`ExternalRelay` is hard-wired to `StripeUpstream`** — the Stripe AI
   Gateway makes the vendor call *and* meters it in one step
   (`stripe.chatCompletionsStream({ customerId, … })`). Needs a LiteLLM
   branch: both sides are OpenAI-compatible, so it is a base-URL and
   auth-header difference plus losing the `customerId`.
2. **`select-payer-for-token` conflates two questions** — *is this key valid*
   and *who pays*. Needs a mode that authenticates the token and validates the
   model but skips `PayerResolver` and `BalanceGate`.
3. **Model catalog comes from Stripe products** (`GatewayModelCatalog`).
   The no-billing source is either LiteLLM's own model list or a config file.
4. **`llm.<HOSTNAME>` routing** must exist in the self-host Caddy config
   (hosted Caddy forwards only `/v1/*`; same rule applies).

## The design question: what stops a runaway call?

On billing tenants, "may this call proceed" is *identical to* "someone can
pay", and BalanceGate is deliberately the sole per-call stop. Remove billing
and there is no stop condition: a looping agent burns the operator's vendor
account with nothing pushing back but the rate limiter.

The BalanceGate stand-in has to be an operator-set policy — likely a per-key
cap (tokens per day, or requests per day) with a deliberate decision about the
default: capped-by-default matches the bridge's bounded-by-default stance;
uncapped-by-default matches "the operator owns the vendor account and its
limits". Settle this before scoping.

Invariants untouched: billing tenants keep BalanceGate as the sole per-call
stop, and `no-LiteLLM-on-billing` still holds — this mode exists only where
`stripe_billing` does not.

## Decisions to settle first

1. **The stop condition** (above) — the one that blocks scoping.
2. **Mode selection.** Deployment-level (env: gateway upstream = litellm) vs
   tenant-level (the `llm_gateway` flag gains meaning on non-billing tenants).
   Deployment-level matches how LiteLLM is configured for the internal lane.
3. **Catalog source.** LiteLLM model-list passthrough (zero config, drifts
   with the operator's LiteLLM) vs explicit config (stable, one more file).
4. **Ledger semantics at cost zero.** Record rows with zero cost, or estimate
   vendor cost from public rates for the operator's information? Zero-cost
   rows are honest and simple; estimates rot.

## Payoff

- Self-hosted agents never hold vendor keys: revoke one `llm_gateway` token
  instead of rotating a vendor key everywhere it leaked.
- Per-agent usage attribution on self-hosted, same ledger as hosted.
- Deletes the standing constraint in
  [llm-gateway-token-in-bridge-handshake.md](llm-gateway-token-in-bridge-handshake.md):
  with this, the handshake-minted gateway token works on *every* deployment,
  and goose-style zero-touch setup stops being a hosted-only story.

## Not in scope

Billing on self-hosted, any change to the billing-tenant path, and the
handshake itself (separate plan; this removes its deployment constraint but
neither depends on the other).

## Sequencing

Independent of the codex harness and the handshake plan. Natural slot: before
or alongside the handshake increment, since it multiplies that increment's
reach.
