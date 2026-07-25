# Programmable Collectives & Declarative Governance — Overview

Status: direction doc / exploration. Captures the full arc from today's automation
system to enforceable, shareable collective governance. Component plan with
concrete near-term work:
[decision-semantics-and-action-approval.md](decision-semantics-and-action-approval.md).
Related: GitHub issue #378 (approval process for agent/trustee actions).

## Vision

Collectives become fully programmable: members can define both **processes**
(workflows that run — proposal pipelines, role rotations, recurring rituals) and
**policies** (gates that enforce — "this action requires that authority"). A
collective's governance is a legible, versionable document that the platform
*executes*, not a norms page members are asked to remember. Governance documents
are shareable and remixable as recipes: fork a "consent-based collective"
starter, change `quorum: 5` to `quorum: 3`, adopt it by amendment.

No mainstream platform occupies this spot: chat platforms have permissions but
no processes; DAOs have enforcement but only for token votes, with brutal UX;
deliberation tools (Loomio et al.) have processes but outcomes are advisory.
Enforced, legible, forkable governance over a general coordination substrate —
with humans as the oracle and agents as participants — is a real gap.

## What programmability decomposes into

A program needs five primitives. Where the automation system stands on each
(see [docs/AUTOMATIONS.md](../../docs/AUTOMATIONS.md)):

| Primitive | Today | Gap |
|---|---|---|
| **Verbs** (things it can do) | 3 internal actions (create_note / create_decision / create_commitment), webhooks, trigger_agent | ActionsHelper defines ~100 authorization-aware actions; expose most of them |
| **Reads** (things it can see) | Only the triggering event's context | Query step: read notes/decisions/commitments matching a filter |
| **State** (memory between runs) | None | Small per-rule / per-collective key-value store (counters, cursors) |
| **Control flow** | Flat AND conditions; multi-action lists | Step outputs as variables (`{{steps.x.id}}`), per-step conditions, branching, composition (automation-as-subroutine with budgets, not just chain *limits*) |
| **Time** (waiting) | Cron triggers only | `wait_for` — pause a run until a decision resolves, a commitment hits critical mass, or a duration elapses; requires durable resumable runs |

## The load-bearing architectural fact

[ActionsHelper](../../app/services/actions_helper.rb) is the single source of
truth for all actions, with per-action authorization lambdas, and every surface
routes through it — HTML UI, markdown API, MCP, agents, automations. Internal
automation actions already execute as the collective identity user through it.

Consequences:

1. **Programmability = giving executors broader access to the existing syscall
   table** under the same identity/authorization model — not building a second
   action system. One audit trail, one permission model, one billing gate.
2. **Enforcement is uniform and has no side doors.** A policy layer evaluated
   at the ActionsHelper checkpoint binds the UI, the API, agents, and external
   bridge connections identically. This is what separates "we wrote our norms
   in a doc" from "our norms execute," and most platforms can't offer it
   because their action surface is scattered across controllers.

## Four paths to programmability (they compose, not compete)

1. **Widen the declarative DSL** (Zapier → GitHub Actions maturity): more
   verbs, step outputs, branching, query step, state store. Cheap, incremental,
   auditable. Plateaus eventually (the Greenspun trap: each added construct
   makes YAML more like a bad programming language). Worth doing regardless.
2. **Sandboxed scripting runtime** (Figma-plugins model): Lua/QuickJS/WASM
   scripts with a capability-scoped API object routing through ActionsHelper as
   the collective identity; instruction/memory/time caps. The true "fully
   programmable" leap, but a permanent sandbox-security liability and a second
   environment to support. Evaluate only after real usage shows where the
   declarative layer actually plateaus.
3. **Agents as the programmability layer**: already mostly built
   (trigger_agent + MCP). Right for judgment, wrong for invariants
   (nondeterministic, ~1000× cost per run). The near-term win is
   **meta-automation**: `create_automation_rule` is already an action, so an
   agent can author and maintain a collective's automations conversationally —
   "programming by talking to the collective's persona."
4. **External code, first-class**: webhook-out + webhook-trigger +
   harmonic-bridge already give off-platform programmability. The ergonomic
   gap is a request/response action step (call an external function, use its
   return value in later steps) — webhooks as RPC, not just fire-and-forget.

## The governance layer

Governance = **processes** + **policies**, both declared in a per-collective
governance document (YAML), both executing on the automation substrate.

### Policies: declarative action gates

A policy attaches preconditions to actions, evaluated at the ActionsHelper
checkpoint:

```yaml
policies:
  - action: remove_member
    requires:
      decision: { threshold: majority, quorum: "{{parameters.quorum}}" }
  - action: update_collective_settings
    requires: { role: facilitator }
  - action: amend_governance          # the constitutional clause
    requires:
      decision: { threshold: "{{parameters.supermajority}}", deadline: 14d }
```

**The held-intent execution model**: attempting a gated action does not fail
with a 403 — it is captured as a **ProposedAction** (parameters frozen), the
required decision opens automatically referencing it, and on acceptance the
platform executes it *as proposed*. What you vote on is literally what runs.
Smart-contract semantics with humans as the oracle.

**Self-amendment**: `amend_governance` is itself a governed action — the
document controls its own modification. Adopting a new upstream recipe version
is an amendment proposal whose diff members can read.

### Processes: workflows with waiting

Named workflows built on triggers + steps + `wait_for`:

```yaml
processes:
  proposal:
    trigger: { event_type: note.created, conditions: [tag: proposal] }
    steps:
      - id: consent_round
        action: create_decision
        params: { question: "Adopt: {{subject.title}}?", deadline: "{{parameters.review_period}}" }
      - id: outcome
        wait_for: { decision: "{{steps.consent_round.id}}" }
      - if: "{{steps.outcome.accepted}}"
        action: create_commitment
        params: { title: "Implement: {{subject.title}}", critical_mass: 2 }
```

`wait_for` turns automations from reflexes into *processes* — a bylaw executing
itself. Requires durable runs (AutomationRuleRun gains a `waiting` state and
resume keyed off the awaited event).

### Recipes: parameters are the remix surface

Most forks change numbers, not structure — separating `parameters:` from
clauses makes recipes shareable and their diffs legible (legible diffs are what
make amendments reviewable). Recipe infrastructure = the existing automation
template gallery + parameterization + provenance ("forked from
@commons/consent-basic v1.2, locally amended twice") + a public commons to
share through.

### Domain primitives already in place

Decisions are branching, commitments are human-quorum gates, cycles are time
structure, the collective identity user is the executor, `has_roles` is the
role substrate, the decision audit chain is the outcome ledger. Governance
composes existing domain objects; it does not invent parallel ones.

## Hard problems (named, not solved)

- **Entrenchment / bricking**: a collective can amend itself into a corner
  (unpassable thresholds, quorum > member count). Mitigations: static
  validation at adoption ("this quorum exceeds membership"), possibly a
  platform-guaranteed minimal amendment path that can't be legislated away.
- **Loopholes are bugs**: gate `remove_member` but not `update_member_roles`
  and an admin demotes instead. "Code is law" means governance YAML has
  exploits. Battle-tested recipes accumulate loophole closures like
  well-reviewed libraries accumulate fixes; a coverage linter ("these related
  actions are ungated") catches the obvious ones.
- **Emergencies**: abuse can't wait out a 7-day consent round. Recipes need an
  emergency-powers pattern (act now, mandatory after-the-fact ratification);
  platform moderation sits *above* collective governance, not inside it.
- **The sovereignty boundary**: tenant admins and the platform exist above any
  collective's constitution, like a hosting provider above a DAO. Don't
  pretend otherwise; make overrides *loud* — break-glass suspension emits a
  public, permanent audit event in the collective.
- **Legibility**: a collective whose behavior members can't inspect is a
  governance problem. Rules stay readable in place; runs and resource
  attribution (already built) link every enforcement back to the clause.

## The arc, sequenced

Each stage independently valuable; later stages consume earlier ones.

1. **Decision semantics + action approval** — persisted resolutions;
   eligibility/quorum/threshold; ProposedAction; three-valued capability
   grants (`allowed | with_approval | denied`). Ships issue #378's
   principal-approval loop and quietly forces the governance foundations to
   exist. → [decision-semantics-and-action-approval.md](decision-semantics-and-action-approval.md)
2. **Durable runs + `wait_for`** decisions/commitments — processes.
3. **Automation DSL widening** — verb coverage from ActionsHelper, step
   outputs, query step, state store. Can proceed in parallel with 1–2.
4. **Policy layer** — governance document, ActionsHelper-checkpoint
   evaluation, held intents for gated actions, declarative roles + rotation.
   By this point governance is mostly configuration over 1–3.
5. **Recipes** — parameterization, provenance, amendment flow, public commons.
6. **Agent-authored automations** as the authoring UX (guardrails around
   agents editing rules); **sandboxed scripting** evaluated last, only if the
   declarative layer demonstrably plateaus.

A minimal credible v1 of governance (after stage 1): held intents +
decision-gating for a fixed small set of actions (member removal, settings,
pool enrollment) — no processes, roles, or recipes yet. That alone lets a
collective truthfully say "membership changes here require collective consent,
and the software holds us to it."

## Cross-cutting constraints

- **Identity & capability scoping**: per-rule capability grants ("this rule
  may vote and comment, nothing else") once verbs multiply; maps onto existing
  authorization lambdas.
- **Metering**: deterministic runs cheap/free; agent steps meter via the LLM
  gateway; chain protection evolves from bans to budgets when composition
  becomes a feature.
- **Backward compatibility**: bindingness is opt-in everywhere. Existing
  decisions remain advisory; existing automations run unchanged.

## Related existing tracks

- Issue #378 — approval process for agent/trustee actions (stage 1 ships it).
- [capability-roles-automator-moderator.md](completed/2026/07/capability-roles-automator-moderator.md)
  — `automator` role gates who edits automations; governance policies will
  eventually gate the same surface.
- Pool funding trust model — per-principal caps and PayerResolver enforcement
  are the same "containment at the checkpoint" pattern.
- Personas — likely default facilitators/executors for governance processes,
  never exclusive holders.
