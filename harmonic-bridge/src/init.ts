// `harmonic-bridge init` — write the skeleton config files a user needs to start.
//
// Writes ~/.harmonic-bridge/config.yml and ~/.harmonic-bridge/harmonic-bridge.service (a systemd
// unit template) plus an empty ~/.harmonic-bridge/agents/ directory. Existing
// files are NOT overwritten — re-running init on a configured host is a
// no-op for already-present files.

import { promises as fs } from "node:fs";
import path from "node:path";

export interface InitResult {
  readonly written: readonly string[];
  readonly skipped: readonly string[];
}

const CONFIG_YAML_SKELETON = `# harmonic-bridge daemon config — see https://github.com/ibis-coordination/Harmonic/tree/main/harmonic-bridge
listen: 127.0.0.1:8080

# Publicly reachable HTTPS URL of this host — required by 'harmonic-bridge add'.
# Each agent's webhook URL is constructed as \${public_url}/webhook/<agent-handle>.
# Front the daemon with a reverse proxy (Caddy, nginx) or a tunnel (cloudflared,
# ngrok) that terminates TLS and forwards to the listen port above.
public_url: ""   # SET ME before running 'harmonic-bridge add'

log_dir: ~/.harmonic-bridge/logs

# Where 'harmonic-bridge add' stores minted credentials. v0.1 ships only the
# 'file' backend; future versions add 1Password, Vault, etc.
secrets:
  backend: file
  base_dir: ~/.harmonic-bridge/secrets

# Optional. Built-in resolvers (file://, env://) are always present.
# Add a line per scheme you want to use. The "{name}" / "{path}" / "{ref}"
# token is substituted with the reference body at wake time.
#
# secret_resolvers:
#   op:    "op read {ref}"
#   awssm: "aws secretsmanager get-secret-value --secret-id {ref} --query SecretString --output text"

# Optional. Steps that run once per agent after 'harmonic-bridge add' succeeds.
# Lets you opt into harness-specific local setup (writing a Claude Code MCP
# config, running 'codex mcp add', etc.). Empty by default.
#
# after_add:
#   - built_in: claude-code-per-agent-mcp-config
#   - command: 'codex mcp add harmonic --url "$HARMONIC_BRIDGE_MCP_ENDPOINT" --bearer-token-env-var HARMONIC_BRIDGE_TOKEN'
`;

const SYSTEMD_UNIT_SKELETON = `[Unit]
Description=harmonic-bridge — self-hosted Harmonic agent daemon
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/harmonic-bridge
Restart=on-failure
RestartSec=5
# Run as the user whose home contains ~/.harmonic-bridge — set this before enabling.
# User=harmonic-bridge
# Group=harmonic-bridge

[Install]
WantedBy=multi-user.target
`;

export async function initConfig(configDir: string): Promise<InitResult> {
  await fs.mkdir(path.join(configDir, "agents"), { recursive: true });

  const written: string[] = [];
  const skipped: string[] = [];

  await writeIfMissing(path.join(configDir, "config.yml"), CONFIG_YAML_SKELETON, written, skipped);
  await writeIfMissing(path.join(configDir, "harmonic-bridge.service"), SYSTEMD_UNIT_SKELETON, written, skipped);

  return { written, skipped };
}

async function writeIfMissing(
  filePath: string,
  contents: string,
  written: string[],
  skipped: string[],
): Promise<void> {
  try {
    // 'wx' = write, fail if exists. Atomic check-and-write.
    await fs.writeFile(filePath, contents, { flag: "wx" });
    written.push(filePath);
  } catch (e) {
    if (isNodeError(e) && e.code === "EEXIST") {
      skipped.push(filePath);
      return;
    }
    throw e;
  }
}

function isNodeError(e: unknown): e is NodeJS.ErrnoException {
  return e instanceof Error && "code" in e;
}
