# AI Agent Capability Audit & Refactor

## Status

Planning. Follow-up to the stripe-integration PR.

## Context

A pre-merge code review of the agent-runner migration surfaced that the
AI-agent authorization story has structural gaps:

1. **Bearer-auth writes can bypass CapabilityCheck.** Routes under
   `/api/v1/*` and various legacy HTML routes don't have `/actions/` in
   the path, so they only get a CapabilityCheck gate if they're listed in
   `ActionCapabilityCheck::CONTROLLER_ACTION_MAP`. The map is partial
   (~30 entries). Routes not in it fall through to controller-level
   authorization only.

2. **The minimum fix shipped with the stripe-integration PR:**
   - `CapabilityCheck.allowed?` now fails closed for uncategorized
     actions rather than returning true when `capabilities: nil`.
   - `ActionCapabilityCheck#check_capability_for_action` now denies
     writes to unmapped routes when the user is an AI agent.
   - A test asserts every `ACTION_DEFINITIONS` key is in exactly one of
     the three capability lists (`AI_AGENT_ALWAYS_ALLOWED`,
     `AI_AGENT_ALWAYS_BLOCKED`, `AI_AGENT_GRANTABLE_ACTIONS`).
   - `start_representation` / `end_representation` moved from silently
     permitted to explicitly `GRANTABLE`.
   - Automation-rule actions moved to `ALWAYS_BLOCKED` for explicitness
     (HUMAN_ONLY_AUTHORIZATION already blocked them).

This plan covers the remaining work the minimum fix defers.

## Goals

1. Make the Bearer-auth write path deny-by-default, so a newly-added
   route isn't silently exposed to AI agents.
2. Keep external API-client usage working: non-agent Bearer tokens must
   continue to have full access where their scope permits, gated only
   by controller-level authorization (the pre-existing contract).
3. Keep human usage working: CapabilityCheck is an agent-only concern
   and must not interfere with session-authenticated humans.

## How authorization actually works (three layers)

Understanding these layers is critical for evaluating what needs fixing.

| Layer | Mechanism | Load-bearing for agents? |
|-------|-----------|--------------------------|
| Token scope | `validate_scope` → `ApiToken#can?` — checks HTTP verb × resource model | **No.** Internal agent tokens get all 48 scopes including `create:all`, `read:all`, etc. Always passes. Exists for external API clients. |
| Capability check | `ActionCapabilityCheck` → `CapabilityCheck.allowed?` — checks action name against three lists + agent config | **Yes.** This is the real agent gate. Fail-closed for unmapped writes. |
| Action authorization | `ActionAuthorization` — per-action role/type checks | Orthogonal. Checks admin status, resource ownership, etc. |

Agents interact with the app exclusively through `/actions/` routes
(via the agent-runner's `HarmonicClient`). They do NOT use REST API v1
endpoints directly. The `CONTROLLER_ACTION_MAP` entries for REST/HTML
routes exist as defense-in-depth against direct API calls with an agent
token, not as the primary enforcement path.

## Current enforcement landscape

| Path type | AI-agent gate | External-client gate |
|-----------|---------------|---------------------|
| `/actions/<name>` | ActionCapabilityCheck → CapabilityCheck.allowed? | Token scope + controller auth |
| Mapped REST/legacy (in CONTROLLER_ACTION_MAP) | Same | Token scope + controller auth |
| Unmapped REST/legacy (after stripe-integration fix) | **Denied** if agent, permitted if human/external | Token scope + controller auth |
| GET (any) | Allowed (navigation) | Token scope + controller auth |

## Phase 1: Populate CONTROLLER_ACTION_MAP

Today's map covers ~30 controller#action routes. Unmapped write routes
are caught by the fail-closed block (denied for agents), which is
correct behavior but produces opaque error messages
(`unmapped_write:notes#pin` instead of `pin_note`). Adding them to the
map turns an opaque deny into a proper capability-checked deny with a
clear error message, and ensures the right capability is checked if the
action is grantable.

Audit every controller that inherits from `ApplicationController` and
accepts writes, and either:

- Add a `controller#action` → capability mapping, or
- Confirm that the fail-closed block correctly denies it (for routes
  agents should never reach).

Controllers known to need review:

- `app/controllers/api/v1/users_controller.rb` (create/update/destroy)
- `app/controllers/api/v1/collectives_controller.rb` (update/destroy)
- `app/controllers/api/v1/options_controller.rb` (destroy)
- `app/controllers/api/v1/notes_controller.rb` (unchecked writes)
- `app/controllers/api/v1/decisions_controller.rb`
- `app/controllers/api/v1/commitments_controller.rb`
- `app/controllers/api/v1/votes_controller.rb`
- `app/controllers/heartbeats_controller.rb` (direct POST beyond /actions/)
- `app/controllers/notes_controller.rb#pin` / similar pin actions on
  decisions/commitments (mapped to grantable capabilities but routes
  aren't in the map)
- `app/controllers/users_controller.rb#update_image`
- `app/controllers/collectives_controller.rb#update_image`,
  `#remove_ai_agent`
- `app/controllers/representation_sessions_controller.rb` (now
  covered for agents via the GRANTABLE list, but the direct routes
  should still hit CapabilityCheck consistently)

## Phase 2: CI enforcement

After Phase 1, strengthen the existing CI checks:

- The `every defined action is in exactly one capability list` test
  already exists. Keep it.
- Add a check that every controller method mapped to a writing HTTP
  verb either appears in `CONTROLLER_ACTION_MAP` or is documented as
  intentionally relying on the fail-closed block.
- Flag any new `inherit_resources`-style auto-routing that bypasses
  the concern.

## Decisions: what we're NOT doing (and why)

### Token scope narrowing (dropped)

An earlier draft proposed narrowing internal agent tokens from all 48
scopes to a specific subset. This was dropped because:

1. **Token scopes aren't the load-bearing gate.** CapabilityCheck
   already blocks everything it needs to, per-action, with the
   three-list model. Narrowing scopes is strictly defense-in-depth.
2. **The scope abstraction doesn't match agent interaction patterns.**
   Token scopes map HTTP verbs to resource models (`create:notes`).
   Agent actions map action names to capabilities (`create_note`).
   These don't align — e.g., an agent voting goes through
   `POST /actions/vote` on the decisions controller, which is
   `create:decisions` in scope terms, not `create:votes`.
3. **Several agent actions hit controllers with nil resource_model**
   (notifications, home, search). These require `action:all` wildcard
   scopes to pass `validate_scope`. Narrowing away the wildcards would
   break agents.
4. **Effort-to-value is poor** given points 1-3. If we ever need this,
   the right approach would be to rethink `validate_scope` for the
   `/actions/` route pattern rather than trying to map action names
   back to resource-based scopes.

### Deny-by-default DSL refactor (dropped)

An earlier draft proposed adding method-level DSL annotations
(`agent_capability :capability_name` or `refuse_agent!` / `allow_agent!`
helpers) to every controller action. This was dropped because:

1. The fail-closed block on unmapped writes already provides
   deny-by-default for agents. A missing `CONTROLLER_ACTION_MAP` entry
   results in a deny, not a pass.
2. The DSL would add boilerplate to every controller action for marginal
   benefit over the current map + fail-closed approach.
3. Phase 2's CI check achieves the same "new routes must be explicitly
   categorized" goal without code-level annotations.

## Out of scope

- External-client (non-agent) authorization model. Token scope check
  stays the same for those callers.
- Human session auth. CapabilityCheck is already a no-op for humans.
- Admin controllers: they have their own role gating that's
  orthogonal to the agent concern.

## Risks

- **Breaking legitimate agent invocations.** Each route newly added to
  the map needs verification that the mapped capability is correct.
- **Behavior change for external API clients.** Keep them on the
  existing path; `CONTROLLER_ACTION_MAP` entries feed CapabilityCheck
  which is a no-op for non-agent users.

## Success criteria

- Every controller write is either in the capability map or
  correctly denied by the fail-closed block.
- A new controller action added without a declaration fails CI.
- No agent-reachable write exists that bypasses CapabilityCheck.
