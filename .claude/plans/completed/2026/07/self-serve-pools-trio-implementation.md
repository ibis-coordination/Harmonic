# Self-Serve Funding Pools Funding Trio — Implementation Plan

Status: IMPLEMENTED on branch `self-serve-pools-fund-trio` (6 commits, one per
phase, 2026-07-16). PR/merge pending; CHANGELOG post-merge.

Builds on `.claude/plans/self-serve-pools-trio-exploration.md`. Both open questions
resolved: residual appropriation via trio is accepted (no requester cap now), and
"paid plan" gates self-serve pool *creation* only — members still individually need
prepaid credits to enroll (unchanged).

## Goal

1. Trio gets a real principal: the collective's identity user (the live part of #462).
2. Trio stops bypassing LLM payment on `stripe_billing` tenants: it routes through
   the gateway and draws from the collective's funding pool.
3. A **paid-tier** standard collective can open a pool **self-serve**; the pool
   **auto-funds trio**. Funding any other agent stays operator-gated
   (`funding_pools` collective flag), as today.

## Verified current state (investigation findings)

- **Trio today**: `ai_agent` User with `system_role: "trio"`, `parent_id: nil`, no
  StripeCustomer, no ApiToken ([trio_seeder.rb](app/services/trio_seeder.rb)). One
  trio per collective; `collective.trio_user_id` links it (nulled on deactivate, the
  CollectiveMember row survives archived).
- **Payment bypass lives in one place**:
  [agent_runner_dispatch_service.rb:67](app/services/agent_runner_dispatch_service.rb#L67)
  skips billing checks for `ai_agent.system?`, and
  [line 96](app/services/agent_runner_dispatch_service.rb#L96) routes system agents
  to `litellm` instead of `stripe_gateway`. Every trio run (automations and chat
  turns) goes through this dispatch chokepoint.
- **Two blockers encode "funded agent's principal must be an enrolled member"**:
  - [user.rb:254](app/models/user.rb#L254) `funding_pool_assignable` — attach-time
    validation requires the agent's principal to be actively enrolled.
  - [payer_resolver.rb:230](app/services/llm_gateway/payer_resolver.rb#L230)
    `ensure_primary_active!` — per-call check on `agent.parent_id`'s enrollment +
    membership.
- **Pool availability gates** (`feature_enabled?("funding_pools")`, the
  operator-managed 3-level flag) sit at: `create_funding_pool` (:547),
  `enroll_in_funding_pool` (:613), `add_funded_agent` (:696),
  `execute_enroll...` (:922, :1019), pool page `@funding_pools_enabled` (:193, :524),
  settings view [settings.html.erb:313](app/views/collectives/settings.html.erb#L313),
  and the per-call kill switch
  [payer_resolver.rb:214](app/services/llm_gateway/payer_resolver.rb#L214)
  `ensure_funding_pool_available!`.
- **Paid tier**: `Collective#paid_tier?` column-driven state machine (free/paid/lapsed);
  `tier_unlocks_paid_features?` also returns true for main collectives and
  non-billing tenants. Trio itself is already a paid feature
  (`PAID_FEATURE_FLAGS`, `trio_enabled?` requires `tier_unlocks_paid_features?`).
  `downgrade!` deactivates trio; `mark_lapsed!` just flips tier.
- **Every standard collective has an identity user** (`create_identity_user!`
  before_validation; chat + private_workspace collectives don't — they also can't
  have pools, `collective_is_standard`).
- **Enrollment** (`FundingPoolEnrollment#enrollable`) requires human + active member
  + funded billing. Collective identities can't enroll — correct; the new rule
  bypasses enrollment for the collective-principal case rather than faking one.
- `User#create_parent_trustee_grant!` (after_create, [user.rb:962](app/models/user.rb#L962))
  fires for any ai_agent with a parent — would now mint a TrusteeGrant naming the
  collective identity as trio's trustee.

## Design decisions

1. **Spender-authorization rule** (the heart of it): an agent may draw from a pool
   without an enrolled principal iff `system_role.present?` AND its `parent_id` is
   the **pool collective's own** `identity_user_id`. Enforced in both blockers
   (attach validation + per-call resolver). Enrolling in a pool is consent that
   "this collective's funded agents draw from my balance" — the collective's own
   system agent is squarely inside that consent. Forward-compatible: the next
   curated persona inherits it.
2. **Pool availability becomes one method**, `Collective#funding_pools_available?`:
   ```
   standard? && tenant stripe_billing && tenant-level funding_pools flag
     && (paid_tier? || collective-level funding_pools flag)
   ```
   - Self-serve = paid tier. The **tenant-level** `funding_pools` flag (operator)
     stays required — it's the rollout/kill lever per tenant (pools are
     sandbox-only in prod today; main-tenant cutover stays an operator decision).
     The app-level flag remains the global kill switch via the cascade.
   - The **collective-level** operator flag keeps its second meaning: it alone
     unlocks `add_funded_agent` for arbitrary agents. Self-serve pools never allow
     attaching non-trio agents.
   - `paid_tier?` deliberately, not `tier_unlocks_paid_features?`: main collectives
     don't get self-serve pools (operator can still flag them).
   - Lapse/downgrade containment falls out for free: tier leaves `paid`
     → `funding_pools_available?` false → `ensure_funding_pool_available!` refuses
     every draw (existing behavior for the flag). Re-upgrade resumes. No new
     lifecycle code.
3. **Litellm is never used on `stripe_billing` tenants** (there is no litellm in
   prod). Gateway routing loses the system-agent special case entirely:
   `stripe_billing` tenant → `stripe_gateway` for every agent, trio included.
   Consequently trio on a billing tenant REQUIRES a pool to run — no pool (or pool
   suspended/exhausted) → task fails with an actionable message pointing at
   collective settings. Non-billing tenants keep litellm for everything, unchanged.
4. **No trustee grant for system agents**: guard `create_parent_trustee_grant!`
   with `!system?`. A grant naming the collective identity as trustee is inert
   noise, and the backfill (update, not create) wouldn't produce one anyway —
   skipping keeps new and backfilled trios identical.
5. **Auto-fund is reconciliation, not a one-shot**: idempotent
   `Collective#ensure_trio_funded!` — if pool exists (open) and trio_user present
   and not attached, attach. Called from `create_funding_pool` (open/reopen) and
   `TrioActivator#bootstrap!`/`restore!`. Closing the pool leaves trio attached
   (draws already refused; reopening resumes — matches existing pool semantics).
   Trio deactivation leaves it attached (no runs happen anyway; reactivation is a
   no-op reattach).
6. **`remove_funded_agent` refuses trio** with "Trio is funded automatically while
   the pool is open — disable Trio or close the pool instead." Otherwise detaching
   creates a phantom state (trio enabled, pool open, every run failing) that
   `ensure_trio_funded!` would silently undo at the next reconcile point.

## Phases (each red-green: failing tests first)

### Phase 1 — Trio's principal is the collective identity

- `TrioSeeder#create`: `parent_id: @collective.identity_user_id`.
- `User#create_parent_trustee_grant!`: add `return if system?`.
- Data migration: for every `system_role IS NOT NULL` user with `parent_id IS NULL`,
  set `parent_id` to the identity_user_id of the standard collective it's a member
  of (via `collective_members` join — survives deactivated trios whose
  `trio_user_id` link is nulled). Skip if the collective has no identity user.
- `ai_agent_must_have_parent` already permits both nil and present parent for
  system agents — no change.
- Tests: `trio_seeder_test.rb` (parent set, no TrusteeGrant), `user_test.rb`
  (system agent with collective-identity parent valid).

### Phase 2 — Pool authorization for collective-principal system agents

- `User#funding_pool_assignable`: after the enrolled-principal check fails, allow
  when `system? && parent_id.present? && pool.collective&.identity_user_id == parent_id`.
- `PayerResolver.ensure_primary_active!`: return early on the same condition
  (lookup via `Collective.tenant_scoped_only`, matching the resolver's scoping
  discipline). No replacement gate needed — a pool with zero funded members
  already fails as `pool_exhausted`.
- Tests: `funding_pool_test.rb`/`user_test.rb` (trio attaches to its own
  collective's pool; trio of collective A refused on collective B's pool; ordinary
  agent still requires enrolled principal), `payer_resolver_test.rb` (trio draw
  resolves to a random enrolled member with receipt fields; `no_primary` not
  raised; `pool_exhausted` when no funded members; kill switches still bite).

### Phase 3 — Trio routes through the gateway

In `AgentRunnerDispatchService#dispatch`:
- `gateway_mode`: drop the `!ai_agent.system?` condition — `stripe_gateway`
  whenever `tenant.feature_enabled?("stripe_billing")`, litellm otherwise.
- New precondition: `ai_agent.system? && stripe_billing && !pool_funded` →
  `fail_task!("Trio runs on the collective's funding pool. A collective admin can open one in collective settings.")`.
- The existing individual-billing checks continue to skip system agents and
  pool-funded agents; nothing else changes. Trio's model (`TRIO_DEFAULT_MODEL`)
  passes through `StripeGatewayModelMapper` like any billed agent's.
- Tests: `agent_runner_dispatch_service_test.rb` (pool-funded trio →
  stripe_gateway payload; unfunded trio on billing tenant → failed task with the
  message; trio on non-billing tenant → litellm, unchanged).

### Phase 4 — Self-serve pool availability

- Add `Collective#funding_pools_available?` per design decision 2.
- Swap it in at: `create_funding_pool`, `enroll_in_funding_pool`,
  `describe/execute_enroll_in_funding_pool` (:922, :1019), both
  `@funding_pools_enabled` assignments (:193, :524), and
  `PayerResolver.ensure_funding_pool_available!` (replace
  `collective.feature_enabled?("funding_pools")`).
- `add_funded_agent` **keeps** the raw collective-level
  `feature_enabled?("funding_pools")` check; update its error message to say
  attaching agents beyond Trio needs the operator-enabled flag.
- `config/feature_flags.yml` `funding_pools` description: no longer "never
  self-serve" — describe the two-tier model (tenant flag = operator rollout lever;
  collective flag = arbitrary-agent attach + tier-independent unlock).
- Tests: `collectives_controller_test.rb` (paid-tier admin opens a pool with no
  collective flag; free-tier refused without flag; flagged free-tier still works;
  lapsed tier: draws refused via resolver test, page still renders),
  `payer_resolver_test.rb` (paid-tier pool draws without collective flag; draws
  refused after downgrade).

### Phase 5 — Auto-fund trio

- `Collective#ensure_trio_funded!` (idempotent): open pool + `trio_user` present
  → `trio_user.update!(funding_pool: funding_pool)` unless already attached.
- Call from `create_funding_pool` (after open/reopen) and from
  `TrioActivator#bootstrap!` and `#restore!`.
- `remove_funded_agent`: refuse when target is the collective's trio (message per
  design decision 6).
- Tests: `collectives_controller_test.rb` (opening pool attaches trio; reopening
  reattaches; remove_funded_agent on trio → 422), `trio_activator_test.rb`
  (activate with open pool attaches; activate without pool doesn't; deactivate
  leaves attachment).

### Phase 6 — Copy, docs, rollout

- Settings + pool page: show trio in the funded-agents list with an "automatic"
  marker; pool-creation section visible to paid-tier collectives (it already keys
  off `@funding_pools_enabled` — flows from Phase 4); brief line that opening a
  pool funds Trio.
- Help pages (`app/views/help/billing.md.erb`, `collectives.md.erb`, `agents.md.erb`)
  and `docs/BILLING.md`: pools self-serve on the paid plan; trio pool-funded on
  billing tenants. Third-person factual (agents read these too).
- Operator/deploy note: on deploy, **sandbox-tenant trios stop running until their
  collectives open pools** (billing tenant + no pool → refused). Sandbox-only
  blast radius today; main tenant unaffected until stripe_billing cutover, at
  which point pool-or-nothing is the intended economics.
- Operator/deploy note 2: on billing tenants **`TRIO_DEFAULT_MODEL` must be a
  gateway-resolvable name** (`provider/model`, or unset → gateway default).
  LiteLLM-only aliases (e.g. `trinity-large-thinking-free`) fail trio dispatch
  fast via StripeGatewayModelMapper — correct behavior, but the env var and any
  per-trio model overrides need checking before cutover.
- CHANGELOG + version bump post-merge (not in the feature branch).

## Sequencing / branch

One branch (`self-serve-pools-fund-trio`), phases as separate commits in order —
1→2→3 make trio payable, 4→5 make it self-serve, 6 polish. Phase 3 is the only
behavior break (sandbox trio needs a pool), and it ships together with 4+5 so the
self-serve remedy exists the moment the requirement does.

## Out of scope (explicitly)

- Per-requester caps on trio usage (accepted risk; lever documented in the
  exploration doc).
- Member-facing itemized draw history (punted earlier, unchanged).
- Layer 2 enrollment event log (still deferred).
- Any change to enrollment requirements (prepaid credits per member, unchanged).
- Auto-opening a pool on collective upgrade (pool creation stays an explicit admin
  act — the ceiling must be stated, never defaulted).
