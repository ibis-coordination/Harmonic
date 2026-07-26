// The `claude-code-harness` built-in step: turn a freshly-added agent into
// a working Claude Code agent without hand-editing config.
//
// `harmonic-bridge add` writes a stub wake_command that fails loudly. This
// step replaces the stub with a headless Claude Code invocation (MCP config
// + system prompt + tool allowlist) and writes a starter system-prompt.md.
// Both writes are conservative: a customized wake_command or an existing
// system-prompt.md is never touched, so the step is safe to run on every
// add and is idempotent.
//
// Pairs with `claude-code-per-agent-mcp-config`, which writes the
// mcp-config.json this wake command references.

import { promises as fs } from "node:fs";
import path from "node:path";
import { parseDocument } from "yaml";
import { buildSystemPrompt } from "./harness-system-prompt.js";

/** Marker present only in the stub wake_command written by `add`. */
const STUB_MARKER = "wake_command not configured";

const WAKE_COMMAND =
  'claude -p \\\n' +
  '  --mcp-config "$HARMONIC_BRIDGE_AGENT_DIR/mcp-config.json" \\\n' +
  '  --append-system-prompt @"$HARMONIC_BRIDGE_AGENT_DIR/system-prompt.md" \\\n' +
  '  --allowedTools "Bash,Read,Write,Edit,Glob,Grep,WebFetch' +
  ',mcp__harmonic-${HARMONIC_BRIDGE_AGENT_NAME}__fetch_page' +
  ',mcp__harmonic-${HARMONIC_BRIDGE_AGENT_NAME}__execute_action' +
  ',mcp__harmonic-${HARMONIC_BRIDGE_AGENT_NAME}__search' +
  ',mcp__harmonic-${HARMONIC_BRIDGE_AGENT_NAME}__get_help"\n';

const DEFAULT_TIMEOUT_SECONDS = 900;

const SYSTEM_PROMPT = buildSystemPrompt({
  toolsParagraph:
    "You have Bash, Read, Write, Edit, Glob, Grep, WebFetch available alongside the four MCP tools. Use them when the task calls for it.",
});

export interface ApplyClaudeCodeHarnessArgs {
  readonly agentDir: string;
}

export interface ApplyClaudeCodeHarnessResult {
  readonly updatedWakeCommand: boolean;
  readonly wroteSystemPrompt: boolean;
}

export async function applyClaudeCodeHarness(args: ApplyClaudeCodeHarnessArgs): Promise<ApplyClaudeCodeHarnessResult> {
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
    await fs.writeFile(promptPath, SYSTEM_PROMPT, { flag: "wx" });
    wroteSystemPrompt = true;
  } catch (e) {
    if (!(e instanceof Error && "code" in e && (e as NodeJS.ErrnoException).code === "EEXIST")) throw e;
  }

  return { updatedWakeCommand, wroteSystemPrompt };
}
