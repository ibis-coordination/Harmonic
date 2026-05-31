#!/usr/bin/env node

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import { handleFetchPage, handleExecuteAction, handleSearch, handleGetHelp, type Config } from "./handlers.js";
import { CONTEXT_MARKDOWN } from "./context.js";

// Configuration from environment
const config: Config = {
  baseUrl: process.env.HARMONIC_BASE_URL || "http://localhost:3000",
  apiToken: process.env.HARMONIC_API_TOKEN,
};

// Create the MCP server
const server = new McpServer({
  name: "harmonic",
  version: "0.1.0",
});

// Register fetch_page tool
server.registerTool(
  "fetch_page",
  {
    description:
      "Fetch the markdown representation of a Harmonic page at the given path. " +
      "The response includes content plus a list of actions available at that path, each with a fully-qualified action URL you can pass back to execute_action. " +
      "Examples: '/collectives/team', '/collectives/team/d/abc123', '/collectives/team/cycles/today'",
    inputSchema: {
      path: z.string().describe("Relative path (e.g., '/collectives/team/n/abc123')"),
    },
    annotations: {
      readOnlyHint: true,
    },
  },
  async ({ path }) => handleFetchPage(path, config)
);

// Register execute_action tool
server.registerTool(
  "execute_action",
  {
    description:
      "Execute an action at a given Harmonic page. " +
      "Pass the path of the page (e.g. '/collectives/team/n/abc123'), the action name (from the page's action list, e.g. 'add_comment'), and any params the action requires.",
    inputSchema: {
      path: z.string().describe(
        "Path of the page the action operates on (e.g., '/collectives/team/n/abc123')."
      ),
      action: z.string().describe("Action name (from the action list on the page)"),
      params: z
        .record(z.string(), z.unknown())
        .optional()
        .describe("Parameters for the action (see the action's parameter list)"),
    },
    annotations: {
      destructiveHint: true,
    },
  },
  async ({ path, action, params }) =>
    handleExecuteAction(path, action, params as Record<string, unknown> | undefined, config)
);

// Register search tool
server.registerTool(
  "search",
  {
    description:
      "Search Harmonic for notes, decisions, commitments, and people.",
    inputSchema: {
      query: z.string().describe(
        "Search query. Supports filters: type:note, type:decision, type:commitment, status:open, cycle:current, creator:@handle, collective:handle"
      ),
    },
    annotations: {
      readOnlyHint: true,
    },
  },
  async ({ query }) => handleSearch(query, config)
);

// Register get_help tool
server.registerTool(
  "get_help",
  {
    description:
      "Read Harmonic documentation for a topic.",
    inputSchema: {
      topic: z.string().describe(
        "Topic name. Available: collectives, notes, reminder-notes, table-notes, decisions, executive-decisions, lottery-decisions, commitments, cycles, search, links, agents, api, privacy"
      ),
    },
    annotations: {
      readOnlyHint: true,
    },
  },
  async ({ topic }) => handleGetHelp(topic, config)
);

// Register context resource
server.registerResource(
  "context",
  "harmonic://context",
  {
    description: "Documentation and context for using Harmonic. Read this first to understand the platform, data model, and available actions.",
    mimeType: "text/markdown",
  },
  async () => ({
    contents: [
      {
        uri: "harmonic://context",
        mimeType: "text/markdown",
        text: CONTEXT_MARKDOWN,
      },
    ],
  })
);

// Start the server
async function main() {
  const transport = new StdioServerTransport();
  await server.connect(transport);
  console.error("Harmonic MCP server running on stdio");
}

main().catch((error) => {
  console.error("Server error:", error);
  process.exit(1);
});
