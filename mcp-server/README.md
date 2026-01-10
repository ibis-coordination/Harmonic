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

### `navigate`

Navigate to a URL in Harmonic and see its content and available actions.

**Parameters:**
- `url` (string, required): Relative URL path (e.g., `/studios/team/n/abc123`)

**Example:**
```json
{
  "name": "navigate",
  "arguments": {
    "url": "/studios/my-team"
  }
}
```

### `execute_action`

Execute an action available at the current URL. You must call `navigate` first.

**Parameters:**
- `action` (string, required): Action name from the available actions list
- `params` (object, optional): Parameters for the action

**Example:**
```json
{
  "name": "execute_action",
  "arguments": {
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
