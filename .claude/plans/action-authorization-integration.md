# Plan: Action Authorization Integration

## Context

The app has a well-designed `ActionAuthorization` system that determines whether a user can perform a given action. However, it's only partially integrated:

- `ActionAuthorization.authorized?` exists and checks base authorization, AI agent capabilities, and trustee grants
- `ActionsHelper.routes_and_actions_for_user` uses it for the global actions index at `/actions`
- **`MarkdownHelper#available_actions_for_current_route`** (YAML frontmatter) does NOT use it — it only filters by `CapabilityCheck` for AI agents
- **Per-page `actions_index_show` methods** in controllers don't use it — they pass through static lists
- **Block checks** are enforced server-side in `ApiHelper` but not reflected in the action listings

The result: the YAML frontmatter and actions index pages advertise actions that will fail when attempted. An AI agent (or user viewing markdown UI) sees "vote" as available, tries it, and gets a block error.

## Goal

Make the YAML frontmatter and actions index pages reflect what the user can actually do. The action list should be the truth — if an action is listed, the user can perform it.

## Design

### Approach: Use `ActionAuthorization.authorized?` everywhere

The authorization system already exists and handles multiple concerns (role-based auth, capabilities, trustee grants). Adding block checks to this system and then using it consistently in all action-listing code paths is the right approach.

### What changes

**1. Add block checking to `ActionAuthorization`**

Add a new step in `ActionAuthorization.authorized?` after the trustee check: if the action operates on a resource with a `created_by`, check for blocks between the user and the resource author.

Not all actions need block checks — only actions that interact with a specific user's content:
- `confirm_read`, `add_comment` — on notes
- `vote`, `add_options` — on decisions
- `join_commitment` — on commitments

Creation actions (`create_note`, `create_decision`, `create_commitment`) are unaffected — they don't target another user's content.

The check needs a `resource` in the context. When no resource is provided (e.g., for the global actions listing), the check is permissive (same pattern used by `:resource_owner` and `:collective_member`).

**2. Use `ActionAuthorization.authorized?` in `MarkdownHelper`**

Replace the manual `CapabilityCheck` filter with `ActionAuthorization.authorized?`. This automatically picks up block checks, capability checks, trustee checks, and role checks.

The context needs: `user`, `collective`, `resource`, `representation_session`. All are available as instance variables in the controller.

**3. Use `ActionAuthorization.authorized?` in controller `actions_index_show` methods**

Update `NotesController#actions_index_show`, `DecisionsController#actions_index_show`, and `CommitmentsController#actions_index_show` to filter their action lists through `ActionAuthorization.authorized?` with the current resource as context.

## Implementation

### Phase 1: Add block check to ActionAuthorization

Add a `blocked?` check in `ActionAuthorization.authorized?`, after the trustee check:

```ruby
# In ActionAuthorization.authorized?
return false unless check_authorization(auth, user, context)
return false unless CapabilityCheck.allowed?(user, action_name)
return false unless trustee_authorized?(user, action_name, context)
return false if blocked_from_action?(user, action_name, context)  # NEW
true
```

The `blocked_from_action?` method:
- Returns false (not blocked) if no resource in context
- Returns false if the action isn't a resource-interaction action
- Returns false if the resource has no `created_by`
- Returns `UserBlock.between?(user, resource.created_by)` otherwise

Define which actions are "resource-interaction" actions that should check blocks:

```ruby
BLOCK_CHECKED_ACTIONS = %w[
  confirm_read add_comment
  vote add_options
  join_commitment
].freeze
```

### Phase 2: Use ActionAuthorization in MarkdownHelper

Update `available_actions_for_current_route` to build a proper context and filter through `ActionAuthorization.authorized?`:

```ruby
def available_actions_for_current_route
  route_pattern = build_route_pattern_from_request
  return [] unless route_pattern

  route_info = ActionsHelper.actions_for_route(route_pattern)
  return [] unless route_info

  all_actions = (route_info[:actions] || []) + evaluate_conditional_actions(route_info)

  # Filter through ActionAuthorization with full context
  current_user = instance_variable_get(:@current_user)
  context = build_authorization_context
  all_actions = all_actions.select do |action|
    ActionAuthorization.authorized?(action[:name], current_user, context)
  end

  # Build full action info with path and params
  all_actions.map { |action| build_action_info(action) }
end

def build_authorization_context
  {
    collective: instance_variable_get(:@current_collective),
    resource: find_current_resource,
    target_user: instance_variable_get(:@showing_user),
    representation_session: instance_variable_get(:@current_representation_session),
  }
end

def find_current_resource
  # Try common instance variables for the current content resource
  instance_variable_get(:@note) ||
    instance_variable_get(:@decision) ||
    instance_variable_get(:@commitment)
end
```

### Phase 3: Use ActionAuthorization in controller actions_index methods

Update the `actions_index_show` methods in `NotesController`, `DecisionsController`, and `CommitmentsController` to filter through `ActionAuthorization.authorized?`:

```ruby
# In NotesController#actions_index_show
def actions_index_show
  @note = current_note
  @page_title = "Actions | #{@note.title}"
  actions_info = ActionsHelper.actions_for_route('/collectives/:collective_handle/n/:note_id')
  actions = (actions_info[:actions] || []).select do |action|
    ActionAuthorization.authorized?(action[:name], @current_user, {
      collective: @current_collective,
      resource: @note,
    })
  end
  render_actions_index({ actions: actions })
end
```

Same pattern for decisions and commitments.

### Phase 4: Tests

**ActionAuthorization tests** (`test/services/action_authorization_test.rb`):
- `confirm_read` blocked when user block exists between user and note author
- `vote` blocked when user block exists between user and decision author
- `join_commitment` blocked when user block exists
- `add_comment` blocked when user block exists
- `create_note` NOT blocked (creation actions unaffected)
- Block check permissive when no resource in context

**MarkdownHelper tests** (or integration tests):
- YAML frontmatter excludes blocked actions when viewing blocked user's content
- YAML frontmatter includes actions when no block exists

**Controller actions_index tests**:
- Actions index excludes blocked actions
- Actions index includes actions when no block exists

## Open Questions

1. **Should `add_options` be blocked?** If you can't vote on a decision because of a block, should you also not be able to add options? Yes — adding options is participating in the decision.

2. **Should `pin_note`/`pin_decision`/`pin_commitment` be blocked?** Pinning is a collective action (pinning to the collective homepage), not a direct interaction with the author. Probably not blocked.

3. **Performance**: `ActionAuthorization.authorized?` is called per-action. With ~3-5 actions per page, that's 3-5 calls. The block check inside does `UserBlock.between?` which is a DB query. Should we preload? For YAML frontmatter, this runs once per request with a small action count, so it's probably fine. If needed, we can pass `block_related_user_ids` in the context.
