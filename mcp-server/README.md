# Harmonic MCP Server

An MCP (Model Context Protocol) server that enables AI agents to interact with Harmonic.

## Installation

```bash
cd mcp-server
npm install
npm run build
```

## Configuration

Set the following environment variables:

- `HARMONIC_API_TOKEN` (required): Your Harmonic API token
- `HARMONIC_BASE_URL` (optional): Base URL for Harmonic (default: `http://localhost:3000`)

## Usage with Claude Desktop

Add to your Claude Desktop configuration (`~/Library/Application Support/Claude/claude_desktop_config.json`):

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

## Usage with Claude Code

Add to your Claude Code MCP settings:

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

## Available Resources

### `harmonic://context`

Documentation and context for using Harmonic. AI clients should read this resource first to understand the platform, data model, and available actions.

**Returns:** Markdown document covering:
- What Harmonic is (social agency platform)
- Design metaphors (music + biology)
- The OODA loop data model
- URL structure and navigation patterns
- Common actions for Notes, Decisions, and Commitments
- Key concepts (acceptance voting, critical mass, cycles, etc.)

## Available Tools

### `fetch_page`

Fetch the markdown of any Harmonic page at the given path.

**Parameters:**
- `path` (string, required): Relative URL path (e.g., `/collectives/team/n/abc123`)

**Example:**
```json
{
  "name": "fetch_page",
  "arguments": {
    "path": "/collectives/my-team"
  }
}
```

### `execute_action`

Execute an action at a given page.

**Parameters:**
- `path` (string, required): Path of the page the action operates on (e.g., `/collectives/team/n/abc123`).
- `action` (string, required): Action name (from the page's action list)
- `params` (object, optional): Parameters for the action

**Example:**
```json
{
  "name": "execute_action",
  "arguments": {
    "path": "/collectives/my-team/note",
    "action": "create_note",
    "params": {
      "title": "Meeting Notes",
      "text": "Discussion points from today's meeting",
      "deadline": "2025-12-31"
    }
  }
}
```

## Development

```bash
# Watch mode for development
npm run dev

# Build
npm run build

# Run
npm start
```

## Getting an API Token

1. Log in to your Harmonic tenant
2. Go to your account settings
3. Create a new API token with appropriate scopes
4. Copy the token and set it as `HARMONIC_API_TOKEN`
