# LLM Gateway: Launch Readiness Plan

Goal: everything required between the current state (1.48.0 in prod; `stripe_billing`
enabled on the sandbox tenant only; zero real users of pools) and opening agent
funding + the LLM gateway to real customers on the main tenant.

Direction locked by this plan (previously exploratory, now decided):
- **Funding pools become children of standard collectives** ("⟨collective⟩'s funding
  pool"), replacing the standalone `agent_funding` collective type. Members opt in
  via explicit enrollment; social membership stays free; "funded by ⟨collective⟩"
  means the collective sponsors the agent and enrolled members pay.
- **Invariants held by design, not machinery:** 1-to-1 agent↔funding-source (no
  fallback chains — a dry pool stops the agent and notifies, never silently bills
  the principal); routing-only (no entity ever holds pooled value); `select-payer`
  stays the single payer-policy choke point; uniform-random draw stays.
- Everything else in `.claude/plans/agent-funding-models-exploration.md` (patronage,
  cross-principal agent pools, personas, recursion, other domains) stays parked
  until there is real usage data.

## Phase 0 — Decisions and external unblocks

**0.1 Stripe zero-balance rejection resolution.** The gateway currently 400s funded
customers (Stripe-side ledger mismatch; thread open with token-billing team). Decide
the fallback now: if unresolved by the time Phase 3 needs live verification, ask
Stripe to disable rejection on the account — the app-side balance gate (shipped
1.48.0) is the per-call guard, and dispatch preflight remains the task-level guard.
Exit criterion: a funded customer's call relays successfully in live mode.

**0.2 Remodel sub-decisions** (small, settle before Phase 1 implementation):
- One pool per collective (recommended: yes; multiple reintroduces naming/identity).
- Enrollment gate = funded billing (active customer + pricing-plan subscription),
  checked at enrollment and continuously at draw time (lapsed/dry members skipped).
- Draw ceiling (`member_daily_draw_cap_cents`) moves from collective to pool.
- Agent attach rule (recommended: agent's principal must be an *enrolled* member,
  preserving the shipped accountability property).
- Whether the main collective can have a pool (recommended: yes — tenant-wide pool).
- Pool lifecycle: create (collective admin), close (admin; attached agents stop —
  1-to-1, no fallback), member exit (drops from next draw; no unwinding).

**0.3 Legal/ToS checkpoint.** Random-incidence pooled funding across members' own
balances, plus external gateway keys, needs terms coverage before real money:
consent language, no-refund-of-drawn-usage, operator's non-custodial posture
(routing-only). Likely small since no funds are held, but it is a launch gate, not
a fast-follow. Owner: Dan.

## Phase 1 — Child-pool remodel (red-green TDD throughout)

Rework #487's shape while it has zero users. Stage 5 machinery (ledger, balance
gate, caps, resolver logic) survives with source changes only.

- **1.1 Schema:** `funding_pools` (belongs_to collective, draw-cap cents, status) +
  `funding_pool_enrollments` (pool, user, timestamps). Migration removes
  `agent_funding` from `VALID_COLLECTIVE_TYPES`, drops the funded-to-join gate, and
  migrates/asserts-empty existing `agent_funding` rows (verify prod + sandbox have
  none; dev has smoke fixtures to recreate). `users.funding_collective_id` →
  `users.funding_pool_id` (keep ledger column `funding_collective_id` semantics by
  stamping the pool's collective, or rename to `funding_pool_id` — decide in
  implementation; point-in-time attribution must survive either way).
- **1.2 Resolver:** `pool_customer_ids` reads enrollments in good standing (funded,
  under pool draw ceiling); error codes unchanged (`pool_exhausted`, `no_primary`,
  etc.). Dispatch bypass keys off `funding_pool_id`.
- **1.3 Surfaces:** pool section on the parent collective's settings (create pool,
  draw ceiling, funded-agents roster, enroll/withdraw self); enrollment consent
  copy (ports the join-page language); "Funded by ⟨collective⟩" on agent profiles
  (label unchanged, now pointing at a real, navigable collective); markdown-UI
  actions for enroll/withdraw/attach/detach.
- **1.4 Deletions:** agent_funding join-gate code, shareable-invite prohibition
  (no longer needed — pools have no invites), type-specific settings sections.
- **1.5 Docs:** BILLING.md LLM Gateway section, help pages (collectives, billing,
  agents), and the doc-followup list in project memory — most naming/navigation
  caveats simply disappear. Dev fixtures: recreate agent-funding-smoke as a pool on
  a standard collective (tmp scripts).

Exit criterion: dev smoke — standard collective with a pool, two enrolled members,
attached agent, payer rotation across members, dry-member skip, cap enforcement —
all green through the real relay chain.

## Phase 2 — Transparency and customer-facing completeness

- **2.1 Usage-transparency view** (launch-required: it is the variance mitigation
  for random draw and the pool's legibility surface). Two surfaces: the pool's page
  on its collective (per-pool spend, per-member incidence over time, per-agent
  breakdown, stale-pending visibility) and "funding you provide" on `/billing`
  (cross-collective: my enrollments, my draws, my agents' spend). Closes the
  navigation gap by construction.
- **2.2 Zero/low-balance notification.** Email (+ web push where enabled) when a
  customer's balance crosses low and zero thresholds; agents stopping silently is
  not acceptable for paying customers. Include pool framing ("you were skipped in
  draws").
- **2.3 `llm_gateway` token type in the token-creation UI** (API-only today) —
  external-agent customers need a self-serve path.
- **2.4 Error-copy pass.** Walk every customer-visible failure (dispatch preflight,
  gateway 402/429 codes, enrollment rejections) and verify the message tells the
  user what to do next. Most exist; this is a review pass, not a build.

## Phase 3 — Ops hardening and live verification

- **3.1 prod-compatible `scripts/generate-caddyfile.sh`** (must target sidekiq or
  /tmp+docker cp; web's /app is read-only in prod) and **RegenerateCaddyfileJob
  failure visibility** (it failed EACCES silently for weeks; needs at minimum error
  reporting/alerting).
- **3.2 Monitoring:** alert on llm-gateway error rates and on ledger anomalies
  (stuck-pending rate, gate fail-closed rate). `billing:gateway_health` is the
  manual check; decide what runs automatically.
- **3.3 Prod config verification:** vendor slugs / per-model rates in the prod
  catalog; env vars (`GATEWAY_BALANCE_*`, `GATEWAY_PENDING_RESERVE_CENTS`,
  `GATEWAY_EXTERNAL_RPM/RPD`) reviewed and set deliberately rather than defaulted.
- **3.4 Live balance-drain smoke test** (blocked on 0.1): top-up → agent task →
  balance drops → zero-balance behavior → notification fires. Manual checklist
  update: pool flows added to `test/manual/billing/`.
- **3.5 Housekeeping:** revoke the old prod test key (`aafd8e50…`, exposed in shell
  history); confirm no other test credentials linger.

## Phase 4 — Main-tenant cutover

Flipping `stripe_billing` on the main tenant activates *all* billing gates
(per-identity subscriptions, paid tiers, agent dispatch gates), not just the
gateway. This is its own project-let:

- **4.1 Audit existing main-tenant billable resources** (humans with tokens/
  webhooks, active agents, upgraded collectives): who would be gated on day one,
  who should be exempted/grandfathered, expected revenue vs. friction.
- **4.2 Comms:** announcement, pricing page/help accuracy, lead time before the
  flip; existing agent owners need warning that agents will require billing.
- **4.3 The flip:** enable flag, watch the first real subscriptions/top-ups,
  runbook smoke (billing:gateway_health, first funded pool).
- **4.4 Rollback rehearsal:** the flag-off path disables all gates (documented
  blast radius) — confirm acceptable and rehearsed.

## Parallel / non-blocking (do when convenient, don't gate launch)

- **Agent-visible budgets:** MCP tool exposing own spend + remaining caps (first
  agent-economics rung; nearly pure exposure of shipped ledger/caps).
- **Per-model rates in the agent model selector** (existing draft plan:
  `display-per-model-rates-in-agent-selector.md`) — pricing transparency when
  customers pay per call.
- Per-key dollar ceilings for external ingress (unblocked by record-usage; RPM/RPD
  stopgap is acceptable at launch scale).

## Explicitly out of scope for launch

Patronage/sponsorship edges; cross-principal agent pools (tier 1) and agent-initiated
pooling; Harmonic-managed persona catalog; pools-of-pools, merging; multi-pool
agents; funding-sources abstraction (extract at the second instrument, not before);
incidence policies beyond uniform-random; non-LLM domains. All mapped in
`agent-funding-models-exploration.md`.

## Suggested order

0.1 immediately (it gates 3.4) and 0.2/0.3 this week → Phase 1 as one focused
branch → Phase 2 (2.1 largest) → Phase 3 → Phase 4 last and deliberately. Phases
1–3 are sequential-ish for one developer; parallel items slot into gaps. The only
hard external dependency in the whole plan is 0.1.
