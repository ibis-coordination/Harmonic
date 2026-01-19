# Harmonic MCP Server Skill

Guide for using the Harmonic MCP (Model Context Protocol) server to navigate and interact with the app.

## Overview

The Harmonic MCP server provides two tools:
- `navigate(path)` - Navigate to a URL and see content + available actions
- `execute_action(action, params)` - Execute an action at current URL

## Basic Pattern

```
1. Navigate to a page
2. Read content and available actions
3. Execute an action with parameters
4. Navigate again to see result
```

**Always navigate before executing actions.** Actions are context-dependent.

## Navigation

```typescript
// Navigate to studio
mcp__harmonic__navigate({ path: "/studios/taco-tuesday" })

// Navigate to create note
mcp__harmonic__navigate({ path: "/studios/taco-tuesday/note" })

// Navigate to view specific note
mcp__harmonic__navigate({ path: "/studios/taco-tuesday/n/abc12345" })
```

### Response Format

Navigation returns markdown with:
- Header metadata (app, host, path, title, timestamp)
- Navigation bar
- Page content
- Available actions with parameter signatures

## Executing Actions

### Notes

```typescript
// Create note
mcp__harmonic__execute_action({
  action: "create_note",
  params: { text: "# My Note\n\nMarkdown content here" }
})

// Confirm reading a note
mcp__harmonic__execute_action({
  action: "confirm_read",
  params: {}
})

// Add comment
mcp__harmonic__execute_action({
  action: "add_comment",
  params: { text: "My comment text" }
})
```

### Decisions

```typescript
// Create decision
mcp__harmonic__execute_action({
  action: "create_decision",
  params: {
    question: "What should we do?",
    description: "Optional markdown description",
    options_open: true,
    deadline: "2026-01-20T23:59:59Z"
  }
})

// Add option (parameter is "title", not "text"!)
mcp__harmonic__execute_action({
  action: "add_option",
  params: { title: "Option A" }
})

// Vote on option
mcp__harmonic__execute_action({
  action: "vote",
  params: {
    option_title: "Option A",
    accept: true,
    prefer: true
  }
})
```

### Commitments

```typescript
// Create commitment
mcp__harmonic__execute_action({
  action: "create_commitment",
  params: {
    title: "Do something",
    description: "Optional description",
    critical_mass: 3,
    deadline: "2026-01-20T18:00:00Z"
  }
})

// Join commitment
mcp__harmonic__execute_action({
  action: "join_commitment",
  params: {}
})
```

### Studios

```typescript
// Send heartbeat (required to access studio content)
mcp__harmonic__execute_action({
  action: "send_heartbeat",
  params: {}
})

// Create studio
mcp__harmonic__execute_action({
  action: "create_studio",
  params: {
    name: "My Studio",
    handle: "my-studio",
    description: "Optional description",
    timezone: "America/Los_Angeles",
    tempo: "daily",
    synchronization_mode: "improv"
  }
})
```

### Notifications

```typescript
// Mark notification as read
mcp__harmonic__execute_action({
  action: "mark_read",
  params: { id: "notification-uuid" }
})

// Mark all as read
mcp__harmonic__execute_action({
  action: "mark_all_read",
  params: {}
})
```

## Important Notes

### Heartbeat Requirement
When first accessing a studio, you may see "Heartbeat Required". Execute `send_heartbeat()` to gain access for the current cycle.

### API Must Be Enabled
Some studios have API disabled. You'll get a 403 error:
```
Error: HTTP 403: {"error":"API not enabled for this studio"}
```

### Parameter Names
Be careful with parameter names:
- `add_option` uses `title`, not `text`
- `create_note` uses `text`
- Check the action signature in navigation response

### Action Availability
Actions vary by:
- Page context (different actions on different pages)
- User permissions (member vs non-member)
- Current state (e.g., can't join commitment twice)

## Useful Navigation Paths

| Path | Purpose |
|------|---------|
| `/` | Home - see your studios |
| `/actions` | List ALL available actions |
| `/notifications` | See and manage notifications |
| `/studios/{handle}` | Studio home |
| `/studios/{handle}/cycles` | Cycle overview with counts |
| `/studios/{handle}/cycles/today` | Today's items |
| `/studios/{handle}/backlinks` | Items by backlink count |

## Error Handling

- **HTTP 403**: API not enabled or permission denied
- **HTTP 500**: Usually wrong parameter names or values
- **Heartbeat Required**: Navigate shows this message, execute `send_heartbeat()`

## Dual Interface

The MCP server provides the same information as the browser UI:
- Humans see HTML in browser
- AI agents see markdown via MCP
- Same data, navigation, and functionality
- URLs are shareable between interfaces
