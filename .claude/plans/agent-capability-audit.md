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
   (~20 entries). Routes not in it fall through to controller-level
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

This plan covers the broader refactor that the minimum fix defers.

## Goals

1. Make the Bearer-auth write path deny-by-default, so a newly-added
   route isn't silently exposed to AI agents.
2. Keep external API-client usage working: non-agent Bearer tokens must
   continue to have full access where their scope permits, gated only
   by controller-level authorization (the pre-existing contract).
3. Keep human usage working: CapabilityCheck is an agent-only concern
   and must not interfere with session-authenticated humans.

## Current enforcement landscape

| Path type | AI-agent gate | External-client gate |
|-----------|---------------|---------------------|
| `/actions/<name>` | ActionCapabilityCheck → CapabilityCheck.allowed? | Token scope + controller auth |
| Mapped REST/legacy (in CONTROLLER_ACTION_MAP) | Same | Token scope + controller auth |
| Unmapped REST/legacy (after this fix) | **Denied** if agent, permitted if human/external | Token scope + controller auth |
| GET (any) | Allowed (navigation) | Token scope + controller auth |

## Phase 1: Populate CONTROLLER_ACTION_MAP

Today's map is a random sample. Audit every controller that inherits
from `ApplicationController` and accepts writes, and either:

- Add a `controller#action` → capability mapping, or
- Mark the controller action as "agent-unreachable" with an explicit
  `refuse_agent!` call at the top of the method.

Controllers known to need review (from the security audit):

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

## Phase 2: Deny-by-default refactor

Flip the default shape of `ActionCapabilityCheck`: for any write
request on a controller that inherits from `ApplicationController`,
require either an explicit capability mapping or an explicit
`agent_allowed!` / `agent_denied!` call. A missing declaration is a
deploy-time error, not a silent pass.

Two implementation options:

- **Option A — Method-level DSL.** Add `agent_capability :capability_name`
  at the top of each action (like `before_action`). The concern reads
  the annotation instead of the static `CONTROLLER_ACTION_MAP`.
- **Option B — Explicit method-level marker.** Add
  `refuse_agent!` / `allow_agent!` helpers the action calls at its
  top. More boilerplate, less magic.

Option A is cleaner; Option B is more grep-able.

## Phase 3: Ephemeral token scope narrowing (now defense-in-depth)

With CapabilityCheck consistently enforced on all writes, the
ephemeral internal agent token's full `valid_scopes` is strictly
defense-in-depth rather than a load-bearing check. Still worth doing
for least-privilege, but no longer urgent. Proposed scope set:

```ruby
INTERNAL_AGENT_SCOPES = %w[
  read:all
  create:notes update:notes
  create:confirmations
  create:decisions update:decisions
  create:options
  create:votes
  create:decision_participants
  create:commitments update:commitments
  create:commitment_participants
].freeze
```

Before shipping, verify every `/actions/<name>` route the agent
legitimately invokes either short-circuits on `read:all` or has its
resource in `valid_resources` and in the scope list. Several agent
actions touch resources not in `valid_resources` today
(`heartbeats`, `notifications`, `trustee_grants`, `attachments`,
`reminders`) — these currently pass because `create:all` is in the
token. Narrowing requires either adding those resources to
`valid_resources` or adjusting the scope-check fallback.

## Phase 4: Add CI enforcement

After phase 2, add a CI check:

- Run the existing `every defined action is in exactly one
  capability list` test (already in place).
- Add a check that every controller method mapped to a writing HTTP
  verb either appears in `CONTROLLER_ACTION_MAP` or has an explicit
  `refuse_agent!` / capability declaration.
- Flag any new `inherit_resources`-style auto-routing that bypasses
  the concern.

## Out of scope

- External-client (non-agent) authorization model. Token scope check
  stays the same for those callers.
- Human session auth. CapabilityCheck is already a no-op for humans.
- Admin controllers: they have their own role gating that's
  orthogonal to the agent concern.

## Risks

- **Breaking legitimate agent invocations.** Each route newly gated
  needs verification. A test that exercises one action of each class
  (create_note, vote, add_comment, etc.) through the real agent-runner
  HTTP path would catch regressions.
- **Behavior change for external API clients.** Keep them on the
  existing path; don't route external clients through
  CapabilityCheck's new fail-closed logic.

## Success criteria

- Every controller write is either in the capability map or
  explicitly refuses AI agents.
- A new controller action added without a declaration fails CI.
- No agent-reachable write exists that bypasses CapabilityCheck.
- The ephemeral token's scope set matches what agents actually need
  (phase 3 optional, but the analysis is documented).
