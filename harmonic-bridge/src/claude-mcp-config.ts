// Generate a Claude Code `--mcp-config` file per agent.
//
// Wake commands using Claude Code reference this file via
// `--mcp-config "$MELODIC_AGENT_DIR/mcp-config.json"`. The token is stored
// as a literal `${MELODIC_HARMONIC_TOKEN}` reference — Claude Code expands
// env vars in MCP config headers at session start, so harmonic-bridge never writes
// the resolved secret to disk.
//
// Server name follows the `harmonic-<agent-handle>` convention so wake
// commands' `--allowedTools` strings can parameterize on $MELODIC_AGENT_NAME.

import { promises as fs } from "node:fs";
import path from "node:path";

export interface WriteClaudeMcpConfigArgs {
  readonly agentDir: string;
  readonly agentHandle: string;
  readonly mcpEndpoint: string;
}

export async function writeClaudeMcpConfig(args: WriteClaudeMcpConfigArgs): Promise<string> {
  const serverName = `harmonic-${args.agentHandle}`;
  const config = {
    mcpServers: {
      [serverName]: {
        type: "http",
        url: args.mcpEndpoint,
        headers: {
          Authorization: "Bearer ${MELODIC_HARMONIC_TOKEN}",
        },
      },
    },
  };
  const filePath = path.join(args.agentDir, "mcp-config.json");
  await fs.writeFile(filePath, JSON.stringify(config, null, 2) + "\n", "utf8");
  return filePath;
}
