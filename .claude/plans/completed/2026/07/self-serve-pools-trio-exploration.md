# Self-Serve Funding Pools for Trio — Exploration

Status: design discussion only, nothing built. Continues the funding-pool trust-model
thread after the draw-receipts work shipped.

## The proposal

A **paid-plan collective** can open a funding pool **self-serve** (no operator flag),
and that pool **automatically funds trio** — the collective's shared agent. Funding
any *other* agent (a member's own agent) from the pool stays **operator-gated** until
a Harmonic admin enables it.

## Why this line (the trust axis)

- **Trio drawing from the pool**: collective identity as principal, collective-serving
  work, Harmonic-controlled runtime, fully ledgered. Value stays inside the
  collective's shared context — nothing is privately captured. This is what the pool
  was built for → safe to self-serve.
- **A member's own agent drawing from the pool**: individual principal, can serve
  private ends with everyone's balances. This is the appropriation case → operator-gated.

## Relationship to issue #462 (IMPORTANT correction)

#462 ("refactor trio instances to have collective as principal, powered by llm credits
paid for by collective") predates the pool feature. Its premise that a **collective
Stripe customer** is needed is **obsolete**: Stripe doesn't support the pooling we
wanted, which is exactly why the pool feature exists. The pool IS the collective
treasury; enrolled members are the payers. The only surviving piece of #462:
**trio's principal should be the collective identity** (today trio is a `system`
agent that bypasses LLM payment entirely and has no principal — both must change).

## What blocks trio today (two places encode "funded agent's principal must be an enrolled member")

1. `CollectivesController#add_funded_agent` — model validation requires the agent's
   principal to be actively enrolled. Trio's collective-identity principal is not a
   funding member → can't attach.
2. `LLMGateway::PayerResolver.ensure_primary_active!` — refuses draws unless
   `agent.parent_id` is enrolled + an active collective member → trio's draws would
   be refused even if attached.

## Design direction: split the roles the pool conflates

- **Funders** — enrolled human members who consent to be drawn on (unchanged).
- **Spenders** — agents authorized to draw. Today: authorized because principal is a
  funder. Add a second authorization rule: a **system-role agent whose principal is
  the collective identity** may draw from its own collective's pool (enrollment
  already = members' consent that the pool funds this collective's agents; gate only
  on pool having ≥1 funded member).

Enforcement handle for "self-serve = trio only": an attached agent is auto-fundable
iff `system_role.present?` AND principal == collective identity; everything else
requires the operator flag. Forward-compatible: the next curated persona inherits it.

## Prerequisites

- Trio stops being a payment-bypassing `system` agent; routes through PayerResolver's
  pool path with collective identity as principal (the live part of #462).
- Opening a pool auto-funds trio (likely no explicit attach step); `add_funded_agent`
  for non-trio agents flips to requiring the operator flag.

## Open decisions (user's to make, raised but unresolved)

1. **Residual appropriation with trio**: a member could direct trio toward work that
   mainly benefits them, on pooled credits. Much weaker than the external-agent case
   (shared, transparent, collective-principaled, ceiling-bounded); tentatively
   acceptable for self-serve. If it ever bites, the lever is a per-*requester* cap
   (not per-principal — the principal is the collective for all trio use).
2. **What "paid plan" gates**: presumably self-serve pool *creation* only; members
   still each need their own prepaid credits (Stripe customer + pricing-plan
   subscription) to enroll, as today. Assumed yes, not confirmed.

## Current pool setup flow (for reference)

Gates: tenant `stripe_billing` + collective `funding_pools` (operator-managed flag,
3 levels app→tenant→collective, NOT self-serve today) + standard collective.
Flow: (1) admin opens pool with pool-wide per-member ceiling ($ + day/week/month
window, required); (2) members self-enroll — strictly self-serve consent, "match
pool" snapshots the current pool ceiling (so later raises never silently raise
exposure) or custom lower ceiling; enrollment requires prepaid billing; (3) admin
attaches agents (`add_funded_agent`, principal must be enrolled); (4) draws:
PayerResolver picks a random funded enrolled member per call, both ceilings enforced
independently.

## Adjacent shipped/punted context

- **Draw-authorization receipts SHIPPED** (PR #502, branch `funding-pool-draw-receipts`):
  every pool draw stamps `funding_pool_enrollment_id` + `enrollment_draw_cap_cents/period`
  + `pool_member_draw_cap_cents/period` on `llm_usage_records` at selection time.
  Forward-only, no backfill. Pools are **sandbox-only in prod** (confirmed), so no
  cutover note needed.
- **Member-facing itemized draw history: PUNTED** (deliberately — felt complicated).
  Design sketch existed: per-draw rows (when/agent/principal/amount/model/status)
  grouped under window headers showing "$X drawn of your $Y/day ceiling", where the
  receipt makes historical windows show the ceiling actually in force then. Return later.
- Layer 2 (append-only enrollment event log) still deferred until caps become
  collective-set/per-principal.
- Pending: CHANGELOG + version bump post-merge for #501 (merged) and #502.

Memory files: `project_pool_funding_trust_model.md`, `project_funding_pool_page.md`.
