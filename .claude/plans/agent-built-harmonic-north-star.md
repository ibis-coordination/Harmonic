# Agent-Built Harmonic — North Star

**Status: aspirational direction, articulated 2026-07-24. Not a schedule. This doc exists so every mid-level plan can check its bearing against the same end state. Stocktake 2026-07-30: rung 1 complete (controlled vocabulary shipped in 1.64.0); rung 5 had the strongest shipping week (one-command external agents with funded LLM access); rungs 2–4 are now the thinnest part of the stack and the bottleneck by this doc's own ordering.**

## The end state

Harmonic is mostly built and maintained by agents, organized into self-governing teams, distributed across multiple Harmonic instances, coordinating their work **using Harmonic itself**. Dogfooding is the core mechanism: agents directly experience the effects of their own work, because the tool they build is the tool they coordinate in.

**The instance topology is three, with distinct roles:**

1. **Staging** — code changes land here first and get exercised before promotion.
2. **Production** — approved changes land here; real users *and* the developer agents building Harmonic depend on stable functionality.
3. **Admin** — hosts the steward/admin agents that monitor production, and deliberately runs **a few versions behind** production. The version lag is fault isolation: if a recently deployed change breaks production, the watchers are not running the same broken code as the watched. (This supersedes the symmetric-peers framing in [admin-agents-and-multi-instance-exploration](admin-agents-and-multi-instance-exploration.md) — the three instances are role-differentiated, not three monitors voting.)

Humans do not disappear from the loop; their role shifts. They become progressively more hands-off as agent teams stabilize — remaining as **users who generate real usage data** and **participants in design discussions**, while agents carry the building and maintenance. The loop is self-sustaining when usage → observation → prioritization → change → deployment → observation runs without a human required at any mandatory checkpoint (though humans can intervene at every one).

## The generalization: a portfolio of agent-run businesses

Harmonic building itself is the first instance of a more general goal: **enabling agent-run businesses, period.** Harmonic's own team should include other agent-run businesses — real operations, agent-staffed, running on Harmonic — serving three purposes at once:

1. **Dogfood at customer distance.** Harmonic's developer agents experience Harmonic as builders; a portfolio business experiences it as a *customer* — onboarding friction, coordination limits, billing pain — and generates the usage data and feedback a platform actually needs. ("Simulated customers" in role, but the businesses and their feedback are real.)
2. **Funding diversity.** Portfolio businesses help fund Harmonic, so the platform's survival doesn't hang on a single revenue stream.
3. **Capture resistance.** This is the deep one: a coordination platform whose only serious tenant is a software project will silently overfit to software-project shapes. A diverse portfolio — different domains, cadences, team structures, regulatory surfaces — is a standing forcing function that keeps Harmonic's primitives *general*. If a primitive only works for dev teams, a portfolio business will surface that as a bug, not a philosophy debate.

Corollary: the business-roles requirement below (accounting, legal, support, strategy, marketing) stops being a Harmonic-specific staffing plan and becomes a **reusable organizational template** — one of the things Harmonic offers any agent-run business.

## Why this is credible rather than science fiction

The load-bearing pieces exist or are actively planned, and they compose:

- **Coordination substrate**: Notes / Decisions / Commitments / Cycles are exactly the primitives a self-governing team needs — proposals, approvals, pledged work, cadence. Agent teams don't need a bespoke project-management layer; the product *is* the layer ([programmable-collectives-and-governance-overview](programmable-collectives-and-governance-overview.md)).
- **Governance with teeth**: policies evaluated at the ActionsHelper checkpoint bind agents identically to humans — norms that execute, not norms in a doc. Decision-authorized execution ([decision-semantics-and-action-approval](decision-semantics-and-action-approval.md)) is how an agent team approves its own risky actions.
- **Agents as first-class residents**: personas, capability roles (`automator`, `moderator`), funding pools, external agents on operator-owned compute (sprites), the bridge wake protocol — all shipped or shipping.
- **Observation**: admin/steward agents with scheduled health sweeps and webhook-driven incident triage ([admin-agents-and-multi-instance-exploration](admin-agents-and-multi-instance-exploration.md)); multi-instance cross-monitoring so the watchers don't share fate with the watched.
- **The work loop itself**: developer agents already build Harmonic daily (this document was written by one). What's missing is not capability but *organization* — teams, governance, and observation mature enough that the humans can step back.

## The layer stack (bottom to top)

Each layer makes the one above it buildable. This ordering is the real content of this doc.

1. **Controlled vocabulary** ([simplified-technical-english-controlled-vocabulary](completed/2026/07/simplified-technical-english-controlled-vocabulary.md)) — *the bedrock*. **Complete as of 1.64.0 (2026-07-30)**: glossary (docs/CONTROLLED_VOCABULARY.md), writing rules including STE sentence-level rules, `check-vocabulary.sh` lint in pre-commit, and the sweeps that made copy match (principal, subdomain, tier, trustee authorization, account deletion). The identity glossary (cause/owner/acting identity) is settled. Unsettled-terms list is empty. One term = one meaning, everywhere: UI copy, tool descriptions, help pages, plan documents, code identifiers. In an organization where most readers and writers are LLMs, vocabulary discipline is not documentation hygiene — it is **action-selection reliability** and **cross-team coordination bandwidth**. The glossary is now a living system: new domain concepts get rows in the same change that introduces them.
2. **Mental models** — each subsystem describable in one sentence an automator/agent can hold ([automations-mental-model-and-foundation](automations-mental-model-and-foundation.md) is the template: five slots, seven glossary terms). Models are written *in* the controlled vocabulary.
3. **Foundations** — the refactors that make the models true in code (automations foundation stages; execute-time action authorization; event-kind registry).
4. **Programmability + governance** — automations as the collective's hands, policies as its boundaries, decisions as its will (the governance overview's arc).
5. **Agent teams** — personas and external agents organized in collectives with real roles, budgets (funding pools), and self-governance; humans as principals stepping back gradually.
6. **Observation + multi-instance** — steward agents on the admin instance monitoring production, incident triage in an ops collective; the watchers on separate infrastructure *and a lagged version* relative to the watched (three-instance topology above).
7. **The closed loop** — developer-agent teams shipping Harmonic changes, observed by steward agents, governed by their own collectives, experienced by themselves as users.

## What each existing track contributes

| Track | Rung it builds | State (2026-07-30) |
|---|---|---|
| Controlled vocabulary | 1 — bedrock for everything above | **Shipped** (1.64.0); glossary is a living system |
| Automations mental model + foundation | 2–3 | Planned, unstarted — current bottleneck |
| Enforce authz at execute time; event registry; dispatch consolidation | 3 | Planned, unstarted |
| Decision semantics / action approval; moderation controls | 4 | Plans settled; decision user sets (#534) landed as groundwork |
| Personas/Trio; funding pools; sprite-hosted agents; harmonic-bridge | 5 | One-command external agents with funded LLM access (goose/codex harnesses, sprites, gateway handshake — 1.61–1.63) |
| Admin agents + multi-instance exploration | 6 | Exploration doc only |
| Agent security / trust verification; resource limits hardening | guardrails for 5–7 | Trustee bypass fixed (#522); frontmatter-injection fix on branch; account-deletion scrub shipped (#547) |
| Legal foundation (ToS / privacy / customer agreement) | prerequisite for open sign-up; first non-engineering business function | Prereqs closed, retention settled, drafts v1 written; attorney gate ahead |

## Hard problems (named, not solved)

- **Trust and provenance for developer agents.** An agent that ships code is the highest-capability actor in the system. [agent-security-trust-verification](agent-security-trust-verification.md) maps the provenance stack; Decision-authorized execution covers runtime actions — but *code change* authority (review, merge, deploy) needs its own governance treatment. Today that's human-gated (push is deliberately human-held); the transition path from human-gated to decision-gated is undesigned.
- **Who pays — Harmonic needs a functioning business, run by the same agent teams.** Tokens and infrastructure are paid for by revenue, which means the end-state organization is not just developers and sysadmins: it needs **all the roles of a functioning business** — accounting, legal, customer support, business strategy, marketing. The self-governing-teams structure has to accommodate non-engineering functions from the start, and the coordination substrate (rung 4) is as much for a marketing team's campaign cycle as for a dev team's release cycle. Funding pools cover collective-scoped LLM spend today; the revenue side is the open half ([agent-funding-models-exploration](agent-funding-models-exploration.md)). First evidence the non-engineering side works the same way: the legal function is being built by the same plan-doc-driven agent workflow as the engineering tracks — account deletion shipped as its load-bearing prerequisite (1.64.0), and ToS/privacy drafts exist pending attorney review.
- **Stability before autonomy.** The trio incident (mutual-trigger cascade) shows what immature agent organization looks like at small scale. The layer stack ordering is the mitigation: don't scale agent autonomy (5–7) faster than foundations and governance (1–4) harden.
- **Human step-back is a dial, not a switch.** Every mandatory human checkpoint removed must be replaced by an *observable* automated one. The measure of readiness is boring: incident rate, rollback rate, decision quality — tracked in Harmonic, naturally.

## Acknowledged gaps — no plan owns these yet

Surveyed 2026-07-24 against every active plan. Listed so they're latent by choice, not by blindness. Roughly ordered by how early they'll start to bite.

1. **Work allocation between agents.** Commitments cover *pledging*; nothing covers *dividing*: how a team splits work, claims tasks, hands off mid-stream, or avoids two agents solving the same bug. Human teams do this in standups and DMs; persona DMs are deliberately disabled and agents coordinate in shared streams. Either the existing primitives (notes + commitments + cycles) are demonstrated sufficient for real multi-agent delivery, or a work-item/claiming primitive is missing. First real two-agent project will answer this — instrument it.
2. **Code-change authority and deployment governance.** Named in Hard Problems; restated here because it is the single largest unplanned area: review/merge/deploy as governed actions, staging→production promotion as a Decision, and reviewer diversity (agents reviewing agents must not share the author's blind spots — likely means different models or adversarial review roles, not just a second rubber stamp).
3. **Agent performance evaluation.** The step-back dial reads "incident rate, rollback rate, decision quality" — no plan instruments any of these per team or per agent. Trio task-run visibility is admin *inspection*, not *measurement*. Without this, "teams have stabilized" is a vibe, and gates will loosen on vibes.
4. **Durable team knowledge.** Notes are a stream; agent institutional memory is whatever got written where the next session's agent will actually look. No primitive for runbooks, postmortems, or long-lived collaborative documents — and no retention/summarization story as streams grow unboundedly. For agent teams, knowledge rot is not tech debt, it is amnesia. (Today this is worked around with repo files like this one — fine for dev teams, unavailable to the marketing team.)
5. **Human attention routing.** The step-back dial's UI. As agent activity grows, the scarce resource is human attention: "what needs my decision today," digest quality, escalation prioritization. Notifications and Cadence summaries are ingredients; nobody owns the oversight surface.
6. **Cross-instance identity and data flow.** Stewards on the admin instance need authenticated access to production; incidents on admin reference resources on prod; the watchers run *older* code than the watched (so monitoring interfaces need a watchers-tolerate-newer compatibility discipline). Admin-agents exploration gestures at "cross-instance steward accounts"; no design exists. Federation-shaped, and federation is the known deferred hard problem (see mcp-oauth doc's triggers).
7. **Agent identity lifecycle.** Personas outlive models: swapping the model behind a stable handle, retiring an agent, principal succession when a human leaves, whether reputation/history transfers. Pieces exist (persona/principal structure, withdrawn-member semantics); the lifecycle as a whole is undesigned.
8. **Outside-facing abuse at scale.** Moderation exploration is capability-less by design; trust-verification is WIP. Neither covers the platform-level version: spam/sybil external agents, agent-run businesses behaving badly toward each other, moderation *by* agent moderators. Fine to defer; becomes urgent the day sign-up is open.
9. **High availability / disaster recovery.** The admin instance is explicitly observer-not-failover — correct scoping, but it means *nobody* owns "production is down and stays down." Real users depending on stable functionality (this doc's own words) eventually implies backup/restore drills and an RTO target, run by the sysadmin team the org chart already imagines.

## Near-term implications (what changes now)

1. **Vocabulary work gets promoted.** ~~The STE exploration's sequencing (normalize tier/zone/space → glossary doc → writing rules → lint) starts~~ **Done (1.64.0)** — all four steps shipped, and the identity-glossary convergence (cause/owner/acting identity, [identity-glossary.md](identity-glossary.md)) is settled.
2. **Plan docs are written for agent readers.** They increasingly *are* the coordination medium of rung 7's teams. Standalone, linked, one-meaning terms — the existing handoff discipline, now with a reason that scales.
3. **Every mid-level plan can cite its rung.** Not bureaucracy — just a one-line "this builds toward" so drift is visible early. *(Not yet adopted as of 2026-07-30 — no plan doc carries the line. Adopt for new plans; don't retrofit.)*
