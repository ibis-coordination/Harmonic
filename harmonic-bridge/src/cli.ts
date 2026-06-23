// CLI dispatch for harmonic-bridge. Imported by ./bin.ts (the actual entry point)
// and by tests. This file has no side effects on import — runCommand must
// be invoked explicitly.

import { homedir } from "node:os";
import path from "node:path";
import type { Writable } from "node:stream";
import { initConfig } from "./init.js";
import { startDaemon } from "./daemon.js";

export interface CliOpts {
  /** Base config directory. Defaults to ~/.harmonic-bridge. */
  readonly configDir?: string;
  readonly stdout?: Writable;
  readonly stderr?: Writable;
}

const STUB_COMMANDS: ReadonlySet<string> = new Set(["status", "reload", "logs", "test"]);

/**
 * Run the CLI with the given arguments. Returns the exit code.
 * - `[]` (no args) starts the daemon and runs until SIGINT/SIGTERM.
 * - `["init"]` writes the config skeleton.
 * - `["help"]` / `["--help"]` / `["-h"]` prints usage.
 * - Other known commands print "not yet implemented" and return non-zero.
 */
export async function runCommand(args: readonly string[], opts: CliOpts = {}): Promise<number> {
  const stdout = opts.stdout ?? process.stdout;
  const stderr = opts.stderr ?? process.stderr;
  const configDir = opts.configDir ?? path.join(homedir(), ".harmonic-bridge");
  const command = args[0];

  if (command === "help" || command === "--help" || command === "-h") {
    printUsage(stdout);
    return 0;
  }

  if (command === undefined) {
    return await runDaemon(configDir, stdout, stderr);
  }

  if (command === "init") {
    const result = await initConfig(configDir);
    for (const p of result.written) stdout.write(`wrote     ${p}\n`);
    for (const p of result.skipped) stdout.write(`exists    ${p}\n`);
    stdout.write(`\nConfig directory: ${configDir}\n`);
    return 0;
  }

  if (STUB_COMMANDS.has(command)) {
    stderr.write(`harmonic-bridge: "${command}" is not implemented yet in v0.1\n`);
    return 2;
  }

  stderr.write(`harmonic-bridge: unknown command "${command}"\n`);
  printUsage(stderr);
  return 64;
}

async function runDaemon(configDir: string, stdout: Writable, stderr: Writable): Promise<number> {
  let daemon;
  try {
    daemon = await startDaemon({ configDir });
  } catch (e) {
    stderr.write(`harmonic-bridge: failed to start — ${e instanceof Error ? e.message : String(e)}\n`);
    return 1;
  }
  stdout.write(`harmonic-bridge listening on port ${daemon.port}\n`);

  await new Promise<void>((resolve) => {
    const stop = (signal: NodeJS.Signals) => {
      stdout.write(`harmonic-bridge: ${signal} received, draining\n`);
      resolve();
      process.off("SIGTERM", onTerm);
      process.off("SIGINT", onInt);
    };
    const onTerm = () => stop("SIGTERM");
    const onInt = () => stop("SIGINT");
    process.once("SIGTERM", onTerm);
    process.once("SIGINT", onInt);
  });

  await daemon.stop();
  stdout.write(`harmonic-bridge stopped\n`);
  return 0;
}

function printUsage(out: Writable): void {
  out.write(`Usage: harmonic-bridge [command]

Without a command, starts the daemon (reads ~/.harmonic-bridge/config.yml and
~/.harmonic-bridge/agents/*/harmonic-bridge.yml). Stays running until SIGTERM/SIGINT.

Commands:
  init            Write ~/.harmonic-bridge/config.yml and a systemd unit template.
  help            Show this help.

Planned (not in v0.1):
  status          Show daemon + per-agent state.
  reload          Re-read configs without dropping in-flight wakes.
  logs <agent>    Tail an agent's wake logs.
  test <agent>    Send a synthetic event to the wake command.
`);
}

