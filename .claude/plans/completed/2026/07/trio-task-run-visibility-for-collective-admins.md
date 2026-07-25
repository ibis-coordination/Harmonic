# Trio Task-Run Visibility for Collective Admins

> **Shipped** in PR #514.

Status: planning. Component 1 of
[trio-improvements-overview.md](../../../trio-improvements-overview.md).

## Problem

Persona task runs are inspectable by **no one**:

- `/ai-agents/:handle/runs` and `/runs/:run_id` require
  `current_user.human?` AND resolve the agent through
  `current_user.ai_agents` — parent-scoped
  ([ai_agents_controller.rb:290-296](../../../../../app/controllers/ai_agents_controller.rb#L290-L296),
  [`find_ai_agent_by_handle`:758](../../../../../app/controllers/ai_agents_controller.rb#L758-L763)).
  A persona's parent is the collective's **identity user**, so no human is
  ever the parent.
- Representing the collective doesn't help: the representation session's
  `current_user` is the identity user, which fails the `human?` gate — by
  design, and we keep it that way.
- The sys-admin view *should* work for personas — the redaction exemption
  (`redacted = !@task_run.ai_agent&.system?`) correctly shows the
  "full step details are visible" note for system agents — but the steps
  render as "No step data recorded" for sandbox-tenant runs.
  **Diagnosed 2026-07-18: cross-tenant association scoping.** The run
  loads via `AiAgentTaskRun.unscoped_for_admin`
  ([system_admin_controller.rb:165](../../../../../app/controllers/system_admin_controller.rb#L165)),
  but steps load through `@task_run.agent_session_steps` — and
  `AgentSessionStep` is tenant-scoped, so on the main-tenant-only admin
  dashboard the association silently filters sandbox rows to empty
  (`steps_count`, a denormalized column, still shows positive — the
  tell). Same shape likely affects `ai_agent_task_run_resources` and the
  `mcp_tool_call_log` links on that page. Fix: load these admin-scoped in
  the controller (`AgentSessionStep.unscoped_for_admin(...).where(ai_agent_task_run_id: ...)`)
  and pass to the view instead of traversing associations. Even fixed,
  sys-admin remains the wrong surface for accountability — the operator
  isn't the principal.

The accountability story we shipped says: *the collective is the
principal, and the collective is accountable for the personas' actions.*
Accountable-but-blind is not a real principal. The humans who answer for
the collective — its **admins** — must be able to see what its agents did,
what it cost, and why a run failed.

## Design

**Extend the existing `/ai-agents/:handle/runs` surfaces to authorize
collective admins of collective-principaled agents.** No new routes, no new
views — the run list, run detail (HTML + markdown + JSON), and cancel
action already render everything needed (steps timeline, cost, status,
error, created resources). This is an authorization change plus navigation.

### Authorization rule

For `runs`, `show_run`, `cancel_run` (and only these), the agent resolves
if either:

1. **Existing rule** — `current_user` is the agent's parent (unchanged), or
2. **New rule** — the agent is collective-principaled (its `parent` is a
   collective's `identity_user`) AND `current_user` is an **active admin
   member of that collective** in the current tenant.

Notes:

- The `human?` gate stays. Admins browse as themselves; representation
  sessions and agent callers remain 403. No change to the
  "collectives can't navigate `/ai-agents`" rule.
- Private workspaces come free: a workspace is a collective whose owner is
  its admin, so workspace persona runs become visible to the owner by the
  same rule.
- Rule 2 is not persona-specific — it keys off collective-principaled
  (`parent_id == collective.identity_user_id`), same predicate family as
  `User#collective_pool_agent?`. If a future non-Trio built-in is
  collective-principaled, its runs are admin-visible too. Deliberate.
- Resolve the collective from the agent (via `parent` → identity user →
  collective), not from a params collective — no confused-deputy route
  where an admin of collective A passes B's agent handle.
- Admin check must be **active membership + admin role** (the
  `CollectiveMember` predicates already exist); archived members and
  non-admin members get 404/403 exactly like strangers.

### What admins can and cannot do

| Action | Admin of the principal collective |
|---|---|
| List runs, view run detail (steps, cost, error, resources) | Yes |
| Cancel a queued/running run | Yes |
| `run_task` / `execute_task` (manual dispatch) | **No** — out of scope; personas act via automations, and manual dispatch has billing-consent implications (who pays?) that need their own design |
| Agent `show`/`settings`/`update_settings` | **No change** — persona identity is managed by Harmonic; behavior is customized via the collective's automation rules, which admins already control |
| MCP tool-call log | No change now (internal-runtime personas don't use it; revisit if that changes) |

### Scoping and privacy

- An admin sees only runs of their own collective's agents; the lookup is
  tenant-scoped like the existing one (join through `tenant_users` on the
  current tenant).
- Content exposure is acceptable by construction: a persona works inside
  one collective, so its run steps read/write content of that collective —
  which its admins can already see. The one wrinkle: a run step could
  quote content from a **members-only vs admin visibility** difference
  only if such a difference exists inside one collective — it doesn't
  today (admins see all collective content). State this assumption in the
  PR; if per-note audiences inside a collective ever tighten, revisit.
- Run pages show cost. Good — that's the pool-transparency posture, and
  admins can already see per-agent 30-day spend on the pool page.

### Fix task-run cost display (found 2026-07-18 — it's been dead since April)

`AiAgentTaskRun.estimated_cost_usd` has had **no writer since commit
`73d92de5` (2026-04-16)** — the old Sidekiq execution stack computed it,
and the agent-runner migration deleted that stack; the runner's completion
report writes token counts only
([internal/agent_runner_controller.rb:100-114](../../../../../app/controllers/internal/agent_runner_controller.rb#L100-L114)).
Every run since then has nil cost; the displays are conditional so the
line silently doesn't render, and the aggregates (`runs` page total,
`/ai-agents` index `@total_costs_by_ai_agent`, `total_cost_for_period`)
sum nils to zero.

The authoritative numbers already exist: every gateway call opens an
`LLMUsageRecord` stamped with `task_run_id`
([internal/llm_gateway_controller.rb:33](../../../../../app/controllers/internal/llm_gateway_controller.rb#L33))
and completes with rate-card-priced `estimated_cost_cents`. Fix, in this
PR (blank/zero cost on admin-visible run pages would defeat half the
purpose):

- Run detail + runs list read cost from the ledger (live join on
  `ai_agent_task_run_id`; sum completed rows, show pending count) — the
  ledger is source of truth, and record-usage can land after the run
  completes, so join beats denormalizing.
- Retire or reroute the dead `estimated_cost_usd` aggregates (index page,
  `total_cost_for_period`); don't leave silent zeros.
- LiteLLM-routed calls (non-billing tenants) produce no usage records:
  label cost honestly as "not tracked" there instead of blank. Gap closes
  with the main-tenant `stripe_billing` cutover.
- Decide the column's fate: drop `estimated_cost_usd`, or backfill from
  the ledger and keep it denormalized-but-maintained. Leaning drop —
  one source of truth.

### Lineage surfacing (pairs with overview Track B)

The task-run lineage work (`parent_task_run_id` + `chain_depth`, see the
overview doc) surfaces in exactly the views this plan touches: run detail
shows "triggered from [parent run] · depth N" with a walkable chain back
to the originating human action; the runs list and the sys-admin
agent-runner dashboard get a depth column. Build them together so the
views are designed once.

### Navigation (discoverability)

- **Persona profile page** (`/u/melody-<collective>`): "Task runs" link
  visible to authorized viewers (parent or collective admin).
- **Collective settings, AI section**: each active persona row links to
  its runs. This is where an admin lands when something misbehaves.
- Optional, cheap: the pool page's Funded Agents table rows link the agent
  name to runs for admins (it already shows spend; "why did this cost
  $5?" should be one click).

### Dual interface

`runs` and `show_run` already render markdown. The authorization change
covers both formats automatically; add the runs link to the persona
profile's markdown view and settings markdown so agent-readers (e.g. an
admin's own agent) can traverse it too.

### Sys-admin redaction fix

Verify and fix the prod observation that persona run steps render redacted
in the system-admin view despite `system?` being true. Repro first; likely
a nil `ai_agent` in that context. Small, rides along.

## Tests (red-green)

Authorization matrix on `runs` / `show_run` / `cancel_run` for a
collective-principaled agent:

- collective admin (active) → 200; can cancel
- plain member → 403/404
- admin whose membership is archived → 403/404
- admin of a *different* collective in same tenant → 404
- same handle, different tenant → 404
- representation session (identity user) → 403 (unchanged, pinned)
- the persona itself / any ai_agent caller → 403 (unchanged)
- workspace owner sees workspace persona runs
- human-principaled external agent: parent still sees runs; a collective
  admin where the agent merely *belongs to* the collective (member but not
  collective-principaled) → 404 — membership is not principalship
- markdown format parity on the same matrix (at least admin-200 and
  member-403)
- navigation: runs link renders on persona profile for admin, absent for
  plain member

Plus a regression test pinning sys-admin unredacted steps for system
agents once the redaction issue is diagnosed.

## Open questions

1. **Plain-member visibility.** Pool enrollees fund these runs; there's a
   transparency argument for member-readable run *lists* (status + cost,
   no step content). Not in scope — admins first, and the pool page
   already gives members per-agent spend. Revisit with the pool-consent
   notification question.
2. **Should admins see the runs of a *retired* legacy trio agent?** Its
   membership is archived, so rule 2's "collective-principaled" check
   still passes (parent link survives retirement). Cheap answer: yes,
   history stays visible — consistent with keeping attribution. Pin it in
   a test either way.

## Size

Small-medium. One PR: authorization + lookup change, navigation links,
sys-admin redaction fix, test matrix. No schema changes, no migration.
