// Per-agent log file streams.
//
// Wakes for a given agent append to <logDir>/agents/<handle>/stdout.log
// and stderr.log. The daemon opens fresh streams per wake (so a long-lived
// daemon doesn't accumulate open file handles) and closes them after the
// wake exits. Files are append-mode so historical wakes are preserved and
// `harmonic-bridge logs <agent>` (future) can tail them.

import { createWriteStream, WriteStream } from "node:fs";
import { promises as fs } from "node:fs";
import path from "node:path";

export interface AgentLogStreams {
  readonly stdout: WriteStream;
  readonly stderr: WriteStream;
  readonly dir: string;
  close(): Promise<void>;
}

export async function openAgentLogStreams(logDir: string, agentHandle: string): Promise<AgentLogStreams> {
  const dir = path.join(logDir, "agents", agentHandle);
  await fs.mkdir(dir, { recursive: true });

  // "a" = append, create if missing.
  const stdout = createWriteStream(path.join(dir, "stdout.log"), { flags: "a" });
  const stderr = createWriteStream(path.join(dir, "stderr.log"), { flags: "a" });

  // Attach error handlers so a write failure (disk full, ENOSPC, EACCES on
  // the log file, etc.) doesn't crash the daemon as an unhandled 'error'
  // event. Logs are best-effort — we'd rather lose the log line than the
  // wake. Write a single notice to stderr so failures aren't silent.
  attachErrorHandler(stdout, path.join(dir, "stdout.log"));
  attachErrorHandler(stderr, path.join(dir, "stderr.log"));

  return { stdout, stderr, dir, close: () => closeBoth(stdout, stderr) };
}

function attachErrorHandler(stream: WriteStream, filePath: string): void {
  stream.on("error", (err) => {
    process.stderr.write(`harmonic-bridge: log write failed for ${filePath}: ${err.message}\n`);
  });
}

function closeBoth(a: WriteStream, b: WriteStream): Promise<void> {
  return Promise.all([endStream(a), endStream(b)]).then(() => undefined);
}

function endStream(s: WriteStream): Promise<void> {
  return new Promise((resolve) => {
    s.end(() => resolve());
  });
}
