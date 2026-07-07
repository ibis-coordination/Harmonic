# Enforce ACTION_DEFINITIONS authorization at execute time

## The problem (one line)

The `authorization:` field on every entry in `ACTION_DEFINITIONS` is consulted only when building markdown action listings — never when an action actually executes. The execute path is gated only by whatever `before_action :authorize_*` the controller happens to declare. So a contributor who adds a new action with a tight `authorization:` rule but a thin controller ships an unguarded endpoint that looks gated to anyone reading the action definition.

## Background — how authorization actually works today

A write request currently passes through three layers:

1. **Controller `before_action` chain** — `require_login`, `set_*` (resource load), `authorize_*` (e.g. `authorize_parent`, `authorize_collective_admin`). This is the real per-request access control.
2. **`ActionCapabilityCheck` concern** — auto-included by `ApplicationController`. For any POST whose path contains `/actions/<name>`, it calls `CapabilityCheck.allowed?(user, name)`. Consults `AI_AGENT_ALWAYS_BLOCKED`, `AI_AGENT_ALWAYS_ALLOWED`, and the user's per-agent grantable list. Restricted users (AI agents, trustees) are denied. Unrestricted humans pass through.
3. **`ActionAuthorization.authorized?(action_name, user, context)`** — the function that consumes `ACTION_DEFINITIONS[name][:authorization]`. **Never called on the execute path.** Every call site is a listing helper:
   - `decisions_controller#actions_index_show`
   - `notes_controller#actions_index_show`
   - `user_lists_controller#actions_index_show`
   - `commitments_controller#actions_index_show`
   - `MarkdownHelper#available_actions_for_current_route`
   - `ActionsHelper.routes_and_actions_for_user`

The result: the `authorization:` field is a *visibility filter*. It controls which actions an action-index page shows to which users. Execution control comes from layers (1) and (2), independently of what `authorization:` says.

## What the fix is

Make `ActionAuthorization.authorized?` run on every `/actions/<name>` POST, *before* the controller's `execute_<name>` method. Deny with 403 if the rule rejects. The action definition becomes the single source of truth for "who can do this," consulted by both listings and executions.

Concretely:

1. Add a `before_action` to the existing `ActionCapabilityCheck` concern (or a sibling concern) that:
   - Triggers only on POST requests whose path matches `/actions/<name>` (mirroring `check_capability_for_action`'s trigger).
   - Looks up `ACTION_DEFINITIONS[name][:authorization]`.
   - Builds the context hash from controller instance variables (the same way `MarkdownHelper#build_authorization_context` does, or via a per-controller hook for controllers that need extra context).
   - Calls `ActionAuthorization.authorized?(name, current_user, context)`.
   - On false, renders 403 with the same `render_capability_denied`-style response shape.
2. Existing controller `authorize_*` before_actions stay. They keep working as belt-and-suspenders, and continue to gate non-action-routed endpoints. Over time we can decide whether they're still earning their keep once the action-layer gate is universal.

This change makes the architecture obvious: if you want to gate an action, you set `authorization:` in `ACTION_DEFINITIONS`. The field name now matches what the field does.

## The two related naming/ergonomics hazards

These don't go away just because we enforce the field. They become more important to fix because every action author will be reading the rules.

### N1. `HUMAN_ONLY_AUTHORIZATION` is misnamed

The lambda checks **two** conditions:

```ruby
return false unless user
return false unless user.user_type == "human"
return true unless target_user || target          # listing-permissive
return true if target_user && target_user.id == user.id   # self
return true if target && user.can_represent?(target)      # representee
false
```

The constant advertises only the human/agent gate and silently includes a self-or-representee check. Two failure modes:

- **Copy-paste foot-gun.** Someone wanting "block AI agents" picks this constant, omits a controller-side parent check, and inherits the self-or-representee filter without realizing.
- **Discovery failure.** Someone wanting "parent or trustee" doesn't find a constant with that name and writes their own, duplicating what this one already does.

Rename to something honest. Two options:

- A single descriptive constant: `HUMAN_PRINCIPAL_OR_REPRESENTATIVE`.
- Two simpler predicates that compose: `HUMAN_USER`, `SELF_OR_REPRESENTS_TARGET` — and let actions list both, ANDed.

The split is cleaner long-term. The single rename is a smaller diff.

### N2. `target_user` and `target` look like synonyms

Two context-hash fields with confusingly similar names:

| Field | Meaning | Used for |
|---|---|---|
| `target_user` | "the user the action is *about*" | Self-check: `target_user.id == user.id` |
| `target` | "the resource the action targets" | Representation check: `user.can_represent?(target)` |

Setting `target_user: @ai_agent` would mean "is the current user the same person as this agent" — almost never true for a parent. Setting `target: @ai_agent` means "can the current user represent this agent" — true for the parent. Picking the wrong one silently swaps to the wrong gate.

Rename to disambiguate the semantic:

- `target_user` → `self_user` (or `subject_user`)
- `target` → `principal` (or `represented_target`)

Once `ActionAuthorization` is on the execute path, action authors will be reading these hash keys constantly. They need to be unambiguous.

## What needs to happen, in order

### Step 1 — Plumb context into the execute path

`MarkdownHelper#build_authorization_context` reads controller instance variables (`@current_collective`, `@note`, `@decision`, `@commitment`, `@list`, `@showing_user`). This works because the helper runs in the controller's view-rendering context.

For the execute-time gate, the same context-building logic needs to run before the controller's action method. Two ways:

- **Same instance-variable scrape, but in a controller before_action.** Easy port. Fragile against new resource types: every new action's controller must set the right ivar (e.g. `@list`, `@target_agent`) and the scrape must know about it.
- **Per-controller `authorization_context` hook.** Each controller defines `def authorization_context` returning the hash. The before_action calls it. Explicit, less coupling. Slightly more boilerplate per controller.

The second is cleaner; existing controllers can keep a default that delegates to the current ivar scrape so the migration is gradual.

### Step 2 — Add the before_action

In `ActionCapabilityCheck` (or a sibling concern, e.g. `ActionAuthorizationCheck`):

```ruby
append_before_action :check_action_authorization

def check_action_authorization
  return unless request.post? && request.path.match?(%r{/actions/[^/]+/?$})
  return unless defined?(@current_user) && @current_user

  action_name = extract_action_name_from_path
  rule = ActionsHelper::ACTION_DEFINITIONS.dig(action_name, :authorization)
  return unless rule  # legacy actions with no rule fall through to existing gates

  context = authorization_context
  return if ActionAuthorization.authorized?(action_name, @current_user, context)

  render_capability_denied("authorization:#{action_name}")
end

def authorization_context
  # Default: scrape ivars same way MarkdownHelper does, plus a couple
  # of conventional agent / target ivars. Controllers override for
  # custom shapes.
  {
    collective: @current_collective,
    resource: @note || @decision || @commitment || @list,
    self_user: @showing_user,                                 # renamed
    principal: @ai_agent || @target_agent || @grant&.target,  # renamed
    representation_session: @current_representation_session,
  }
end
```

Order matters: this should run *after* `check_capability_for_action` so capability denials short-circuit. Both before_actions are `append_before_action`, so the include order in `ApplicationController` controls.

### Step 3 — Make every action's rule pass through `ActionAuthorization.authorized?(execute_context)`

Audit every existing `ACTION_DEFINITIONS` entry that has an `authorization:`:

- Build a representative context for the action.
- Confirm the rule allows the intended users and rejects everyone else.
- Where the rule is currently looser than what the controller's `before_action` enforces, tighten the rule (the rule now becomes the enforcement, so it must match what the controller's `authorize_*` does today).
- Where the rule is currently tighter than what the controller enforces, that's an *existing* security gap that just became visible — fix it (probably by tightening the controller historically, now both layers agree).

Tests: for each action, an integration test that posts as (parent, non-parent human, AI agent, anonymous) and asserts the right outcomes. The existing `ai_agent_bridge_setups_controller_test.rb` GATE tests are a template.

### Step 4 — Rename the constants and context keys

Once the execute-time gate is in place and every action is migrated:

- `HUMAN_ONLY_AUTHORIZATION` → either `HUMAN_PRINCIPAL_OR_REPRESENTATIVE` or split into composable predicates (preferred).
- `target_user:` → `self_user:` in the context hash.
- `target:` → `principal:` in the context hash.
- Other named rules (`WEBHOOK_AUTHORIZATION`, etc.) audited for accuracy and renamed where misleading.

Each rename is mechanical and reviewable in isolation.

### Step 5 — Delete unused controller-side `authorize_*` (optional)

Once Steps 2–3 are stable, some controller `before_action :authorize_*` calls become redundant — the action-layer gate does the same check. Leaving them in is fine (belt and suspenders). Removing them simplifies the chain. Either is OK; do it case-by-case.

## Acceptance criteria

- [ ] Every `/actions/<name>` POST is rejected with 403 if `ACTION_DEFINITIONS[name][:authorization]` returns false for the current user + built context — regardless of whether the controller has its own `authorize_*` before_action.
- [ ] An integration test exists per action that asserts the rule rejects the right users.
- [ ] No action has an `authorization:` rule whose intent diverges from what its controller enforces — audited and reconciled.
- [ ] Context keys and rule constants are named honestly (Step 4 names, or equivalents the team prefers).
- [ ] A README / inline doc in `ActionsHelper` and `ActionAuthorization` explains the model: "set `authorization:` in `ACTION_DEFINITIONS`; that's enforced at execute time and consulted for listings."

## Out of scope

- Refactoring the capability check side (the `AI_AGENT_ALWAYS_BLOCKED` lists). That layer is doing its job today and is a separate concern.
- Changing the markdown action-listing UX.

## Risks

- **The audit will surface real bugs.** Expected. Each is a discrete fix.
- **Context-building inconsistency.** Some controllers set `@target_user`, others `@target_agent`, others `@ai_agent`. The default `authorization_context` has to handle all of them, or controllers explicitly opt in via `authorization_context`. Cleanest: standardize on `principal:` in the hash and have each controller set it explicitly via override.
- **Performance.** One extra method call per write. Negligible.

## Why this is worth doing

`authorization:` looks like an enforcement gate. It is not. That mismatch shipped at least one almost-unguarded endpoint already (the original Connect controller in this branch) before I caught it on review. The fix is structural — make the field do what it says.
