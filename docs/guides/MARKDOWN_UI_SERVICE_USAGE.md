# MarkdownUiService Usage Guide

This guide provides practical examples for using `MarkdownUiService` to navigate and interact with the Harmonic app programmatically.

## Quick Start

```ruby
# Get your context objects
tenant = Tenant.find_by(subdomain: "mycompany")
superagent = tenant.superagents.find_by(handle: "engineering")
user = User.find_by(email: "alice@example.com")

# Create the service
service = MarkdownUiService.new(
  tenant: tenant,
  superagent: superagent,
  user: user
)

# Navigate to a page
result = service.navigate("/studios/engineering")

# Check for errors
if result[:error]
  puts "Error: #{result[:error]}"
else
  puts result[:content]  # Rendered markdown
  puts result[:actions]  # Available actions
end
```

## Common Use Cases

### 1. Browse Studio Content

```ruby
# View studio home page
result = service.navigate("/studios/engineering")
puts result[:content]

# View pinned items and team
# (These are included in the rendered content)
```

### 2. Read a Note

```ruby
# Navigate to a note
result = service.navigate("/studios/engineering/n/abc12345")

# The content includes the note text
puts result[:content]

# Confirm you've read it
service.execute_action("confirm_read")
```

### 3. Create a Note

```ruby
# Navigate to the new note page
service.navigate("/studios/engineering/note")

# Create the note
result = service.execute_action("create_note", {
  text: "# Meeting Notes\n\nDiscussed Q1 roadmap..."
})

if result[:success]
  puts result[:content]  # "Note created: /studios/engineering/n/xyz789"
end
```

### 4. Participate in a Decision

```ruby
# View a decision
result = service.navigate("/studios/engineering/d/dec12345")
puts result[:content]  # Shows question, options, current votes

# See available actions
puts result[:actions].map { |a| a[:name] }
# => ["vote", "pin_decision", ...]

# Cast a vote
result = service.execute_action("vote", { vote: "accept" })
```

### 5. Join a Commitment

```ruby
# View a commitment
service.navigate("/studios/engineering/c/com12345")

# Join the commitment
result = service.execute_action("join_commitment")

if result[:success]
  puts "Successfully joined!"
end
```

### 6. Send a Heartbeat

Studios may require periodic heartbeats to confirm presence:

```ruby
# Check if heartbeat is needed (view the studio page first)
result = service.navigate("/studios/engineering")

if result[:content].include?("Heartbeat Required")
  service.execute_action("send_heartbeat")
end
```

### 7. Efficient Action Execution

If you only need to execute actions (not view content), use `set_path`:

```ruby
# set_path is faster than navigate (no rendering)
service.set_path("/studios/engineering/note")
result = service.execute_action("create_note", { text: "Quick note" })
```

### 8. Navigate Without Layout

Get just the page content without the nav bar and YAML front matter:

```ruby
result = service.navigate("/studios/engineering", include_layout: false)
# result[:content] contains only the page body
```

## Understanding Results

### NavigateResult

```ruby
{
  content: "# Page Title\n...",      # Rendered markdown
  path: "/studios/engineering",       # Requested path
  actions: [                          # Available actions
    {
      name: "create_note",
      description: "Create a new note",
      params: [{ name: "text", type: "string", required: true }]
    },
    ...
  ],
  error: nil                          # Error message if failed
}
```

### ActionResult

```ruby
{
  success: true,                      # Whether action succeeded
  content: "Note created: /n/abc",    # Success message or details
  error: nil                          # Error message if failed
}
```

## Error Handling

```ruby
# Check navigation errors
result = service.navigate("/invalid/path")
if result[:error]
  case result[:error]
  when /Route not found/
    puts "Page doesn't exist"
  when /Access denied/
    puts "User doesn't have permission"
  when /Authentication required/
    puts "User must be logged in"
  end
end

# Check action errors
result = service.execute_action("create_note", { text: "" })
if !result[:success]
  puts "Action failed: #{result[:error]}"
end
```

## Authorization

The service enforces the same authorization rules as the web interface:

1. **Tenant membership**: User must be a member of the tenant
2. **Superagent membership**: User must be a member of the studio (main superagent is exempt)
3. **Login requirement**: If tenant requires login, user must be provided

```ruby
# This will fail if user isn't a studio member
service = MarkdownUiService.new(
  tenant: tenant,
  superagent: private_studio,
  user: non_member_user
)
result = service.navigate("/")
# result[:error] => "Access denied: User is not a member of this studio"
```

## Available Actions by Page

| Page | Actions |
|------|---------|
| Studio home | `create_note`, `create_decision`, `create_commitment`, `send_heartbeat` |
| New note | `create_note` |
| Note show | `confirm_read`, `edit_note`, `pin_note`, `unpin_note` |
| New decision | `create_decision` |
| Decision show | `vote`, `pin_decision`, `unpin_decision` |
| Decision settings | `edit_settings` |
| New commitment | `create_commitment` |
| Commitment show | `join_commitment`, `leave_commitment`, `pin_commitment`, `unpin_commitment` |
| Commitment settings | `edit_settings` |
| Notifications | `mark_read`, `dismiss`, `mark_all_read` |

## Tips

1. **Reuse the service**: Create one instance and make multiple navigate/execute calls
2. **Use set_path for actions**: It's faster than navigate when you don't need the content
3. **Check actions array**: The navigate result tells you exactly what actions are available
4. **Handle errors gracefully**: Always check `result[:error]` or `result[:success]`

## Testing

```ruby
# In Rails console
rails console

# Quick test
t = Tenant.first
s = t.superagents.find_by(superagent_type: "studio")
u = User.first

service = MarkdownUiService.new(tenant: t, superagent: s, user: u)
puts service.navigate("/")[:content]
```

## See Also

- [Full API Documentation](../plans/MARKDOWN_UI_SERVICE_PLAN.md)
- [Architecture Overview](../ARCHITECTURE.md)
