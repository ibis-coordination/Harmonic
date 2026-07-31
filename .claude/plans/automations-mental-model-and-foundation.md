# Automations: Mental Model, Foundation Refactor, Expansion Runway

**Status: round 2, 2026-07-30 — round-1 claims verified against the code; live defects found during verification are named as acceptance criteria on the stages that fix them. The five-slot model survived verification unchanged. Direction agreed with Dan; two defects (secrets docs, manual-path enabled check) ship as targeted fixes ahead of the foundation stages.**

Companion to [programmable-collectives-and-governance-overview.md](programmable-collectives-and-governance-overview.md), which maps *where automations could go* (five primitives, four paths to programmability, ActionsHelper as the syscall table). This document sits beneath it: what an automation *is*, and what foundation work makes the expansion buildable. The goal end-state: anyone holding the `automator` role — human or agent — can author automations confidently from a model they can hold in their head.

## Why now

Three production bugs in one week, all traceable to conceptual debt rather than coding mistakes:

1. **Notification cross-delivery leak.** Per-recipient events (`notifications.delivered`) were dispatched through the collective-audience matcher, sending one member's notification payloads to other members' webhooks. Root cause: event *audience* was implicit — encoded as a fast-path optimization instead of a property of the event kind.
2. **Webhook deletion 500 / run-history cascade.** "What happens when a rule is deleted" had never been modeled; foreign keys were accidentally load-bearing. Fixed with soft delete — but the fix had to be patched into **three** independent dispatch sites (dispatcher, scheduler job, inbound webhook lookup), because "which rules are live" has no single home.
3. **Notification webhooks are shape-sniffed.** The per-user notification forwarder is stored as an `AutomationRule` and detected by `actions->>'webhook_url' IS NOT NULL` plus owner presence. Every surface that touches rules needs a carve-out (listings exclusion, uniqueness index predicate, tier-gate exemption, dispatch scoping, bridge-setup conflict checks). Each carve-out is a bug waiting for the next person who doesn't know it's there.

Separately: the docs promise `{{secrets.api_token}}` template support that **does not exist** in the codebase — a sign the docs describe an imagined system, not the real one. A mental model that authors can trust starts with docs that are true. Worse than a doc lie: the promise appears in the YAML-reference partial rendered on all four authoring screens, and an unresolved `{{secrets.token}}` renders as the empty string — a header silently becomes `Bearer `. (Shipping as a targeted fix ahead of F6.)

### Round-2 verification findings (2026-07-30)

Code sweep confirming/refining the round-1 claims. Live defects found:

1. **The manual path never checks `enabled`.** `execute_run` validates `manual_trigger?` and inputs, then creates the run; neither the execution job nor the executor re-checks `rule.enabled?`. A disabled-but-not-deleted manual rule is runnable. (Shipping as a targeted red-green fix ahead of F2; F2 still owns making it structural.)
2. **Chain depth and rate limits apply to the event path only.** `can_execute_rule?` and both rate limiters live in the dispatcher; the scheduler, inbound-webhook, and manual paths bypass all of them. The tier gate is triplicated across three of the paths. P5's "scattered" undersold it: limits are *absent* on three of four paths.
3. **Persona deactivation clobbers user-authored rules.** `PersonaActivator` deactivate runs `update_all(enabled: false)` on *all* the agent's rules, and reseeding is blocked by any user-edited rule with overlapping `event_types`. With no managed-by marker, system and user rules on the same agent are indistinguishable (F3).

Refinements: dispatch is **four** trigger paths, and only the event path uses the shared `enabled` scope — the scheduler re-spells the predicate inline; webhook and manual use only `not_deleted`. `NOTIFICATION_DELIVERED_EVENTS` has a second verbatim copy in `AutomationTemplateRenderer`. The forwarder shape-sniff inventory is 9 live sites plus the partial-index predicate plus the `PENDING_RULE_NAME` name-string (a *lifecycle state* encoded in a name). The `actions` column tolerates three shapes (bare String, Hash-with-task, array) and collective rules have no shape validation at all. Per-step run recording already exists but is inconsistently shaped between the multi-action loop (`{index, type, result}`) and the two single-action paths (no index/status, mixed key types) — F4 is a normalization, not greenfield.

---

## Part 1 — Principles and the mental model

### The one-sentence model

> **When _trigger_ fires and _conditions_ hold, run _steps_ as _identity_ within _limits_.**

Five slots. Every concept in the system should belong to exactly one slot, and an automator should be able to fill in the sentence for any rule they read. Today's system fills the sentence for simple cases but muddles three of the slots (steps, identity, limits) — see the principles below.

| Slot | Today | Debt |
|---|---|---|
| **Trigger** | event / schedule / webhook / manual | Sound. Event *audience* is implicit (P2) |
| **Conditions** | flat AND filters | Sound, if limited |
| **Steps** | `task` (agent rules) XOR `actions` (collective rules) | Two vocabularies for one concept (P4) |
| **Identity** | implicit from rule scope | Never named; conflated with ownership (P3) |
| **Limits** | rate limits, chain protection, tier gate, max_steps | Sprinkled through dispatch/execution code, with per-kind carve-outs (P5) |

### Principles

**P1. Events are addressed: every event kind declares its audience.**
Two audiences exist today: *collective-audience* (content events — a note was posted; everyone in the room may react) and *single-recipient* (delivery events — you were notified; only your rules may react). The audience is a property of the **event kind**, declared where the event is defined, not inferred inside dispatch code. New event kinds must declare an audience to exist — making the recent leak class unrepresentable. (Future audiences are conceivable — tenant-wide, cross-collective — and each would get its own dispatch semantics *explicitly*.)

Two boundary rules from round-2 verification: (a) **audience and gating are separate axes** — today's single-recipient branch also skips the tier gate, but that exemption belongs to the *rule kind* (forwarders are a delivery preference, P4), not the event's audience; if the registry declaration bundles both, F1's audience and F3's kind will fight over the same exemption. Audience answers *who may react*; kind answers *what gates apply*. (b) Delivery events currently store the recipient as `event.actor_id` — the "actor" of `notifications.delivered` is the person notified, which bends the cause-attribution vocabulary. F1 gives delivery events an explicit **recipient**, not an inherited actor.

**P2. Ownership, acting identity, and capability are three different things.**
- *Owner*: who configures the rule and answers for it (agent's principal, collective's admins/automators).
- *Acting identity*: who the run acts **as** — the agent, or the collective identity user. Attribution and authorization flow from this.
- *Capability*: what that identity is allowed to do — decided by ActionsHelper's per-action authorization, the same checkpoint every other surface uses.

Today the rule's *scope* silently determines all three plus the allowed step vocabulary (agent rules may only `task`, collective rules may only `actions`). Untangling this is what makes "automator authors a rule" safe to reason about: the rule can never do more than its acting identity could do by hand.

**P3. A step is a step.**
`task` and `actions` are the same concept at different determinism levels: a **deterministic step** (send webhook, create note) and an **agentic step** (hand a prompt to an agent). `trigger_agent` is not a third thing — it's an agentic step appearing inside an actions list. One vocabulary: an automation has an ordered list of steps; each step is deterministic or agentic. (This is also the GitHub Actions shape: jobs with different runners, one workflow grammar.)

**P4. What is not an automation stays out of the automation system.**
The per-user notification webhook is a *delivery preference* — "also forward my notifications here" — not a rule the user authors. It has no conditions worth writing, no steps worth choosing, singleton semantics, different billing, different UI. Modeling it as an `AutomationRule` bought reuse of the delivery machinery at the price of permanent carve-outs. It should be explicitly distinguished (at minimum a `kind` column; possibly its own table) so that "for every automation rule…" code stops being a trap.

**P5. Limits attach to the model, not to code paths.**
Rate limits, chain depth, tier gates, and soft-delete liveness are facts about *rules and runs*, but they're enforced by scattered conditionals across three dispatch sites. There should be one place that answers "is this rule live and allowed to fire right now," and every trigger path — event, schedule, inbound webhook, manual — consults it.

**P6. One syscall table.** (Imported from the governance overview; restated as a foundation principle.) Automations act through ActionsHelper like every other surface. Expanding automation power means widening what executors may call through the *existing* authorization checkpoint — never a parallel action system.

**P7. Docs describe the real system.**
The help page and AUTOMATIONS.md teach the five-slot sentence, in that vocabulary, and promise nothing unimplemented. (Current violation: `{{secrets.*}}`.)

### The glossary an automator learns

*automation* (a rule: the five-slot sentence) · *trigger* · *condition* · *step* (deterministic or agentic) · *run* (one execution, with per-step results) · *acting identity* (who the run acts as) · *owner* (who answers for the rule) · *limits* (rate, chain, billing). Seven terms; the help page teaches exactly these and nothing else.

---

## Part 2 — Foundation refactor (sequenced; each stage shippable alone)

Ordered so that each stage pays for itself even if the later ones never happen.

### F1. Event-kind registry with declared audience
A single registry (likely in/next to `EventService`) declaring every event kind and its audience. The dispatcher stops owning `NOTIFICATION_DELIVERED_EVENTS`; per-audience matching branches on the declaration. Emitting an unregistered event kind is an error in dev/test.
*Acceptance:* both copies of `NOTIFICATION_DELIVERED_EVENTS` (dispatcher + `AutomationTemplateRenderer`) are gone; all `EventService.record!` call sites (~12) emit registered kinds; delivery events carry an explicit recipient (P1b).
*Pays for:* makes the leak class structural rather than vigilance-based; gives new event kinds a forcing function.

### F2. Dispatch consolidation — one checkpoint, not just one query
Per P5's full sentence: one place answers "is this rule live *and allowed to fire right now*," and all four trigger paths — event, schedule, inbound webhook, manual — consult it. That's the liveness query (enabled, not deleted, correct trigger type) **and** the limits (chain depth, rate limits, tier gate), which today run only on the event path. Per-audience matchers as separate, individually testable units (the strategy split discussed after the leak fix). The scheduler job and inbound-webhook lookup route through the same core instead of hand-rolling. F2 also owns **cascade-awareness** (chain identity propagated through agentic steps' side effects — the trio-incident gap), or it becomes another scattered guard.
*Acceptance:* the manual-path `enabled` gap can't recur (the targeted fix's tests move onto the checkpoint); scheduler/webhook/manual paths hit the same chain/rate/tier checks as events; the tier gate has one home instead of three.
*Pays for:* the next liveness- or limits-semantics change is a one-site change. Four-site patching (soft delete) never recurs.

### F3. Explicit rule kinds — two dimensions
`kind` column on `automation_rules`: `automation` vs `notification_forwarder` (name TBD), **plus a managed-by dimension** (`user | system`) — round-2 verification showed persona rules have no marker at all: deactivation `update_all`s every rule on the agent (clobbering user-authored ones) and reseeding is blocked by user edits. All shape-sniffing (`actions->>'webhook_url'` — 9 live sites, `excluding_notification_webhooks`, the partial-index predicate, the bridge-setup `PENDING_RULE_NAME` convention) replaced by the columns; `PENDING_RULE_NAME` is really a *lifecycle state* stored in a name and gets an honest representation, not just a kind. Uniqueness index keys on kind. Decide *after this lands* whether forwarders migrate to their own table — the column makes that a data migration, not a semantics hunt.
*Acceptance:* zero raw `actions->>'webhook_url'` predicates outside the migration; persona deactivate/reseed touches only system-managed rules.
*Pays for:* every carve-out becomes explicit; new rule surfaces can't accidentally include forwarders; persona lifecycle stops colliding with user rules.

### F4. Steps unification (internal representation first)
Internal execution model becomes `steps[]`; `task` compiles to a single agentic step; `trigger_agent` actions become agentic steps; existing `actions` become deterministic steps. **YAML stays backward-compatible** — the current schema still parses (schema is versioned from here on; store `schema_version` on the rule — the `actions` column already holds three shapes in the wild: bare String, Hash-with-task, array). The executor runs one step pipeline with uniform per-step run recording — a *normalization* of what exists: the multi-action loop already records `{index, type, result}` per action while the two single-action paths record differently-keyed entries with no index/status.
*Pays for:* one execution/observability pipeline; the prerequisite for step outputs, branching, `wait_for`, and everything in the overview's control-flow row.

### F5. Acting identity made explicit
The rule records who it executes as; execution authorizes each step through ActionsHelper as that identity. Mostly formalizes current behavior (collective identity for internal actions, the agent for tasks) but names it, displays it in the UI ("runs as @collective-handle"), and closes the gap where step vocabulary was doing authorization's job.
*Pays for:* the automator story ("your rule can't exceed its identity's powers") and the hook that the action-approval track ([decision-semantics-and-action-approval.md](decision-semantics-and-action-approval.md)) attaches gates to.

### F6. Docs + authoring surface rewrite
Help page and AUTOMATIONS.md rewritten around the five-slot sentence and seven-term glossary; validation errors speak the same vocabulary; the automator-facing creation flow (templates, test, run history) audited against the model. (`{{secrets.*}}` removal shipped ahead as a targeted fix — see round-2 findings.) The seven glossary terms land as rows in `docs/CONTROLLED_VOCABULARY.md` with this stage, when the copy makes them true.
*Pays for:* the actual goal — automators who can author without reading source.

**Deliberately not in the foundation:** new verbs, state store, query steps, `wait_for`, scripting — all expansion (Part 3), all blocked-on or eased-by F4.

---

## Part 3 — Forward-facing design questions

The governance overview owns the strategic map (four paths; do the declarative widening regardless; evaluate scripting only after the DSL demonstrably plateaus). Questions below are the ones the foundation work forces us to answer eventually — record positions early, decide late.

**Q1. Secrets.** Payloads need credentials; today people would paste them into YAML (visible to every automator). A per-collective secret store (`{{secrets.name}}`, write-only UI, masked in run logs, usable only by that collective's rules) seems unavoidable *before* serious webhook/RPC use. Who may read/write secrets — admins only, or automators too?

**Q2. Step dataflow and durable runs.** Step outputs as variables (`{{steps.notify.status}}`), per-step conditions, `wait_for` (pause until a decision resolves). All require runs to become durable, resumable state machines rather than one-shot jobs. This is the single biggest architectural commitment on the expansion path — worth a dedicated design round when F4 is done.

**Q3. Where does arbitrary code run?** Three candidate runners, likely all eventually, in this order of appetite:
   1. *External RPC step* (call an operator's endpoint, use the response in later steps) — no new trust surface; webhooks-as-RPC. Cheapest.
   2. *Operator compute as runner* — sprites are shaped exactly like GitHub's self-hosted runners: operator-owned, billed to the operator, isolated per agent. The bridge already gives them a wake protocol.
   3. *Platform sandbox* (WASM/QuickJS with a capability-scoped API through ActionsHelper) — the Figma-plugin model; a permanent security liability to own; last resort after the DSL plateaus, per the overview.

**Q4. Approval and provenance for rule changes.** When an automator (especially an agent) creates or edits a rule: does it activate immediately, or does some rule class require admin approval / a decision? Rules-about-rules is where governance and automations meet — this belongs to the action-approval track, but F5's acting-identity work should leave the hook. Related: rule definitions should be versioned (which definition did run #N execute?) — cheap to add during F4, painful later.

**Q5. What happens to user-owned general automations?** The path helpers imagine `/u/:handle/settings/automations`, but no controller exists; the only user-owned rules in practice are notification forwarders. Either commit to user-scoped automations as a product surface (with their own acting-identity semantics) or prune the affordance in F3.

**Q6. Composability and reuse.** Templates exist; recipes (parameterized automation bundles) are the governance overview's remix surface. Open: whether steps themselves become shareable named units (GH marketplace shape) or reuse stays at whole-rule/template granularity. No position yet; F4's step model should at least not preclude it.

**Q7. Observability at step granularity.** Per-step logs, rendered-payload capture, replay-with-same-context for debugging. Partially exists at run level; step-level lands naturally in F4 if designed in rather than bolted on.

---

## Compatibility map: how this plan relates to the other active plans

Scanned 2026-07-24 against every doc in `.claude/plans/`. Grouped by relationship.

### Bedrock beneath this plan

- **[simplified-technical-english-controlled-vocabulary.md](completed/2026/07/simplified-technical-english-controlled-vocabulary.md)** — **shipped 1.64.0**: `docs/CONTROLLED_VOCABULARY.md` and its lint exist. This plan's seven-term glossary lands as rows there with F6, when the copy makes the terms true; the identity-glossary convergence below is already settled.

### Prerequisites — satisfied

- **[enforce-action-authorization-at-execute-time.md](completed/2026/07/enforce-action-authorization-at-execute-time.md)** — **shipped 2026-07-06** (`ActionAuthorizationCheck`, 79af4ecb): the `authorization:` field on ACTION_DEFINITIONS is now enforced at execute time on every `/actions` POST, not just in listings. P6 ("one syscall table") and F5 ("authorize each step through ActionsHelper") stand on real enforcement; F5 has no outstanding prerequisite besides the identity-glossary convergence.

### Same concept, different vocabulary (must converge before implementation)

Four plans independently name pieces of the identity triangle. One glossary must win:

| This plan | [decision-semantics-and-action-approval](decision-semantics-and-action-approval.md) | [task-initiator-resolution](parked/task-initiator-resolution.md) | [agent-security-trust-verification](agent-security-trust-verification.md) |
|---|---|---|---|
| *acting identity* (who the run acts as) | `execute_as` (principal \| collective identity) | — | — |
| *owner* (who answers for the rule) | `proposed_by` includes `automation` | `responsible_party` (= `rule.created_by`) | "automation inherits trust level of the rule's **creator**" |
| *cause* (what fired it) | — | `initiated_by` (event actor) | provenance chain to originating event |

Convergence **settled** in **[identity-glossary.md](identity-glossary.md)** (marked settled 2026-07-29, commit c77e5506): **cause** (what fired it; cause actor when a user is attached) · **owner** (who answers for the config — resolvable role, never `created_by`) · **acting identity** (who steps execute as). Billing is explicitly out of scope — the automation system names no payer; automation-triggered runs bill exactly like manual ones, in the billing domain, from the agent's funding arrangement. The overlapping plans are annotated with their term mappings; task-initiator's `responsible_party` is superseded outright (pools + the gateway now serve its billing motivation), with its `initiated_by`-fallback impurity flagged as a standalone cause-attribution cleanup.

### Strong synergy (this foundation is their substrate)

- **[decision-semantics-and-action-approval.md](decision-semantics-and-action-approval.md)** — `ProposedAction` (frozen params, `execute_as`, routed through ActionsHelper) is exactly the shape a future "propose" step needs; its three-valued grants (`allowed | with_approval | denied`) are the mechanism Q4 wants for gating automator rule-changes. Its `DecisionResolution` payload work should register through the F1 event-kind registry. Its moderation carve-out invariant (moderation actions never gated behind `with_approval`) constrains Q4.
- **[programmable-collectives-and-governance-overview.md](programmable-collectives-and-governance-overview.md)** — the strategy map above this doc. One sequencing tension resolved here: the overview says "widen the declarative DSL regardless"; this plan gates expansion on F4. Resolution: F1–F3 block nothing; *new DSL constructs land on the step model* (F4), not on the `task`/`actions` split — widening before F4 recreates the tangle this plan exists to fix.
- **[trio-improvements-overview.md](trio-improvements-overview.md)** — the 2026-07-18 persona cascade incident is more P5 evidence: chain protection is blind to agent-generated events (an agent's content starts a *fresh* chain, so mutual-trigger loops never hit the depth limit), and mention filters ignore the triggering author. Both gaps this bullet flagged in round 1 are now absorbed: F2 owns cascade-awareness, and F3 carries the `managed_by` dimension (upgraded from "likely needs" to "needs" by the round-2 finding that persona deactivation clobbers user-authored rules).
- **[agent-funding-models-exploration.md](agent-funding-models-exploration.md)** + task-initiator — who pays for automation-triggered agent runs is answered in the billing domain (the agent's funding arrangement), not by the automation system ([identity-glossary.md](identity-glossary.md)'s boundary rule); per-rule spending caps (listed as future mitigations in both task-initiator and the trio incident notes) belong in the *limits* slot of the five-slot model.

### Downstream consumers (validate the foundation, add requirements)

- **[admin-agents-and-multi-instance-exploration.md](admin-agents-and-multi-instance-exploration.md)** — builds its Phase 0 entirely on scheduled automations + inbound webhooks, and its Phase 2 on decision-authorized execution. New requirement it surfaces: **trigger dedup/coalescing** ("an error storm should append evidence to one open incident, not spawn task-per-event") — a trigger-slot feature no current plan owns; parked here as a Part 3 addendum.
- **[agent-runner-external-tools-exploration.md](agent-runner-external-tools-exploration.md)** — its "tools as automations" option (a `run_automation` tool for agents) and its Rails-vs-runner execution-locus tension directly inform Q3's runner question; cite it when Q3 gets a design round.
- **[resource-limits-hardening.md](resource-limits-hardening.md)** — its retention jobs for `automation_rule_runs` / `webhook_deliveries` are the sanctioned consumer of the soft-delete work's `allow_hard_destroy` escape hatch. Compatible; no changes needed either side.
- **[moderation-controls-exploration.md](moderation-controls-exploration.md)** — automator and moderator capabilities ship as siblings; whatever rule-approval gates Q4 produces must honor the moderation exemption noted above.
- **[action-context-overview.md](completed/2026/06/action-context-overview.md)** (Stage 3 renames `AiAgentTaskRun` → `AgentSession`) — F4/F5 touch the executor's run-creation sites; whichever lands second rebases mechanically. Awareness, not conflict.

## Suggested sequencing

F1+F2 are small and directly bug-preventing — near-term, possibly one PR each (F2 should absorb the cascade-awareness gap from the trio incident, per the compatibility map). F3 needs a data migration and a carve-out hunt — medium — and must decide the system-managed-rules dimension. F4 is the big one; do it before any expansion feature, after the model (Part 1) survives critique. F5 rides alongside F4; its execute-time-authorization prerequisite is already shipped ([enforce-action-authorization-at-execute-time](completed/2026/07/enforce-action-authorization-at-execute-time.md)). F6 lands last, describing what's then true. Part 3 questions get positions recorded as they become blocking, not before — and the identity glossary convergence (compatibility map) should be settled with the owners of the three overlapping plans before F5 starts.
