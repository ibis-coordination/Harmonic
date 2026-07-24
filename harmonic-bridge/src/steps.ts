// Lifecycle steps — user-configured actions that run at a specific point in
// a CLI command's flow. Today: `after_add`, which fires once per agent
// immediately after `harmonic-bridge add` successfully registers the agent
// with Harmonic. The same machinery will serve future lifecycle points
// (after_remove, after_rotate, …) without protocol changes.
//
// Steps let users opt into harness-specific setup (writing a Claude Code
// MCP config, running `codex mcp add`, telling Cursor about the new
// server) without baking any harness knowledge into the daemon's runtime
// path.
//
// Two step forms:
//   { built_in: "claude-code-per-agent-mcp-config" }   // named TypeScript fn
//   { command: "claude mcp add --transport http ..." } // arbitrary shell
//
// Step env mirrors the wake-command env (HARMONIC_BRIDGE_AGENT_NAME, etc.),
// minus HARMONIC_BRIDGE_EVENT_TYPE (no event — this is one-time setup).
// HARMONIC_BRIDGE_TOKEN is the freshly-minted plaintext token; steps like
// `claude mcp add` need it literally to embed in their own config.

import { spawn as spawnProcess } from "node:child_process";
import type { Writable } from "node:stream";
import { writeClaudeMcpConfig } from "./claude-mcp-config.js";
import { applyClaudeCodeHarness } from "./claude-code-harness.js";

export type Step =
  | { readonly kind: "built_in"; readonly name: string }
  | { readonly kind: "command"; readonly command: string };

export interface StepContext {
  readonly agentHandle: string;
  readonly agentDir: string;
  readonly mcpEndpoint: string;
  /** Resolved plaintext token. Steps like `claude mcp add` embed it. */
  readonly token: string;
}

export interface StepOpts {
  /** Where to send the step subprocess's stdout. Defaults to inherit. */
  readonly stdout?: Writable;
  /** Where to send the step subprocess's stderr. Defaults to inherit. */
  readonly stderr?: Writable;
  /** Kill after this many seconds. Defaults to 60. */
  readonly timeoutSeconds?: number;
}

export type StepResult = { readonly ok: true } | { readonly ok: false; readonly error: string };

type BuiltInImpl = (ctx: StepContext) => Promise<void>;

/**
 * Registry of built-in steps. Add a new entry here to ship a new built-in;
 * users opt in by name in their config. Built-ins are globally available
 * across lifecycle points — naming conventions (e.g. `…-mcp-config` reads
 * as "writes a config") signal which phase a given built-in belongs in.
 */
export const BUILT_INS: Readonly<Record<string, BuiltInImpl>> = Object.freeze({
  "claude-code-per-agent-mcp-config": async (ctx) => {
    await writeClaudeMcpConfig({
      agentDir: ctx.agentDir,
      agentHandle: ctx.agentHandle,
      mcpEndpoint: ctx.mcpEndpoint,
    });
  },
  "claude-code-harness": async (ctx) => {
    await applyClaudeCodeHarness({ agentDir: ctx.agentDir });
  },
});

const DEFAULT_TIMEOUT_SECONDS = 60;
const SIGKILL_GRACE_MS = 1000;

export async function runStep(step: Step, ctx: StepContext, opts: StepOpts = {}): Promise<StepResult> {
  if (step.kind === "built_in") {
    const impl = BUILT_INS[step.name];
    if (!impl) {
      return { ok: false, error: `unknown built-in step: ${step.name}` };
    }
    try {
      await impl(ctx);
      return { ok: true };
    } catch (e) {
      return { ok: false, error: e instanceof Error ? e.message : String(e) };
    }
  }
  return runCommandStep(step.command, ctx, opts);
}

/**
 * Run a list of steps sequentially. Continues after failures (so a Claude
 * step failing doesn't prevent a Codex step from running). Returns results
 * in the same order as input. The optional `onResult` callback fires after
 * each step completes — useful for live progress reporting.
 */
export async function runSteps(
  steps: readonly Step[],
  ctx: StepContext,
  opts: StepOpts & { readonly onResult?: (step: Step, result: StepResult) => void } = {},
): Promise<readonly StepResult[]> {
  const results: StepResult[] = [];
  for (const step of steps) {
    const result = await runStep(step, ctx, opts);
    results.push(result);
    opts.onResult?.(step, result);
  }
  return results;
}

/**
 * Resolve the effective `after_add` step list for an agent. The agent's
 * field, if present, fully replaces the daemon's defaults — same shape as
 * `wake_command`. An explicit empty list on the agent ([]) overrides to no
 * steps; an absent field inherits the daemon defaults. The same resolution
 * rule will apply to future lifecycle points (after_remove, etc.).
 */
export function effectiveAfterAdd(
  agentSteps: readonly Step[] | undefined,
  daemonSteps: readonly Step[],
): readonly Step[] {
  return agentSteps ?? daemonSteps;
}

function runCommandStep(command: string, ctx: StepContext, opts: StepOpts): Promise<StepResult> {
  return new Promise((resolve) => {
    const timeoutSeconds = opts.timeoutSeconds ?? DEFAULT_TIMEOUT_SECONDS;
    const env: Record<string, string> = {};
    for (const [k, v] of Object.entries(process.env)) {
      if (typeof v === "string") env[k] = v;
    }
    env["HARMONIC_BRIDGE_AGENT_NAME"] = ctx.agentHandle;
    env["HARMONIC_BRIDGE_AGENT_DIR"] = ctx.agentDir;
    env["HARMONIC_BRIDGE_MCP_ENDPOINT"] = ctx.mcpEndpoint;
    env["HARMONIC_BRIDGE_TOKEN"] = ctx.token;

    const child = spawnProcess("sh", ["-c", command], {
      cwd: ctx.agentDir,
      env,
      stdio: ["ignore", "pipe", "pipe"],
    });

    let timedOut = false;
    const timer = setTimeout(() => {
      timedOut = true;
      child.kill("SIGTERM");
      setTimeout(() => {
        if (!child.killed) child.kill("SIGKILL");
      }, SIGKILL_GRACE_MS);
    }, timeoutSeconds * 1000);

    if (child.stdout) {
      if (opts.stdout) child.stdout.pipe(opts.stdout, { end: false });
      else child.stdout.pipe(process.stdout, { end: false });
    }
    if (child.stderr) {
      if (opts.stderr) child.stderr.pipe(opts.stderr, { end: false });
      else child.stderr.pipe(process.stderr, { end: false });
    }

    child.on("error", (err) => {
      clearTimeout(timer);
      resolve({ ok: false, error: err.message });
    });

    child.on("exit", (code, signal) => {
      clearTimeout(timer);
      if (timedOut) {
        resolve({ ok: false, error: `step command timed out after ${timeoutSeconds}s` });
        return;
      }
      if (code === 0) {
        resolve({ ok: true });
        return;
      }
      const detail = signal ? `killed by ${signal}` : `exit code ${code}`;
      resolve({ ok: false, error: `step command failed (${detail})` });
    });
  });
}
