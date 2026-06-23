// Spawn an agent's wake command for one webhook event.
//
// The wake command is an opaque shell pipeline (claude, codex, a Python
// script, whatever). harmonic-bridge just runs it via sh -c with the right env,
// cwd, stdin, and timeout, then reports the outcome. Stdout/stderr stream
// to caller-provided WritableStreams so the daemon can route them to log
// files; if no streams are provided, they pipe through to the daemon's
// own stdout/stderr.

import { spawn as spawnProcess } from "node:child_process";
import type { Writable } from "node:stream";

export interface SpawnArgs {
  /** The shell command line to run. Executed via `sh -c`. */
  readonly command: string;
  readonly cwd: string;
  readonly env: Readonly<Record<string, string>>;
  /** Payload piped to the wake command's stdin. */
  readonly stdin: string;
  /** Kill the process after this many seconds. Omit for no timeout. */
  readonly timeoutSeconds?: number;
  /** Where to send the wake command's stdout. Defaults to inherit. */
  readonly stdout?: Writable;
  /** Where to send the wake command's stderr. Defaults to inherit. */
  readonly stderr?: Writable;
}

export interface SpawnResult {
  readonly exitCode: number | null;
  readonly signal: NodeJS.Signals | null;
  readonly durationMs: number;
  readonly timedOut: boolean;
}

/** Grace period after SIGTERM before escalating to SIGKILL. */
const SIGKILL_GRACE_MS = 1000;

export function spawnWake(args: SpawnArgs): Promise<SpawnResult> {
  return new Promise((resolve, reject) => {
    const start = Date.now();

    const child = spawnProcess("sh", ["-c", args.command], {
      cwd: args.cwd,
      env: { ...args.env },
      stdio: ["pipe", "pipe", "pipe"],
    });

    let timedOut = false;
    let timer: NodeJS.Timeout | undefined;
    let killTimer: NodeJS.Timeout | undefined;

    if (args.timeoutSeconds !== undefined) {
      timer = setTimeout(() => {
        timedOut = true;
        child.kill("SIGTERM");
        // Escalate if the process ignores SIGTERM.
        killTimer = setTimeout(() => {
          if (!child.killed) child.kill("SIGKILL");
        }, SIGKILL_GRACE_MS);
      }, args.timeoutSeconds * 1000);
    }

    // Pipe child stdout/stderr through. With `end: true` on a caller-provided
    // stream, the stream emits 'end' when the child exits — tests rely on
    // that to collect output.
    if (child.stdout) {
      if (args.stdout) child.stdout.pipe(args.stdout, { end: true });
      else child.stdout.pipe(process.stdout, { end: false });
    }
    if (child.stderr) {
      if (args.stderr) child.stderr.pipe(args.stderr, { end: true });
      else child.stderr.pipe(process.stderr, { end: false });
    }

    if (child.stdin) {
      child.stdin.on("error", () => {
        // ignore EPIPE if the child exits before reading stdin
      });
      child.stdin.write(args.stdin);
      child.stdin.end();
    }

    child.on("error", (err) => {
      if (timer) clearTimeout(timer);
      if (killTimer) clearTimeout(killTimer);
      reject(err);
    });

    child.on("exit", (code, signal) => {
      if (timer) clearTimeout(timer);
      if (killTimer) clearTimeout(killTimer);
      resolve({
        exitCode: code,
        signal,
        durationMs: Date.now() - start,
        timedOut,
      });
    });
  });
}
