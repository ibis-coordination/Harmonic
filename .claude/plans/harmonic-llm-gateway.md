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
headers (agent-runner-specific); stage 4's external calls identify the agent by its own
API token (type `llm_gateway`), forwarded to Rails for validation. The seam holds below
the handler.

Note the accepted trade: `select-payer` runs per LLM call, so every call costs one extra
internal Rails round-trip (milliseconds against an LLM call's seconds). That is the price
of per-call payer selection, which stage 2's random pick requires.

### `POST /internal/llm-gateway/select-payer` — before relaying

Request. The gateway passes a caller identity; initially that is a task run (agent-runner),
later an external agent authenticated by its `llm_gateway`-type API token. Either resolves
to the agent, and the agent resolves to a payer:

```json
{ "caller": { "type": "task_run" | "agent_token", "id": "..." }, "model": "anthropic/claude-sonnet-4.6" }
```

Response:

```json
{ "payer_customer_id": "cus_...", "selection_id": "sel_..." }
```

or `{ "error": "pool_exhausted" | "not_authorized" | "model_not_allowed" }`.

Rails: resolve `caller → agent → payer`. The funding mapping hangs off the agent, never
the credential: an agent in a pool draws from the pool (filter to consenting members,
**select one uniformly at random** — see below); otherwise its own billing_customer pays.
Validate the model against the allowlist.

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

**Working sketch for the real feature (2026-07-10): primary principal + `agent_funders`
collective.** This is the current design direction — a sketch to build the first cut
from, not yet a shipped decision.

The structure: every agent keeps exactly one **primary principal** — a human, publicly
listed, accountable for the agent (and carrying its seat subscription), exactly today's
`parent`. Token funding comes from an **`agent_funders` collective** (a fourth
`collective_type`, immutable at creation like the others): joining it IS consenting to
fund its agents' LLM usage from your own prepaid balance. Two crisp rules instead of one
overloaded one: *the primary principal answers for the agent; the funding collective pays
its tokens.* "Who pays?" and "who's responsible?" each have exactly one answer.

Rules agreed in design discussion:

1. **One name per role.** Funding members are "funders," never "secondary principals" —
   "principal" stays singular and human. Funders carry no accountability slice.
2. **The primary principal must be a funding member** — accountability with skin in the
   game; their own customer is one of the pool draws.
3. **Public listing splits by audience**: the agent shows "funded by ⟨collective⟩"
   publicly; the member roster keeps the collective's normal visibility. No per-member
   listed/unlisted flag.
4. **No primary, no service**: if the primary leaves (the collective or the platform),
   the agent suspends until another funding member steps up as primary. Enforced at
   dispatch/select-payer.

Implementation shape: `parent` association unchanged (human). New agent → funding
collective association. `PayerResolver.resolve_for_agent` / `pool_customer_ids` becomes
DB-backed — funding collective → consenting members → their Stripe customers,
uniform-random per call — replacing `LLM_POOL_CONFIG`. Camp B intact: each member's own
balance pays Stripe directly per call; the collective never holds funds.

Open questions to resolve at build time:

- **Consent duration**: open-ended-until-exit (what membership naturally gives) vs the
  time-bounded/renewable window argued for in the earlier commitment design ("time-bound
  establishes clearer expectations and lowers risk"). Possibly membership admits you and
  funding participation rides a renewable window (dues-like).
- **Agent admission governance**: admitting an agent spends everyone's money; a Decision
  is the natural gate. Who can propose, what threshold.
- **Dry-member handling** (402-retry vs balance cache) — still hostage to Stripe's answer
  on the zero-balance blocker.
- How `agent_funders` interacts with `billable_types`, listability, and the join UX (all
  keyed on `collective_type` today).

Notes carried from the abandoned commitment-subtype cut (still relevant where the
commitment instrument returns, e.g. renewable funding windows): join-deadline vs
funding-window semantics; critical-mass-as-activation; window overlap rules;
thread-scope-safe pool lookups (collective-scoped associations misbehave outside request
contexts — resolve membership via `tenant_scoped_only` + explicit ids).

### Stage 3 — Minimal UI to prove end-to-end

Only enough UI to exercise the backend by hand:

- Create / join a common-pool commitment for a collective (explicit participation).
- View the per-collective usage breakdown (realized cost vs. fair share).

Explicitly *not* the real management experience.

Exit criteria: a human can set up a pool in the UI, run a collective's agents through it,
and watch the cost distribute — proving the full backend loop.

### Stage 4 — External beta access (identity-keyed, per-collective admin-gated flag)

Open the gateway beyond the agent-runner, to *select* collectives only. Additive to the
architecture; the per-collective admin-only feature flag is the boundary (see Scope &
rollout posture). Not publicly advertised.

**Identity-keyed, not funding-keyed (decided 2026-07-09).** There is no separate
"gateway key" credential type. External gateway calls authenticate with the agent's own
API token; the token answers only "who is calling." Funding resolution reuses the exact
agent→funding mapping the internal path uses (agent → pool, or agent → its
billing_customer) — the key never points at money, the agent does. This keeps the purpose
legible: an API key belongs to a specific external agent, so a gateway call is that agent
powering itself, attributable and revocable per identity. `select-payer` gains a second
caller type (authenticated agent identity instead of task-run id) in front of the same
funding logic.

**Three mutually exclusive token types (formalizing `mcp_only`).** Every ApiToken has
exactly one type, chosen at creation, never changed:

| Type | Who can hold one (user-issued) | Reaches |
|---|---|---|
| `rest` | humans, external agents | REST / markdown endpoints only |
| `mcp` | external agents only | `/mcp` only |
| `llm_gateway` | external agents only | the gateway only |

Internal agents cannot have user-issued API keys at all; the agent-runner's ephemeral
task-scoped tokens (`internal: true`, minted by dispatch) are the one carve-out and stay
type `mcp`. Migration: `mcp_only: true` → `mcp`, `false` → `rest`; nothing existing
becomes `llm_gateway`, so no pre-existing token gains spending power. This subsumes the
previously planned mcp/rest mode-exclusivity work (the action-context bypass closure) —
one migration, three values instead of two. Enforcement is three symmetric gates: each
surface accepts exactly its own type. A leaked token is exactly one kind of incident:
data access (rest), audited agent action (mcp), or spend with zero data access
(llm_gateway).

**Ingress BUILT (2026-07-10, branch llm-gateway-ingress; implementation plan in
llm-gateway-stage4-ingress.md):**

- **Tenant-level `llm_gateway` feature flag** (decided over per-collective: mirrors
  `stripe_billing` exactly; per-collective gating arrives with the real pool feature).
  Toggle appears automatically in tenant admin settings.
- `llm.<hostname>` Caddy block forwarding ONLY `/v1/*` to the gateway; the gateway's
  unauthenticated internal relay path stays unreachable from outside.
- OpenAI-compatible `POST /v1/chat/completions` with the agent's llm_gateway key as
  Bearer. Rails authenticates per call via `select-payer-for-token`
  (`ApiToken.authenticate_llm_gateway` — cross-tenant hash lookup, thread re-scoped from
  the token's tenant) and returns payer + mapped model; gateway stays stateless, so
  revocation takes effect on the next call. Model validation via
  `StripeGatewayModelMapper`; OpenAI-shaped error bodies pass through verbatim.
- **Streaming (SSE) passthrough** — upstream bytes pipe straight through; one code path
  serves stream and non-stream.
- **Per-key rate limits** (in-memory sliding window, `GATEWAY_EXTERNAL_RPM`=20 /
  `GATEWAY_EXTERNAL_RPD`=500) + **request-size cap** (`GATEWAY_MAX_BODY_BYTES`=1 MB) as
  the spend-rate stopgap; **dollar spend ceilings deferred** until record-usage
  persistence exists.
- Dev E2E verified through the real edge: 401/403/429 (with Retry-After) negative paths,
  and the valid-key path relaying Stripe's balance-rejection 400 verbatim (full-chain
  proof while the Stripe blocker stands).

Still remaining for the beta:

- Prod DNS for `llm.harmonic.social` (deploy step, not code).
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
