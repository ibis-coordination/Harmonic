# MarkdownUiService

> **Status**: Implemented
> **Branch**: `feature/markdown-ui-service`

## Overview

`MarkdownUiService` renders the markdown UI without requiring a controller/HTTP request context. This enables AI agents to navigate the app internally from chat sessions, seeing the same markdown interface that external LLMs see via HTTP—but without the HTTP request overhead.

## Use Case

AI agents chatting in the UI need to navigate and execute actions within the app. Rather than making HTTP requests, agents can use this service to:
- Navigate to any page and get the rendered markdown content
- See available actions for the current page
- Execute actions (create notes, vote on decisions, etc.)

## Files

| File | Purpose |
|------|---------|
| `app/services/markdown_ui_service.rb` | Main service with `navigate`, `set_path`, and `execute_action` methods |
| `app/services/markdown_ui_service/view_context.rb` | Provides instance variables for templates |
| `app/services/markdown_ui_service/resource_loader.rb` | Loads resources based on routes |
| `app/services/markdown_ui_service/action_executor.rb` | Executes actions via ApiHelper |
| `test/services/markdown_ui_service_test.rb` | Unit tests (25 tests) |

## API

### Constructor

```ruby
service = MarkdownUiService.new(
  tenant: tenant,        # Required: Tenant record
  superagent: superagent, # Optional: Superagent/studio (defaults to main)
  user: user             # Optional: User record (nil for unauthenticated)
)
```

### Methods

#### `navigate(path, include_layout: true)` → NavigateResult

Navigates to a path and renders the markdown view.

```ruby
result = service.navigate("/studios/team")
# => { content: "...", path: "/studios/team", actions: [...], error: nil }

result = service.navigate("/studios/team/n/abc123", include_layout: false)
# => Content without YAML front matter and nav bar
```

**Returns:**
- `content`: Rendered markdown string
- `path`: The requested path
- `actions`: Array of available actions for this page
- `error`: Error message if navigation failed, nil otherwise

#### `set_path(path)` → Boolean

Sets up context for a path without rendering. Useful when you only want to execute actions.

```ruby
service.set_path("/studios/team/note")
# => true (success) or false (failure)
```

#### `execute_action(action_name, params = {})` → ActionResult

Executes an action at the current path. Requires calling `navigate` or `set_path` first.

```ruby
service.navigate("/studios/team/note")
result = service.execute_action("create_note", { text: "Hello world" })
# => { success: true, content: "Note created: /studios/team/n/abc123", error: nil }
```

**Returns:**
- `success`: Boolean indicating success
- `content`: Success message or result description
- `error`: Error message if action failed, nil otherwise

#### `validate_access` → String?

Checks if the user has access to the tenant and superagent. Returns nil if authorized, or an error message.

```ruby
error = service.validate_access
# => nil (authorized)
# => "User is not a member of this tenant"
# => "User is not a member of this studio"
# => "Authentication required"
```

### Available Actions

Actions are determined by the current route. Use `navigate` to see available actions:

```ruby
result = service.navigate("/studios/team/n/abc123")
result[:actions]
# => [
#   { name: "confirm_read", description: "Confirm you've read this note", params: [] },
#   { name: "edit_note", description: "Edit note content", params: [...] },
#   ...
# ]
```

## Authorization

The service replicates controller authorization logic:

1. **Unauthenticated access**: Blocked if tenant requires login
2. **Tenant membership**: User must have a `TenantUser` record
3. **Superagent membership**: User must have a `SuperagentMember` record (main superagent doesn't require explicit membership)

Authorization is checked automatically in `navigate` and `set_path`.

## Supported Controllers/Routes

| Controller | Actions | Resources Loaded |
|------------|---------|------------------|
| `home` | index | studios list |
| `studios` | show, new, join, settings, team, cycles | pinned_items, team, cycles |
| `notes` | new, show, edit | note, note_reader |
| `decisions` | new, show, settings | decision, decision_participant |
| `commitments` | new, show, settings | commitment, commitment_participant |
| `notifications` | index | notifications |
| `users` | show, settings | - |
| `cycles` | index, today | cycles |

## Supported Actions

The action executor supports all actions defined in `ActionsHelper`:

- **Note actions**: `create_note`, `confirm_read`, `edit_note`, `pin_note`, `unpin_note`
- **Decision actions**: `create_decision`, `vote`, `edit_settings`, `pin_decision`, `unpin_decision`
- **Commitment actions**: `create_commitment`, `join_commitment`, `leave_commitment`, `edit_settings`, `pin_commitment`, `unpin_commitment`
- **Studio actions**: `create_studio`, `join_studio`, `leave_studio`, `update_settings`, `send_heartbeat`
- **Notification actions**: `mark_read`, `dismiss`, `mark_all_read`

## Thread-Local Context

The service properly manages thread-local tenant/superagent context:

```ruby
# Context is set during navigate/set_path/execute_action
# and cleared afterward via ensure block
def with_context
  Superagent.scope_thread_to_superagent(
    subdomain: tenant.subdomain,
    handle: superagent&.handle
  )
  yield
ensure
  Tenant.clear_thread_scope
  Superagent.clear_thread_scope
end
```

## Example Usage

### Basic Navigation

```ruby
# In Rails console
tenant = Tenant.first
superagent = tenant.superagents.find_by(superagent_type: "studio")
user = User.first

service = MarkdownUiService.new(tenant: tenant, superagent: superagent, user: user)

# Navigate to home
result = service.navigate("/")
puts result[:content]

# Navigate to a studio
result = service.navigate("/studios/#{superagent.handle}")
puts result[:actions].map { |a| a[:name] }
```

### Creating Content

```ruby
# Navigate to create note page
service.navigate("/studios/team/note")

# Create a note
result = service.execute_action("create_note", { text: "Meeting notes from today" })
puts result[:content] # => "Note created: /studios/team/n/abc123"
```

### Efficient Action Execution

```ruby
# Use set_path for faster action execution (no rendering)
service.set_path("/studios/team/note")
result = service.execute_action("create_note", { text: "Quick note" })
```

## Testing

```bash
# Run unit tests
docker compose exec web bundle exec rails test test/services/markdown_ui_service_test.rb

# Run type checking
docker compose exec web bundle exec srb tc
```

## Implementation Notes

### View Rendering

Uses `ApplicationController.renderer` instead of `ActionView::Base` directly, which properly handles template compilation and helper methods.

### Resource Loading

The `ResourceLoader` mirrors controller resource loading logic, populating the `ViewContext` with the same instance variables that templates expect.

### Action Execution

The `ActionExecutor` delegates to `ApiHelper` for business logic, ensuring consistent behavior between HTTP API and internal service calls.
