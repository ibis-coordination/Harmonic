# Agent axes: management vs. access (internal/external redefinition)

**Status:** Planned 2026-07-28, not started. Follows the controlled-vocabulary work
(PR #544); implements a terminology ruling that also has one enforcement consequence.

## The ruling

Today "internal agent" / "external agent" names a single distinction: internal =
runs on Harmonic's agent runner, external = runs on the operator's own harness via
MCP. That conflates two orthogonal axes:

- **Management** — who runs the agent:
  - **Harmonic-managed** — powered by Harmonic's agent runner.
  - **self-managed** — powered by the operator's own harness, connected via MCP with
    API tokens. ("Self-hosted" remains the narrower subset: self-managed on hardware
    the operator controls. A Codex Cloud agent is self-managed but not self-hosted.)
- **Access** — what systems the agent can reach:
  - **internal** — can act only inside Harmonic; no access to systems outside it.
  - **external** — has access to systems outside Harmonic.

Decided semantics:

1. **Internal is a verifiable guarantee, so only Harmonic-managed agents can carry
   it.** A self-managed agent's environment is invisible to Harmonic, so all
   self-managed agents are external by definition. Today the axes coincide
   (Harmonic-managed ⇒ internal, self-managed ⇒ external); in the future,
   Harmonic-managed **external** agents may exist (runner-hosted agents with tools
   that reach outside systems). Harmonic-managed internal is the only combination
   that can honestly claim the sandbox.
2. **LLM inference through Harmonic's gateway does not count as external access** —
   it is infrastructure, not agent-directed reach. State this in copy.
3. **Webhook creation breaks the internal claim.** An internal agent must not be
   able to create or edit automation `webhook` actions — an agent that can cause
   POSTs to arbitrary external URLs has external reach, even indirectly through a
   collective automation.

## Consequence 1: enforcement gap (do this FIRST)

The claim must be true before copy makes it. Today built-in agents (Trio) hold
automator-level capabilities and can create/edit collective automations, including
`webhook` actions — which violates ruling 3.

- Block Harmonic-managed agents from creating or editing automations that contain
  `webhook` actions (and from adding a `webhook` action to an existing rule).
  Candidate enforcement points: `CapabilityCheck` (a non-grantable action for
  internal agents) and/or validation in the automation create/update path keyed on
  the acting user being a runner-managed agent. Humans and automator-role members
  are unaffected.
- The refusal copy should say why: "This agent is internal — it cannot set up
  actions that reach outside Harmonic. A collective admin or automator can add the
  webhook action."
- Audit other outbound channels an internal agent could configure or hold:
  - Notification webhooks — can a runner-managed agent have one? If yes, same
    treatment (it forwards content to an external URL).
  - Automation `trigger_agent` / `internal_action` actions — stay allowed (they act
    inside Harmonic).
  - API tokens — already impossible for internal agents (no externally accessible
    tokens), which is part of the guarantee; keep the existing invariant.
- Prod audit before deploy: do any existing runner-managed agents own automations
  with `webhook` actions? If so, decide grandfather-vs-migrate before the block
  lands.
- Red-green: tests for the refusal on both the create and edit paths, plus one that
  an automator human is unaffected.

## Consequence 2: vocabulary + copy reframe

Glossary (`docs/CONTROLLED_VOCABULARY.md`):

- Redefine **internal agent** — an agent that can act only inside Harmonic, with no
  access to outside systems; a guarantee only Harmonic-managed agents can carry.
  LLM inference via the gateway does not count as outside access.
- Redefine **external agent** — an agent with access to systems outside Harmonic.
  All self-managed agents are external; Harmonic-managed external agents may exist
  in the future.
- Add **Harmonic-managed** — run by Harmonic's agent runner.
- Add **self-managed** — run by the operator's own harness, connected via MCP.
  Do not use: external (for the management axis).
- Adjust **self-hosted** framing where it appears: the self-managed subset on
  hardware the operator controls.
- **built-in agent** row: still "a ready-made Harmonic-managed internal agent whose
  principal is the collective" — update wording to the new axes.

Copy surfaces (sweep during implementation; known spots):

- `app/views/help/agents.md.erb` — the "Internal vs External Agents" section is the
  main rewrite: present the two axes, note that today all Harmonic-managed agents
  are internal and all self-managed agents are external, and move the mechanics
  sentences ("authenticate via API tokens and reach Harmonic through MCP") from
  "external" to "self-managed".
- `app/views/help/api.md.erb` — "Internal AI agents (those run by Harmonic's agent
  runner) do not have externally accessible API tokens": rekey to Harmonic-managed,
  and note this is part of what makes the internal guarantee verifiable.
- `app/views/help/trio.md.erb` — "They run only inside Harmonic" bullet: state both
  axes explicitly (Harmonic-managed and internal), plus the webhook restriction
  once Consequence 1 ships.
- `app/views/help/self_hosting_agents.md.erb` — position self-hosted under
  self-managed.
- Agent settings UI — the internal/external mode toggle labels and hints: relabel
  to the management axis (the `agent_configuration["mode"]` values `internal`/
  `external` are code identifiers and keep their names).
- Agent profile badges/copy, `/help/agents/getting-started`, and `actions_helper`
  descriptions — grep for "internal agent" / "external agent" and rekey each use to
  whichever axis it actually means.
- Tests locking the new framing (agents help page names both axes; refusal copy).

Lint: no new mechanically checkable pattern — axis misuse is a judgment call. The
glossary rows carry the rule.

## Sequencing

1. Enforcement: block webhook-action creation/editing for Harmonic-managed agents
   (+ notification-webhook audit + prod audit of existing rules).
2. Glossary redefinition + copy sweep + settings-UI labels, in one change.
3. When a Harmonic-managed external agent ships, its design revisits the refusal
   from step 1 as a per-agent capability flip that also flips the badge.

## Open questions

- Does the settings toggle stay a single control (Harmonic-managed vs self-managed)
  with access implied, or become two controls once managed-external exists?
- Should the agent's access class (internal/external) be displayed on their profile
  as a trust signal? It is arguably the more decision-relevant fact for other
  members than who manages them.
