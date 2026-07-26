// The `goose-harness` built-in step: turn a freshly-added agent into a working
// Goose agent without hand-editing config.
//
// Same conservative contract as `claude-code-harness`: replace the stub
// wake_command only while the stub marker is present, write system-prompt.md
// only when absent, set timeout_seconds only when absent. Safe on every add,
// and idempotent.
//
// Pairs with `goose-per-agent-mcp-config`, which writes the config.yaml this
// wake command's XDG_CONFIG_HOME points at.
//
// Goose is the first supported harness with no interactive login: its provider
// credential is an environment variable (GOOSE_PROVIDER, GOOSE_MODEL, and the
// provider's own key), supplied by the operator and inherited into the wake.
// The bridge does not manage it.

import { promises as fs } from "node:fs";
import path from "node:path";
import { parseDocument } from "yaml";
import { buildSystemPrompt } from "./harness-system-prompt.js";

/** Marker present only in the stub wake_command written by `add`. */
const STUB_MARKER = "wake_command not configured";

// Upstream's --max-turns default is 1000 and there is no default cap on tool
// repetition. On a hibernating host an unbounded wake holds the machine awake
// and billing, so the shipped default is bounded. These bound the agent's loop;
// timeout_seconds bounds wall-clock. They are complementary, not redundant.
const MAX_TURNS = 40;
const MAX_TOOL_REPETITIONS = 3;

const DEFAULT_TIMEOUT_SECONDS = 900;

// XDG_CONFIG_HOME alone selects the per-agent config root (honored by goose
// on macOS and Linux). HOME stays untouched so the agent keeps the daemon
// user's real dotfiles — gitconfig, ssh — for its shell work.
//
// --with-builtin developer belongs here rather than in the written config: it
// keeps the agent's local tool surface visible in the command the operator
// reads and edits.
const WAKE_COMMAND =
  'XDG_CONFIG_HOME="$HARMONIC_BRIDGE_AGENT_DIR/config" \\\n' +
  "goose run \\\n" +
  "  --no-session \\\n" +
  "  --quiet \\\n" +
  `  --max-turns ${MAX_TURNS} \\\n` +
  `  --max-tool-repetitions ${MAX_TOOL_REPETITIONS} \\\n` +
  "  --with-builtin developer \\\n" +
  '  --system "$(cat "$HARMONIC_BRIDGE_AGENT_DIR/system-prompt.md")" \\\n' +
  "  -i -\n";

function toolsParagraph(agentHandle: string): string {
  return (
    "Your shell and file tools come from Goose's developer extension. Your four Harmonic tools — " +
    `fetch_page, execute_action, search, get_help — come from the harmonic-${agentHandle} extension. ` +
    "Use them when the task calls for it."
  );
}

export interface ApplyGooseHarnessArgs {
  readonly agentDir: string;
  readonly agentHandle: string;
}

export interface ApplyGooseHarnessResult {
  readonly updatedWakeCommand: boolean;
  readonly wroteSystemPrompt: boolean;
}

export async function applyGooseHarness(args: ApplyGooseHarnessArgs): Promise<ApplyGooseHarnessResult> {
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
    const prompt = buildSystemPrompt({ toolsParagraph: toolsParagraph(args.agentHandle) });
    await fs.writeFile(promptPath, prompt, { flag: "wx" });
    wroteSystemPrompt = true;
  } catch (e) {
    if (!(e instanceof Error && "code" in e && (e as NodeJS.ErrnoException).code === "EEXIST")) throw e;
  }

  return { updatedWakeCommand, wroteSystemPrompt };
}
