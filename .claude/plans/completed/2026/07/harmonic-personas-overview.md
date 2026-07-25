# Harmonic Personas — Overview

Status: planning. This doc is the map; each component has its own scoped plan:

1. [capability-roles-automator-moderator.md](capability-roles-automator-moderator.md) — new grantable roles
2. [persona-handle-role-restructuring.md](persona-handle-role-restructuring.md) — trio identity cleanup that all personas build on
3. [agent-personas-melody-counterpoint.md](agent-personas-melody-counterpoint.md) — the two new personas
4. [moderation-controls-exploration.md](../../../moderation-controls-exploration.md) — carved off; design space only, nothing scheduled

## The picture

Three built-in Harmonic agent personas. The triad divides attention: each persona
watches for something different and brings a matching domain of expertise and
capability role. (Earlier drafts framed this as 1st/2nd/3rd person — that was
shorthand for the same split, not grammatical voice.)

| Persona | Focuses on | Expert in | Capability role |
|---|---|---|---|
| **melody** | doing — good things happen | Harmonic's features and controls | `automator` — create/configure automations |
| **counterpoint** | verifying — bad things don't | Harmonic's rules and boundaries | `moderator` — named now, grants nothing yet |
| **cadence** | learning — the collective learns from whatever happens | Harmonic's information architecture | `summarizer` — exists; cycle summaries + agent context curation still to build |

**"Trio" names the ENSEMBLE/feature** (renamed 2026-07-18): the agent
formerly called trio was retired; cadence is net-new. One `trio` flag
enables all three everywhere (workspaces included); the shared `trio`
role makes @trio fan out to all active personas. See
agent-personas-melody-counterpoint.md for the implemented state.

## Two kinds of roles (the load-bearing distinction)

- **Capability roles** (`automator`, `moderator`, `summarizer`): ordinary
  collective-member roles in `CollectiveMember.valid_roles`, grantable to
  ANYONE — human or agent — through the existing role-grant flow. Personas are
  default holders, not exclusive holders. Group tags derive automatically
  (`@automators`, `@moderators`, `@summarizers`).
- **Persona roles** (`melody`, `counterpoint`, `trio`): reserved, activator-managed
  identity roles. Never grantable through the role endpoints. They are the
  mention-resolution mechanism: `@trio` resolves to the member holding the `trio`
  persona role in the current collective (replacing today's `collective.trio_user`
  special case in MentionParser).

A persona agent therefore holds two roles: its persona role (identity) and its
capability role (function) — e.g. melody holds `melody` + `automator`.

## What personas inherit for free (from PR #504)

The funding-pool work was deliberately written against `system_role.present?` +
collective-identity principal, not against trio specifically. Every persona gets:
collective identity as principal, pool draw authorization
(`PayerResolver.collective_principaled?`), gateway routing on billing tenants,
and the attach validation. What does NOT generalize automatically:
`Collective#trio_user_id` (structural link), `ensure_trio_funded!`, TrioSeeder /
TrioActivator, the trio feature flag, `TRIO_DEFAULT_MODEL`, and dispatch error copy.

## Sequencing

1. **Capability roles** — smallest, fully independent, unblocks nothing but
   informs everything. Ships alone.
2. **Persona handle/role restructuring** — valuable for trio alone; establishes
   the persona-role mention mechanism and the `<persona>-[collective_handle]`
   handle scheme that melody/counterpoint reuse. Ships alone.
3. **Agent personas** — melody + counterpoint on the generalized structure.
4. **Moderation controls** — independent track, own timeline, own design
   process. The `moderator` role exists (capability-less) from step 1, so the
   counterpoint persona can hold it before the controls exist.

## Cross-cutting decisions (made)

- Roles are independent of the agents who hold them; assignable to anyone.
- Moderation is carved off; `moderator` is a named, capability-less role for now.
- Personas work should stay small in scope.
- **Two roles per persona**: reserved persona role (identity, activator-managed,
  drives mentions) + capability role (function, grantable to anyone).
- **`automator` manages ALL collective automations** — same surface as the admin
  gate it relaxes; no per-owner scoping.
- **Full structural generalization now**: `collective.trio_user_id` is dropped;
  the persona role on the CollectiveMember row is the single source of truth
  (`collective.persona_user("trio")`). Lands in component 2, so component 3
  genuinely just adds entries.
- **Prod melody retires**; the persona succeeds the name. Must happen before the
  persona work reaches prod: the moment "melody" enters `AGENT_ROLES`, the tag
  becomes collective-local and `@melody` mentions stop resolving to the external
  agent through the tenant handle index.

## Cross-cutting decisions (open)

1. **Packaging**: one feature flag per persona vs. a bundle; all paid-tier like
   trio (assumed yes). Activated individually or as a set.
2. **Pool consent**: members enrolled when trio was the only spender now fund up
   to three agents. Existing enrollment consent covers "the collective's agents"
   by the letter; decide whether adding personas to a funded pool warrants a
   notification (recommended) or re-consent.
3. **Default spend caps** per persona (`llm_daily_spend_cap_cents` exists per
   agent; three ambient agents triple automation-driven spend).
4. **Private workspaces**: workspace-trio exists; do melody/counterpoint appear
   in private workspaces too? (Assumed no for v1.)
5. **What makes melody proactive**: the main net-new product-design question;
   v1 ships mention-shaped defaults.
6. **Agent context curation** (trio's summarizer work): if trio curates context
   *for* melody and counterpoint, there's an inter-persona dependency to design
   deliberately. Deferred with the summarizer work.
