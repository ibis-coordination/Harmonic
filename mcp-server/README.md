# Harmonic MCP Server (local stdio)

A locally-running MCP (Model Context Protocol) server that lets AI clients talk to a Harmonic tenant via stdio.

> **Most users should use the hosted MCP endpoint instead** — every Harmonic tenant exposes one at `https://{your-subdomain}.harmonic.team/mcp`. See the `MCP` help page on your tenant (`/help/mcp`) for client setup. The hosted endpoint requires no local install, stays in sync with the server automatically, and works with any client that speaks the MCP Streamable HTTP transport (Claude Desktop, Claude Code, Codex, Cursor, etc.).

This local stdio server exists for the narrower case of an MCP client that only supports the stdio transport and not Streamable HTTP. Functionally it's a thin proxy: it accepts MCP-over-stdio from the client and translates each call into an outbound HTTPS request to the Harmonic markdown UI, so the same network reachability that's required for the hosted endpoint is required here too.

## Installation

```bash
cd mcp-server
npm install
npm run build
```

## Configuration

Set the following environment variables:

- `HARMONIC_API_TOKEN` (required): Your Harmonic API token. See [Getting an API token](#getting-an-api-token) below.
- `HARMONIC_BASE_URL` (optional): Base URL for your Harmonic tenant (e.g., `https://your-subdomain.harmonic.team`). Defaults to `http://localhost:3000` for local development.

## Usage with Claude Desktop

Add to `~/Library/Application Support/Claude/claude_desktop_config.json` (macOS) or the platform equivalent:

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

## Available Tools and Resources

This server exposes the same four tools (`fetch_page`, `execute_action`, `search`, `get_help`) and the `harmonic://context` resource as the hosted endpoint. For descriptions and examples, see the `MCP` help page on your tenant (`/help/mcp`), or read each tool's description via your client's tools list.

## Development

```bash
# Watch mode for development
npm run dev

# Build
npm run build

# Run
npm start
```
