// The `codex-harness` built-in step: turn a freshly-added agent into a working
// Codex agent without hand-editing config.
//
// Same conservative contract as the other harnesses: replace the stub
// wake_command only while the stub marker is present, write system-prompt.md
// only when absent, set timeout_seconds only when absent. Safe on every add,
// and idempotent.
//
// Unlike the Claude and Goose pairs, Codex needs no config-file built-in: the
// MCP server rides in the wake command as `-c` overrides, parameterized on
// $HARMONIC_BRIDGE_AGENT_NAME. Auth stays in the shared ~/.codex (auth.json
// moves with CODEX_HOME, so a per-agent CODEX_HOME would demand a login per
// agent), and nothing is written outside the agent dir.

import { promises as fs } from "node:fs";
import path from "node:path";
import { parseDocument } from "yaml";
import { buildSystemPrompt } from "./harness-system-prompt.js";

/** Marker present only in the stub wake_command written by `add`. */
const STUB_MARKER = "wake_command not configured";

const DEFAULT_TIMEOUT_SECONDS = 900;

// --skip-git-repo-check: working_dir is usually not a git repo, and the check
//   would refuse to run.
// --sandbox workspace-write + approval_policy never: real work in the agent's
//   own directory, unattended — nothing may stall waiting for an approval,
//   because a stalled wake holds a hibernating host awake. The config-key
//   form rather than --ask-for-approval: newer codex builds removed that flag
//   from `exec` while the config key stays accepted everywhere.
// The sandbox mode is env-overridable because codex cannot sandbox in every
//   environment: inside a Fly sprite both bwrap and legacy Landlock fail, so
//   setup-sprite sets HARMONIC_BRIDGE_CODEX_SANDBOX=danger-full-access on the
//   service — there the single-agent micro-VM is the boundary, the same
//   posture as Claude Code's unrestricted Bash on a sprite.
// required=true: a Harmonic server that fails to start aborts the run instead
//   of silently proceeding without tools. The token is named, never inlined.
const WAKE_COMMAND =
  "codex exec \\\n" +
  "  --skip-git-repo-check \\\n" +
  '  --sandbox "${HARMONIC_BRIDGE_CODEX_SANDBOX:-workspace-write}" \\\n' +
  "  -c 'approval_policy=\"never\"' \\\n" +
  '  -c "mcp_servers.harmonic-$HARMONIC_BRIDGE_AGENT_NAME.url=\\"$HARMONIC_BRIDGE_MCP_ENDPOINT\\"" \\\n' +
  '  -c "mcp_servers.harmonic-$HARMONIC_BRIDGE_AGENT_NAME.bearer_token_env_var=\\"HARMONIC_BRIDGE_TOKEN\\"" \\\n' +
  '  -c "mcp_servers.harmonic-$HARMONIC_BRIDGE_AGENT_NAME.required=true" \\\n' +
  '  "$(cat "$HARMONIC_BRIDGE_AGENT_DIR/system-prompt.md")"\n';

const TOOLS_PARAGRAPH =
  "You have Codex's shell and file-editing tools, working in your working_dir. " +
  "Your four Harmonic tools — fetch_page, execute_action, search, get_help — come from the " +
  "harmonic-<your-handle> MCP server and may appear namespaced by that server name. " +
  "Use them when the task calls for it.";

export interface ApplyCodexHarnessArgs {
  readonly agentDir: string;
}

export interface ApplyCodexHarnessResult {
  readonly updatedWakeCommand: boolean;
  readonly wroteSystemPrompt: boolean;
}

export async function applyCodexHarness(args: ApplyCodexHarnessArgs): Promise<ApplyCodexHarnessResult> {
  const ymlPath = path.join(args.agentDir, "harmonic-bridge.yml");
  const promptPath = path.join(args.agentDir, "system-prompt.md");

  // Wake command: replace only the stub. parseDocument preserves the
  // generated file's comments and formatting for everything we don't touch.
  let updatedWakeCommand = false;
  const doc = parseDocument(await fs.readFile(ymlPath, "utf8"));
  const currentWake = doc.get("wake_command");
  if (typeof currentWake === "string" && currentWake.includes(STUB_MARKER)) {
    doc.set("wake_command", WAKE_COMMAND);
    if (!doc.has("timeout_seconds")) {
      doc.set("timeout_seconds", DEFAULT_TIMEOUT_SECONDS);
    }
    await fs.writeFile(ymlPath, doc.toString(), "utf8");
    updatedWakeCommand = true;
  }

  // System prompt: write only if absent ('wx' fails on existing files).
  let wroteSystemPrompt = false;
  try {
    const prompt = buildSystemPrompt({ toolsParagraph: TOOLS_PARAGRAPH });
    await fs.writeFile(promptPath, prompt, { flag: "wx" });
    wroteSystemPrompt = true;
  } catch (e) {
    if (!(e instanceof Error && "code" in e && (e as NodeJS.ErrnoException).code === "EEXIST")) throw e;
  }

  return { updatedWakeCommand, wroteSystemPrompt };
}
