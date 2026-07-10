# Harmonic LLM Gateway

A gateway service that makes LLM calls billed to a Harmonic prepaid credit balance,
attributing each call to a payer — a single customer, or a collective's common pool where
cost is spread across consenting members. It exists so a collective's members can pool
their balances to fund their own agents.

Related: [#464 common-pool LLM credits](https://github.com/ibis-coordination/Harmonic/issues/464).
Depends on the Stripe AI Gateway billing already in production (see [docs/BILLING.md](../../docs/BILLING.md)).

## Motivation

Today, only Harmonic's own agent-runner spends prepaid credits, and it does so over an
internal-only channel, with each call billed to a single customer. The goal is to let a
**collective's members pool their prepaid balances** to fund the collective's agents, so
LLM cost is shared fairly without any inter-user payment. A gateway service becomes the
single place that decides, per call, which member's balance pays — and handles that
attribution transparently so the caller never holds a Stripe key or knows how cost is
distributed.

## Scope & rollout posture

**This is a collective feature, not a public LLM reseller.** The value is shared-balance
access to fund a collective's own agents — something you cannot get by going direct to a
provider. It is deliberately *not* a general-purpose "call any model with a Harmonic key"
product; that framing carries resale-rights, money-transmission, acceptable-use, and SLA
risk we are choosing not to take on. Minimizing legal and counterparty risk is a primary
design constraint.

Rollout follows that posture:

- **Initial rollout is internal only.** The sole client is the agent-runner. The gateway
  runs on the internal backend network with **no public endpoint** — no `llm.harmonic.social`
  route, no external keys, no public money-spending surface. This erases most legal/abuse
  concerns from the initial scope.
- **External access is a controlled beta, gated per-collective by an admin-only feature
  flag.** Opening the gateway to non-agent-runner clients happens for *select* collectives,
  not the public. A per-collective feature flag (controlled by app admin, mirroring how
  `stripe_billing` is gated) enables external access for a specific collective; it is not
  publicly advertised. The flag is itself the risk boundary: every external participant is a
  deliberate admin decision, so participation can be vetted and paired with explicit
  commitment enrollment (the consent/contract instrument — see stage 2) before any external
  key works. The architecture supports this as a pure additive (public route + an external
  key type gated by the flag); it lands as stage 4, after the internal loop is proven.

The commitment record is therefore load-bearing in two ways at once: it is the *fairness*
mechanism (who may be drawn) and the *consent/contract* mechanism (explicit agreement to
have one's balance spent). Never auto-enroll anyone into it.

## The seam: one variable, two implementations

The existing relay code ([agent-runner/src/services/LLMClient.ts](../../agent-runner/src/services/LLMClient.ts))
already forwards to `llm.stripe.com` and parameterizes the *only* thing that matters for
billing — a single header:

```
Authorization: Bearer {STRIPE_GATEWAY_KEY}
X-Stripe-Customer-ID: {customer_id}
```

Everything else about the relay is invariant. So the entire difference between "one
customer pays" and "a pool pays" lives in **how you answer "whose customer id goes in
that header for this call?"** — not in the gateway. This is the seam the plan is built
around:

- **Single customer** — `api_key → one stripe_customer_id`. Set header, relay.
- **Common pool** — `api_key → collective pool → pick a consenting member's
  stripe_customer_id`. Set header, relay.

Same gateway, same wire contract. The single-customer case is the N=1 degenerate case of
the pool.

## Architecture

Initial (internal-only) topology — the agent-runner is the only client and there is no
public edge:

```
agent-runner ──internal──► llm-gateway container ──Bearer key + customer header──► llm.stripe.com
                                  │  ▲
                        select-payer│  │record-usage   (HMAC + IP-allowlist internal API)
                                  ▼  │
                             Rails (web:3000)
```

Later (gated) external phase adds a public edge in front of the same gateway, unchanged
below the edge:

```
external client ──HTTPS──► llm.harmonic.social (Caddy) ──► llm-gateway ──► (same as above)
```

- **Gateway is stateless and dumb.** It authenticates the caller, asks Rails who pays,
  relays to Stripe, and reports token usage back. It holds `STRIPE_GATEWAY_KEY` but no
  billing logic.
- **Rails owns all policy** — key→payer resolution, pool membership/consent, eligibility,
  selection, and pricing. Single source of truth.
- **Reuses the agent-runner deployment template**: separate Docker container on the
  backend network, talking to Rails over the existing HMAC-signed `/internal/*` channel
  ([internal/base_controller.rb](../../app/controllers/internal/base_controller.rb)). The
  public subdomain (via the Caddyfile generator,
  [caddyfile_generator.rb](../../app/services/caddyfile_generator.rb)) is added only in the
  external phase.

## The resolve contract (shared by single customer and pool)

Two internal endpoints, both over the existing HMAC + IP-allowlist channel. The **relay**
(select payer → forward to Stripe → return verbatim) is written once and never changes as
payer types are added. The **ingress** is the part that grows per caller type: today the
caller identifies itself with `X-Harmonic-Task-Run-Id` / `X-Harmonic-Subdomain` routing
headers (agent-runner-specific), and stage 4's external keys will add a different identity
handshake plus real caller auth at the gateway. The seam holds below the handler.

Note the accepted trade: `select-payer` runs per LLM call, so every call costs one extra
internal Rails round-trip (milliseconds against an LLM call's seconds). That is the price
of per-call payer selection, which stage 2's random pick requires.

### `POST /internal/llm-gateway/select-payer` — before relaying

Request. The gateway passes a caller identity; initially that is the agent whose task is
running (agent-runner), later it may be an external gateway key. Either resolves to a
payer:

```json
{ "caller": { "type": "agent" | "gateway_key", "id": "..." }, "model": "anthropic/claude-sonnet-4.6" }
```

Response:

```json
{ "payer_customer_id": "cus_...", "selection_id": "sel_..." }
```

or `{ "error": "pool_exhausted" | "not_authorized" | "model_not_allowed" }`.

Rails: resolve `caller → payer`. If the caller maps to a single customer (an agent's
principal, or a single-customer key), return it directly. If it maps to a common pool,
filter to members who consent (are in the common-pool commitment) and have positive
balance, then **select one uniformly at random** (see below). Validate the model against
the allowlist.

### `POST /internal/llm-gateway/record-usage` — after relaying (async, fire-and-forget)

```json
{ "selection_id": "sel_...", "input_tokens": 812, "output_tokens": 344, "status": "ok" }
```

Rails computes cost from token counts × the per-model rate (pricing stays in Rails, never
in the gateway) and logs it for observability. Under uniform-random selection this does
**not** feed back into future selection — it is purely for accounting and monitoring.
Runs after the client already has its response; retries on failure.

## Selection strategy: uniform random

For a pool of N eligible members, `select-payer` picks one **uniformly at random**. Each
member pays 1/N of every call's cost in expectation, so cumulative shares converge to
equal.

Why uniform random over the alternatives:

- **vs. round-robin** — round-robin equalizes call *counts*, not *dollars*, and can
  phase-lock (if expensive calls recur on a period aligned with N, one member
  systematically eats them). Random has no phase to lock onto.
- **vs. greedy least-paid** — greedy is tighter (bounds the max spread to one call's cost)
  but requires a durable per-(pool, member) cumulative-paid ledger, optimistic
  reservation, concurrency control (`FOR UPDATE SKIP LOCKED`), and a new-member
  initialization policy. Uniform random needs **none** of that — it is memoryless.
- **Join-time problem dissolves.** Because there is no per-member history, a member who
  joins later is simply eligible from that point on; there is nothing to catch up on and
  no initialization decision.
- **No concurrency contention.** Stateless selection means concurrent calls pick
  independently — no locking, no reservation.

**The one tradeoff — short-run variance.** Cumulative fairness is asymptotic. The absolute
dollar spread between the luckiest and unluckiest member grows like √(number of calls)
even as the relative spread shrinks. High-volume pools wash this out and nobody notices;
a low-volume pool making a handful of expensive calls could see one member reproducibly
pay 2–3× their share for a while.

**Not a one-way door.** The selection policy is fully encapsulated in `select-payer`. If a
low-volume pool ever needs tighter fairness, add the `cumulative_paid` ledger and switch
that endpoint to greedy least-paid — no change to the gateway or the wire contract.
`record-usage` already carries the per-call cost the ledger would need.

## Deployment

- **New container** `llm-gateway` on the backend network (mirrors agent-runner), holding
  `STRIPE_GATEWAY_KEY` and the internal HMAC secret. **Initially internal-only** — reachable
  by the agent-runner at `http://llm-gateway:PORT`, with no frontend exposure at all.
- **Caddy (external phase only).** The public edge is not built in the initial project.
  When external access is opened, add `llm.harmonic.social → llm-gateway:PORT` via the
  Caddyfile generator (or a static block for testing). Unlike tenant blocks, this subdomain
  routes to the gateway container, not `web:3000`.

  **Decided: a dedicated subdomain (`llm.harmonic.social`), not a per-tenant path
  (`<tenant>.harmonic.social/llm`).** The API key already carries all identity the gateway
  needs — it resolves to a customer or a pool (in a collective, in a tenant), so a tenant
  in the URL is redundant and introduces a second identity source that can disagree with
  the key (validation friction for no benefit). The gateway is a *platform* service (one
  gateway serves every pool), so a dedicated host matches its altitude; a per-tenant path
  implies a per-tenant feature. Routing is one static block decoupled from tenant lifecycle,
  vs. fanning a `handle /llm/*` reverse-proxy into every generated tenant block and
  permanently reserving `/llm` in Rails' per-tenant URL namespace. `https://llm.harmonic.social`
  also reads as a conventional LLM provider base URL — drop-in for OpenAI-compatible clients.
  The `*.harmonic.social` wildcard cert already covers `llm.`, so no new cert. A per-tenant
  path would only win for tenant-branded/white-label endpoints, which don't fit keys that
  map to pools rather than tenant brands — and that stays additive later (point a custom
  domain at the same gateway; keys carry identity regardless of host).
- **Internal auth**: gateway → Rails uses the same HMAC-SHA256 + timestamp + nonce + IP
  allowlist as the agent-runner. Add one direction: Rails must accept gateway-originated
  internal calls (`select-payer`, `record-usage`).

## Implementation stages

Stages 1–3 are **internal-only**: the gateway exists, the agent-runner uses it, pools work,
and a minimal UI proves the loop — all behind the backend network, no public endpoint.
Stage 4 opens a **flag-gated external beta** to select collectives once the internal loop is
proven. Each stage is independently landable and leaves the system working.

### Stage 1 — Internal gateway, agent-runner as the only client (single customer)

Stand up the `llm-gateway` container (internal-only, no public edge) and route the
agent-runner's `stripe_gateway`-mode calls through it instead of calling `llm.stripe.com`
directly. LiteLLM-mode calls stay unchanged. This move is the point of the whole design: it
takes payer-selection authority out of dispatch and makes the gateway the **single** place
that does Stripe attribution — which is what lets pools apply to internal agents for free in
stage 2 (their calls resolve to a pool instead of a single customer with no agent-runner
change).

**The core is a lift-and-shift.** The existing stripe_gateway relay in
[LLMClient.ts:81-170](../../agent-runner/src/services/LLMClient.ts#L81) (attach
`Bearer STRIPE_GATEWAY_KEY` + `X-Stripe-Customer-ID`, POST `llm.stripe.com`, map 402/429,
log `llm_request`) moves verbatim into the gateway; the only change is that the customer id
is resolved via `select-payer` rather than passed in.

Tasks:

1. ✅ **`llm-gateway` service** — built as a second entrypoint in the agent-runner package
   (`src/gateway/`: Relay + StripeUpstream Effect services, plain-node handler/server),
   internal-only, reusing `HmacSigner` / `RailsHttp` / `Logger`. Holds `STRIPE_GATEWAY_KEY`
   (fail-fast boot check). Relay + handler unit-tested.
2. ✅ **Rails `Internal::LLMGatewayController#select_payer`** (inherits
   `Internal::BaseController` — HMAC + IP allowlist) + `LLMGateway::PayerResolver`. Resolves
   the task run → stamped billing customer, verifies the pricing-plan subscription (no live
   balance fetch — see Open decisions), returns `{ payer_customer_id }` or a coded error.
   Request-tested incl. cross-tenant isolation. (`selection_id` deferred to stage 2 with
   `record-usage`, its only consumer.)
3. ✅ **Agent-runner rewire** — `stripe_gateway` mode posts to the gateway with
   `X-Harmonic-{Task-Run-Id,Subdomain,Model}` headers; litellm mode unchanged.
   `stripe_customer_stripe_id` removed from the dispatch stream and task plumbing
   (legacy payloads still parse); the runner holds no Stripe credentials.
4. ✅ **Wiring** — `llm-gateway` compose service (same image, gateway entrypoint) in dev and
   prod behind a `stripe` profile: prod enables via `COMPOSE_PROFILES=stripe` in the server
   `.env` (deploy-managed — NOT started once by name like litellm), dev via `start.sh`
   auto-adding the profile when `STRIPE_GATEWAY_KEY` is set. `billing:gateway_health` now
   probes the gateway's `/health` instead of checking a Rails-side key. Deploy docs +
   enablement runbook updated.
5. **Tests (TDD, alongside each task)** — unit/request coverage done for 1–4. Remaining
   before exit: the live parity smoke test — run the stack with the gateway enabled,
   confirm an internal agent task bills via `llm_request` logs on both services + a
   balance drop.

Scope boundaries (deferred because Stage 1's only caller is the trusted agent-runner):
**streaming (SSE)**, **model allowlist**, **rate limiting**, **request-size caps** → stage 4
(untrusted external callers; the agent-runner doesn't stream and models are already validated
at dispatch). **`record-usage` persistence + usage table** → stage 2 (first consumer is the
pool breakdown; Stage 1 verifies via logs + balance, as the current smoke test does).

Small decisions: `selection_id` = stateless signed token carrying
`(collective_id, payer_user_id, model)` (uniform-random needs no reservation, so no per-call
write); agent-runner→gateway auth uses a **separate** HMAC secret from `AGENT_RUNNER_SECRET`
(independent rotation/revocation, sets up stage-4 isolation); keep dispatch preflight as an
early-abort with `select-payer` authoritative per-call; share the HMAC/http modules between
agent-runner and gateway rather than copy (avoids crypto drift).

Exit criteria: internal agents bill identically to today, now via the gateway; parity
confirmed before proceeding.

### Stage 2 — Common-pool mechanics, proof of concept (env-configured)

**Rescoped 2026-07-09: prove the end-to-end mechanics with the most lightweight,
reversible implementation possible.** Pool *management* (how pools are created, who
consents, how membership changes) is a larger feature we are deliberately not designing
yet — no schema, no models, no UI, no feature flags, no permanent decisions.

- Pool definition = `LLM_POOL_CONFIG` env var: `{"<agent-id>": ["cus_a", "cus_b"]}`,
  mapping an agent to the Stripe customers whose balances jointly fund it. Unset = no
  pools. Delete the var and the PoC is gone.
- `PayerResolver` picks uniformly at random from the pool per call (pool wins over a
  stamped individual customer) and logs each selection.
- Dispatch skips the individual billing checks for a pool-configured agent (it has no
  personal billing customer) and routes it `stripe_gateway`; the relayed Stripe 402 is
  the balance gate. Gateway/runner code unchanged.
- Usage accounting for the PoC = Rails logs (`Pool payer selected task_run=... payer=...`)
  plus the Stripe dashboard. The usage table / `record-usage` endpoint wait for the real
  feature.

Exit criteria: a pool-configured agent's calls draw down different members' balances
across calls, observed on real Stripe customers, with the distribution verified in tests.

Design notes banked for the real feature (from the abandoned first cut, never committed):
commitment-subtype consent instrument; join-deadline vs funding-window semantics (the
roster could freeze before the first draw); critical-mass-as-activation; window overlap
rules; thread-scope-safe pool lookups (commitment participant counting via the
collective-scoped association breaks outside request contexts). None of these are
decisions yet.

### Stage 3 — Minimal UI to prove end-to-end

Only enough UI to exercise the backend by hand:

- Create / join a common-pool commitment for a collective (explicit participation).
- View the per-collective usage breakdown (realized cost vs. fair share).

Explicitly *not* the real management experience.

Exit criteria: a human can set up a pool in the UI, run a collective's agents through it,
and watch the cost distribute — proving the full backend loop.

### Stage 4 — External beta access (per-collective, admin-gated flag)

Open the gateway beyond the agent-runner, to *select* collectives only. Additive to the
architecture; the per-collective admin-only feature flag is the boundary (see Scope &
rollout posture). Not publicly advertised.

- **Per-collective feature flag**, app-admin controlled (mirrors `stripe_billing` gating).
  External keys for a collective work only while its flag is on.
- **Gateway ingress auth.** Today the gateway trusts the backend network (any peer can
  relay a money-spending call — acceptable while the network holds only trusted services).
  External access requires authenticating callers at the gateway itself, and an external
  identity handshake (key-based) alongside the internal task-run headers.
- Public `llm.harmonic.social` edge (Caddy) + an external gateway-key credential type,
  scoped and revocable, with per-key spend caps and rate limits.
- The untrusted-caller protections deferred from stage 1: **streaming (SSE) passthrough**
  (external clients stream), **model allowlist** enforced at the gateway, **rate limiting**,
  and **request-size caps**.
- **Internal/external traffic isolation** so a beta collective's runaway usage or a stolen
  key can't take down internal agents (see Open decisions).
- Explicit commitment enrollment as the consent/contract gate for every external
  participant; acceptable-use framing sized to a vetted beta (the admin gate is the primary
  abuse control, so full public-scale AUP enforcement is not a prerequisite).

Exit criteria: a flagged beta collective can drive external LLM calls billed to its pool,
isolated from internal traffic, with the flag as a one-switch off ramp.

### Deferred — full pool management UX (separate project)

The design-heavy surface: setup and consent flows, monitoring dashboards, spend controls,
per-member distribution transparency, leaving a pool, etc. Out of scope here; tracked as
its own project. This initial project builds only the minimal UI in stage 3.

## Open decisions

- **Balance freshness at selection — decided for single customer, one sub-decision left
  for pools.** `select-payer` performs no live balance fetch (slow, stale, and it conflates
  a Stripe API error with an empty balance). The balance gate is dispatch preflight (once
  per task) plus the relay passing through Stripe's 402 — and the Stripe gateway team has
  **confirmed zero-balance rejection is enabled** on the account, so the 402 is
  authoritative, not assumed. Remaining for stage 2: how the pool eligibility filter
  learns who is dry — short-TTL balance cache vs. treat a relay 402 as "dry now", mark the
  member, re-pick once. Lean 402-retry (no cache invalidation problem).
- **Model allowlist scope.** Per-gateway-key, per-pool, or global? Reuse
  `StripeGatewayModelMapper`'s mapping/validation.
- **Internal/external traffic isolation (external phase).** After external access exists,
  external abuse, rate-limit saturation, or an upstream abuse flag on the shared Stripe
  account would otherwise take down internal agents too (they route through the same
  gateway). Likely resolution: one gateway *service*, two credential/quota lanes (separate
  gateway keys and/or rate-limit buckets). Decide when scoping the external phase.
- **Abuse & spend caps (external phase).** A public money-spending endpoint needs per-key
  rate limits and per-key/per-pool spend ceilings independent of Stripe's balance gate,
  plus a top-up chargeback posture (prepaid + consumable + card dispute = losing both the
  money and the usage). Not needed while internal-only.
- **Stored-value / pool legal structure.** Before external money flows, get a legal read
  that the pool's direct-pay-per-call design (no inter-user transfer) stays clear of
  money-transmission/stored-value regulation. Product framing itself is **decided** —
  collective feature, not public reseller (see Scope & rollout posture).
- **Deferred — usage reconciliation with Stripe.** Whether/how to true up Harmonic's
  estimated `record-usage` costs against Stripe's actual metered charges (Stripe as source
  of truth), and whether per-call metadata can make the per-collective split
  Stripe-authoritative. Out of scope for the initial project; revisit once the backend loop
  is proven.
