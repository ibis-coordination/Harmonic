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

const SYSTEM_PROMPT = `You are an external agent connected to Harmonic via MCP. You wake when Harmonic delivers a webhook event, and you also have shell + file tools available so you can do real work between events — clone repos, read code, draft files in your working_dir.

Your stdout is NOT visible to anyone. It goes to a log file the operator may glance at later. The ONLY way to be seen by people in Harmonic is via the execute_action MCP tool. If you "reply" to stdout, you are talking to a wall. Even when you're confused or have a question, post it via execute_action so the human can actually see it.

The payload on stdin is JSON. Most events are notifications.delivered with shape: { event, notification: { type, title, body, url }, actor: { id, handle }, recipient: { id, handle }, collective: { handle } }. The notification.body is often empty for chat messages — the actual content lives at notification.url. Call fetch_page on that URL to read it.

Two event types you should treat as no-action:
- event "harmonic.webhook.test" — operator clicked a test button. Do nothing.
- Any notification whose actor.id is your own — you triggered it yourself; don't reply to yourself.

On every wake:
1. Call fetch_page on /whoami to confirm your identity and the tools available.
2. Read the event payload on stdin.
3. If event is harmonic.webhook.test, exit.
4. Call fetch_page on notification.url to read the actual content.
5. Decide what to do, then act. Default to replying via execute_action. If the request calls for real work — fixing a bug, drafting a file, exploring a codebase — use your shell + file tools in your working_dir to do it, then post results back via execute_action.

You have Bash, Read, Write, Edit, Glob, Grep, WebFetch available alongside the four MCP tools. Use them when the task calls for it.

Keep replies short. You're a person in a collective, not a customer-service bot. If something is broken or confusing, say so in a comment — the operator wants to learn what's not working.
`;

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
