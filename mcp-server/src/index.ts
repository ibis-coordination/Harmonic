#!/usr/bin/env node

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import { handleNavigate, handleExecuteAction, createState, type Config } from "./handlers.js";

// Configuration from environment
const config: Config = {
  baseUrl: process.env.HARMONIC_BASE_URL || "http://localhost:3000",
  apiToken: process.env.HARMONIC_API_TOKEN,
};

// State
const state = createState();

// Create the MCP server
const server = new McpServer({
  name: "harmonic",
  version: "0.1.0",
});

// Register navigate tool
server.registerTool(
  "navigate",
  {
    description:
      "Navigate to a URL in Harmonic and see its content and available actions. " +
      "Returns markdown content plus a list of actions you can take on this page. " +
      "URLs can be shared with humans—they see the same page in their browser. " +
      "Examples: '/studios/team', '/studios/team/d/abc123', '/studios/team/cycles/today'",
    inputSchema: {
      path: z.string().describe("Relative path (e.g., '/studios/team/n/abc123')"),
    },
  },
  async ({ path }) => handleNavigate(path, config, state)
);

// Register execute_action tool
server.registerTool(
  "execute_action",
  {
    description:
      "Execute an action available at the current URL. " +
      "You must call 'navigate' first to see available actions. " +
      "Actions are contextual—only actions listed for the current page will work.",
    inputSchema: {
      action: z.string().describe("Action name from the available actions list"),
      params: z
        .record(z.string(), z.unknown())
        .optional()
        .describe("Parameters for the action (see action's parameter list)"),
    },
  },
  async ({ action, params }) => handleExecuteAction(action, params as Record<string, unknown> | undefined, config, state)
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
