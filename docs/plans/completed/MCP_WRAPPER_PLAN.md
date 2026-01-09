# MCP Server Plan

This document outlines the plan for the Harmonic MCP (Model Context Protocol) server that enables AI agents to interact with Harmonic studios.

## Goal

Create an MCP server that enables AI agents to interact with Harmonic using the same navigation model as humans—visiting URLs, seeing contextual content and available actions, and executing actions in context. This preserves URL sharing between humans and agents and maintains context-appropriate tooling.

## Status

**Current: TypeScript Implementation** ✅

A standalone TypeScript MCP server in `mcp-server/` that:
- Communicates via stdio with MCP clients (Claude Desktop, Claude Code)
- Calls the Harmonic Rails app via HTTP for content and actions
- Uses the official `@modelcontextprotocol/sdk`

## Background

### MCP Architecture

MCP servers are **local programs** that clients download and run. They communicate via stdio (stdin/stdout), not HTTP. This means:

- Users install the MCP server locally
- The client (Claude Desktop, Claude Code) spawns the server process
- Communication happens via JSON-RPC over stdio
- The server makes HTTP calls to external services (like Harmonic)

```
┌─────────────────────────────────────────────────────────────────────┐
│                   MCP Client (Claude Desktop/Code)                   │
└────────────────────────────────┬────────────────────────────────────┘
                                 │ stdio (JSON-RPC)
                                 ▼
┌─────────────────────────────────────────────────────────────────────┐
│                 MCP Server (TypeScript, runs locally)                │
│  ├── Tools: navigate, execute_action                                │
│  ├── State: current_url, available_actions                          │
│  └── Uses: @modelcontextprotocol/sdk                                │
└────────────────────────────────┬────────────────────────────────────┘
                                 │ HTTP (Accept: text/markdown)
                                 ▼
┌─────────────────────────────────────────────────────────────────────┐
│                   Harmonic Rails Application                         │
│  ├── Markdown views (*.md.erb)                                      │
│  ├── Action endpoints (/actions/*)                                  │
│  └── API token authentication                                       │
└─────────────────────────────────────────────────────────────────────┘
```

### Current Dual-Interface Architecture

Harmonic already supports two parallel interfaces:
- **HTML** for browser users
- **Markdown + Actions** for LLMs (same routes with `Accept: text/markdown`)

The markdown interface returns:
1. Content rendered as markdown
2. A list of **contextual actions** available on that page
3. Actions vary by resource type and state

### Design Decision: Navigation-Based MCP

Rather than exposing many granular tools (create_note, vote, join_commitment, etc.), we use **meta-tools** that preserve navigation:

```
Standard MCP:     Agent → [many static tools] → call with params → result
Our approach:     Agent → navigate(url) → [content + contextual actions] → execute_action → result
```

This means:
- Agents navigate the app exactly as humans do
- URLs can be shared between humans and agents in conversation
- Actions are always contextually appropriate
- Existing markdown rendering and action logic is reused

## MCP Tools

Only two tools, preserving the navigation model:

### 1. `navigate`

Navigate to a URL and see its content and available actions.

```typescript
{
  name: "navigate",
  description: "Navigate to a URL in Harmonic and see its content and available actions...",
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

### 2. `execute_action`

Execute one of the actions available at the current URL.

```typescript
{
  name: "execute_action",
  description: "Execute an action available at the current URL...",
  inputSchema: {
    type: "object",
    properties: {
      action: {
        type: "string",
        description: "Action name from the available actions list",
      },
      params: {
        type: "object",
        description: "Parameters for the action",
        additionalProperties: true,
      },
    },
    required: ["action"],
  },
}
```

## Directory Structure

```
mcp-server/
├── package.json           # Dependencies (@modelcontextprotocol/sdk)
├── tsconfig.json          # TypeScript config
├── src/
│   └── index.ts           # Main server implementation
├── dist/                  # Compiled output
│   └── index.js           # Entry point for clients
└── README.md              # Installation & usage
```

## Configuration

### Environment Variables

- `HARMONIC_API_TOKEN` (required): API token for authentication
- `HARMONIC_BASE_URL` (optional): Base URL, defaults to `http://localhost:3000`

### Claude Desktop Configuration

Add to `~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "harmonic": {
      "command": "node",
      "args": ["/path/to/harmonic/mcp-server/dist/index.js"],
      "env": {
        "HARMONIC_API_TOKEN": "your-api-token",
        "HARMONIC_BASE_URL": "https://your-subdomain.harmonic.team"
      }
    }
  }
}
```

### Claude Code Configuration

Similar configuration in Claude Code's MCP settings.

## Implementation Status

### Completed ✅

- [x] TypeScript project setup with `@modelcontextprotocol/sdk`
- [x] `navigate` tool - fetches markdown content from Harmonic
- [x] `execute_action` tool - posts to action endpoints
- [x] Navigation state management (current URL, available actions)
- [x] Error handling
- [x] README with installation instructions

### TODO

- [ ] Distribution strategy (npm package? bundled binary?)
- [ ] Action discovery from server response (currently hardcoded patterns)
- [ ] Testing with Claude Desktop
- [ ] CI/CD for releases

## Example Interaction

```
Agent: navigate("/studios/team")
Server: Returns studio homepage markdown + actions [create_note, create_decision, ...]

Agent: navigate("/studios/team/note")
Server: Returns note creation form + actions [create_note]

Agent: execute_action("create_note", { title: "Meeting notes", text: "..." })
Server: Returns success message

Agent: "I created meeting notes - check /studios/team/n/xyz789"
Human: *clicks link, sees same content in browser*
```

## Security Considerations

- API token required for all operations
- Actions validated against current URL context
- No URL path traversal outside allowed routes
- Token stored in environment, not in code

## Future Enhancements

1. **Dynamic action discovery**: Parse actions from server response instead of hardcoded patterns
2. **MCP Resources**: Expose notes, decisions as resources for @ mentions
3. **Streaming responses**: For long content
4. **npm distribution**: Publish as `harmonic-mcp-server` or similar
5. **Prompt templates**: Pre-built workflows

## References

- [Model Context Protocol Specification](https://modelcontextprotocol.io)
- [MCP TypeScript SDK](https://github.com/modelcontextprotocol/typescript-sdk)
- [Harmonic Architecture](../ARCHITECTURE.md)
