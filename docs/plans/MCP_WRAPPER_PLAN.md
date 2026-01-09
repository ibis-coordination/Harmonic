# MCP Wrapper Plan

This document outlines the plan for building an MCP (Model Context Protocol) server that wraps Harmonic's existing markdown+actions interface, preserving the navigation-based interaction model.

## Goal

Create an MCP server that enables AI agents to interact with Harmonic using the same navigation model as humans—visiting URLs, seeing contextual content and available actions, and executing actions in context. This preserves URL sharing between humans and agents and maintains context-appropriate tooling.

## Background

### Current Dual-Interface Architecture

Harmonic already supports two parallel interfaces:
- **HTML** for browser users
- **Markdown + Actions** for LLMs (same routes with `Accept: text/markdown`)

The markdown interface returns:
1. Content rendered as markdown
2. A list of **contextual actions** available on that page
3. Actions vary by resource type and state (e.g., can't vote twice, can't join a full commitment)

### Why This Matters

| Feature | Standard MCP | Harmonic's Pattern |
|---------|--------------|------------------------|
| Tools | Static, global list | Contextual, varies by page |
| Navigation | No concept | URL-based, like humans |
| Shared context | Tool parameters only | URLs work for humans & agents |
| Discovery | See all tools upfront | See what's available HERE |

### Design Decision: Navigation-Based MCP

Rather than exposing many granular tools (create_note, vote, join_commitment, etc.), we wrap the existing pattern with **meta-tools** that preserve navigation:

```
Standard MCP:     Agent → [many static tools] → call with params → result
Our approach:     Agent → navigate(url) → [content + contextual actions] → execute_action → result
```

This means:
- Agents navigate the app exactly as humans do
- URLs can be shared between humans and agents in conversation
- Actions are always contextually appropriate
- Existing markdown rendering and action logic is reused

## Architecture

### Option A: Rails-Native (Recommended)

Implement MCP directly in Rails, reusing existing markdown views and action handlers.

```
┌─────────────────────────────────────────────────────────────────────┐
│                        MCP Client (Claude Code)                      │
└────────────────────────────────┬────────────────────────────────────┘
                                 │ MCP Protocol (stdio or HTTP)
                                 ▼
┌─────────────────────────────────────────────────────────────────────┐
│                     MCP Server (Ruby/Rails)                          │
│  ├── Tools: navigate, execute_action                                │
│  ├── State: current_url, available_actions                          │
│  └── Reuses: Markdown views, ActionsHelper, ApiHelper               │
└────────────────────────────────┬────────────────────────────────────┘
                                 │ Direct (in-process)
                                 ▼
┌─────────────────────────────────────────────────────────────────────┐
│                     Existing Rails Application                       │
│  ├── Markdown views (*.md.erb)                                      │
│  ├── ActionsHelper (available actions per resource)                 │
│  └── ApiHelper (business logic)                                     │
└─────────────────────────────────────────────────────────────────────┘
```

**Pros:**
- Direct access to existing markdown rendering
- No network latency
- Single codebase, single deployment
- Reuses all existing logic

**Cons:**
- Must implement MCP protocol (JSON-RPC 2.0) manually
- No official Ruby SDK (yet)

### Option B: TypeScript Wrapper

Separate Node.js service that calls Rails via HTTP.

```
┌─────────────────────────────────────────────────────────────────────┐
│                        MCP Client (Claude Code)                      │
└────────────────────────────────┬────────────────────────────────────┘
                                 │ MCP Protocol (stdio)
                                 ▼
┌─────────────────────────────────────────────────────────────────────┐
│                   MCP Server (TypeScript/Node.js)                    │
│  ├── Tools: navigate, execute_action                                │
│  ├── State: current_url, available_actions                          │
│  └── Uses official MCP SDK                                          │
└────────────────────────────────┬────────────────────────────────────┘
                                 │ HTTP (Accept: text/markdown)
                                 ▼
┌─────────────────────────────────────────────────────────────────────┐
│                     Existing Rails Application                       │
│  └── Responds with markdown + actions (existing functionality)      │
└─────────────────────────────────────────────────────────────────────┘
```

**Pros:**
- Official SDK handles protocol details
- TypeScript type safety

**Cons:**
- Separate service to deploy
- HTTP latency for each navigation
- Must parse actions from markdown response (or add JSON endpoint)

### Recommendation

**Option A (Rails-native)** for tighter integration and simplicity. The MCP protocol is straightforward enough that implementing it in Ruby is reasonable.

## MCP Tools

Only two tools, preserving the navigation model:

### 1. `navigate`

Navigate to a URL and see its content and available actions.

```ruby
{
  name: "navigate",
  description: "Navigate to a URL in Harmonic and see its content and available actions. " \
               "Returns markdown content plus a list of actions you can take on this page. " \
               "URLs can be shared with humans—they see the same page in their browser. " \
               "Examples: '/studios/team', '/studios/team/d/abc123', '/studios/team/cycles/today'",
  inputSchema: {
    type: "object",
    properties: {
      url: {
        type: "string",
        description: "Relative URL path (e.g., '/studios/team/n/abc123')",
      },
    },
    required: ["url"],
  },
}
```

**Returns:**
```markdown
# Current URL: /studios/team/d/abc123

# Should we adopt weekly standups?

**Status:** Open (3 days remaining)
**Participants:** 5 of 8 members have voted

## Options

1. **Yes, every Monday** - 3 votes (Accept)
2. **Yes, async updates** - 2 votes (Accept)
3. **No change needed** - 1 vote (Reject)

## Available Actions

- **vote**: Cast your vote on an option
  - option_id (required): ID of the option to vote for

- **add_option**: Add a new option to this decision
  - title (required): Option title
  - description: Optional description

- **comment**: Add a comment to this decision
  - body (required): Comment text in markdown
```

### 2. `execute_action`

Execute one of the actions available at the current URL.

```ruby
{
  name: "execute_action",
  description: "Execute an action available at the current URL. " \
               "You must call 'navigate' first to see available actions. " \
               "Actions are contextual—only actions listed for the current page will work.",
  inputSchema: {
    type: "object",
    properties: {
      action: {
        type: "string",
        description: "Action name from the available actions list",
      },
      params: {
        type: "object",
        description: "Parameters for the action (see action's parameter list)",
        additionalProperties: true,
      },
    },
    required: ["action"],
  },
}
```

**Returns:**
```markdown
✓ Vote recorded for "Yes, every Monday"

Current URL: /studios/team/d/abc123

(Use 'navigate' to see updated content and available actions)
```

## Components to Build

### 1. MCP Protocol Handler

JSON-RPC 2.0 implementation for MCP.

- [ ] Parse JSON-RPC requests
- [ ] Route to appropriate handlers (initialize, tools/list, tools/call)
- [ ] Format JSON-RPC responses
- [ ] Handle errors with proper error codes

```ruby
# app/services/mcp/protocol_handler.rb
module Mcp
  class ProtocolHandler
    def handle(request)
      case request["method"]
      when "initialize"        then handle_initialize(request)
      when "tools/list"        then handle_tools_list(request)
      when "tools/call"        then handle_tool_call(request)
      when "resources/list"    then handle_resources_list(request)
      else                          error_response(-32601, "Method not found")
      end
    end
  end
end
```

### 2. Navigation State Manager

Maintains navigation context within a session.

- [ ] Track current URL
- [ ] Cache current page's available actions
- [ ] Handle session persistence (for stdio transport)

```ruby
# app/services/mcp/navigation_state.rb
module Mcp
  class NavigationState
    attr_reader :current_url, :available_actions

    def navigate(url)
      @current_url = url
      @available_actions = fetch_actions_for(url)
    end

    def action_available?(name)
      @available_actions.any? { |a| a[:name] == name }
    end
  end
end
```

### 3. Markdown Fetcher

Renders pages as markdown with available actions.

- [ ] Reuse existing markdown views (*.md.erb)
- [ ] Integrate with ActionsHelper for available actions
- [ ] Handle authentication context
- [ ] Parse/structure action definitions for MCP response

```ruby
# app/services/mcp/markdown_fetcher.rb
module Mcp
  class MarkdownFetcher
    def initialize(user:, tenant:)
      @user = user
      @tenant = tenant
    end

    def fetch(url)
      # Route URL to controller/action
      # Render markdown view
      # Extract available actions
      {
        markdown: rendered_content,
        actions: available_actions,
      }
    end
  end
end
```

### 4. Action Executor

Executes contextual actions.

- [ ] Validate action is available at current URL
- [ ] Map action to appropriate service (ApiHelper, ParticipantManagers, etc.)
- [ ] Execute with proper authentication context
- [ ] Return result with any redirect URL

```ruby
# app/services/mcp/action_executor.rb
module Mcp
  class ActionExecutor
    def execute(url:, action:, params:, user:, tenant:)
      # Determine resource from URL
      # Validate action is allowed
      # Execute via appropriate service
      # Return result
    end
  end
end
```

### 5. Transport Layer

Handle stdio communication for Claude Code.

- [ ] Read JSON-RPC from stdin
- [ ] Write responses to stdout
- [ ] Handle connection lifecycle

```ruby
#!/usr/bin/env ruby
# bin/mcp-server

require_relative "../config/environment"

handler = Mcp::ProtocolHandler.new

$stdin.each_line do |line|
  request = JSON.parse(line)
  response = handler.handle(request)
  $stdout.puts response.to_json
  $stdout.flush
end
```

### 6. HTTP Transport (Optional)

Alternative transport for non-stdio clients.

- [ ] POST /mcp endpoint for JSON-RPC
- [ ] Session management for navigation state
- [ ] Authentication via API token

## Directory Structure

```
app/
└── services/
    └── mcp/
        ├── protocol_handler.rb    # JSON-RPC routing
        ├── navigation_state.rb    # URL/history tracking
        ├── markdown_fetcher.rb    # Render markdown + actions
        ├── action_executor.rb     # Execute contextual actions
        └── tools.rb               # Tool definitions

bin/
└── mcp-server                     # Stdio entry point

config/
└── initializers/
    └── mcp.rb                     # Configuration
```

## Implementation Order

### Phase 1: Protocol Foundation
- [ ] JSON-RPC 2.0 handler (initialize, tools/list, tools/call)
- [ ] Tool definitions (navigate, execute_action)
- [ ] Stdio transport (bin/mcp-server)
- [ ] Basic navigation state (current_url, available_actions)

### Phase 2: Navigation Integration
- [ ] Markdown fetcher using existing views
- [ ] Actions extraction from ActionsHelper
- [ ] Format actions for MCP response
- [ ] Test with Claude Code

### Phase 3: Action Execution
- [ ] Action executor with validation
- [ ] Integration with ApiHelper
- [ ] Integration with ParticipantManagers
- [ ] Error handling and messaging

### Phase 4: Polish
- [ ] Session persistence
- [ ] HTTP transport option
- [ ] Documentation
- [ ] Edge case handling

## Example Interaction

```
Agent: navigate("/studios/team")
Server: Returns studio homepage markdown + actions [create_note, create_decision, create_commitment]

Agent: navigate("/studios/team/cycles/today")
Server: Returns today's activity + actions [create_note, ...]

Agent: execute_action("create_note", { title: "Meeting notes", body: "..." })
Server: Returns success + new note URL

Agent: navigate("/studios/team/n/xyz789")
Server: Returns the new note + actions [edit, confirm_read, comment, pin]

Agent: "I created meeting notes at /studios/team/n/xyz789"
Human: *clicks link, sees same content in browser*
```

## Configuration

```bash
# Environment variables
MCP_TRANSPORT=stdio              # or "http"
MCP_DEBUG=false                  # Enable verbose logging

# For HTTP transport
MCP_HTTP_PORT=3001
```

## Success Criteria

- [ ] `bin/mcp-server` starts and responds to MCP protocol
- [ ] Can navigate to any studio URL and see markdown content
- [ ] Available actions match what ActionsHelper provides
- [ ] Can execute actions (create note, vote, join commitment)
- [ ] URLs returned by server work in browser
- [ ] Errors are informative and actionable

## Non-Goals

- **Granular tools**: No separate create_note, vote, etc.—actions are contextual
- **Real-time updates**: Polling via re-navigation
- **Multi-tenant**: Single tenant context per session
- **OAuth in MCP**: Assumes pre-authenticated API token
- **Resources**: Focus on tools first; resources are optional enhancement

## Testing Plan

- [ ] Unit tests for ProtocolHandler (JSON-RPC parsing)
- [ ] Unit tests for NavigationState
- [ ] Integration tests for MarkdownFetcher with real views
- [ ] Integration tests for ActionExecutor with real services
- [ ] End-to-end test with mock stdin/stdout
- [ ] Manual testing with Claude Code

## Security Considerations

- API token required for all operations
- Actions validated against current URL context
- No URL path traversal outside allowed routes
- Rate limiting via existing Rails middleware
- Audit logging via existing request logs

## Future Enhancements

1. **MCP Resources**: Expose notes, decisions as resources for @ mentions
2. **Streaming responses**: For long content or action results
3. **Multi-studio**: Switch studios within session
4. **Webhooks/notifications**: Alert agent to changes
5. **Prompt templates**: Pre-built workflows (e.g., "daily standup")

## Alternative: TypeScript Implementation

If Rails-native proves too complex, fall back to TypeScript:

```
mcp/
├── package.json
├── tsconfig.json
├── src/
│   ├── index.ts              # Entry point
│   ├── server.ts             # MCP server setup
│   ├── navigation.ts         # State management
│   └── api-client.ts         # Call Rails markdown endpoints
└── README.md
```

The TypeScript version would:
1. Call Rails with `Accept: text/markdown` header
2. Parse markdown response to extract actions section
3. Execute actions via Rails API endpoints
4. Maintain navigation state in memory

This requires adding a structured actions response (JSON) to the markdown endpoint, or parsing the "Available Actions" section from markdown.

## References

- [Model Context Protocol Specification](https://modelcontextprotocol.io)
- [JSON-RPC 2.0 Specification](https://www.jsonrpc.org/specification)
- [Harmonic Architecture](../ARCHITECTURE.md)
- [ActionsHelper](../../app/services/actions_helper.rb) - Existing action definitions
- [Markdown Views](../../app/views/) - Existing *.md.erb templates
