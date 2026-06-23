import { test } from "node:test";
import assert from "node:assert/strict";
import { existsSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { PassThrough } from "node:stream";
import { runCommand } from "./cli.js";

async function withTempDir<T>(fn: (dir: string) => Promise<T>): Promise<T> {
  const dir = mkdtempSync(path.join(tmpdir(), "harmonic-bridge-cli-"));
  try {
    return await fn(dir);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

function collect(stream: PassThrough): Promise<string> {
  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = [];
    stream.on("data", (c: Buffer) => chunks.push(c));
    stream.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
    stream.on("error", reject);
  });
}

test("runCommand: init writes config files into the given configDir", async () => {
  await withTempDir(async (dir) => {
    const stdout = new PassThrough();
    const stdoutPromise = collect(stdout);
    const code = await runCommand(["init"], { configDir: dir, stdout });
    stdout.end();
    assert.equal(code, 0);
    assert.ok(existsSync(path.join(dir, "config.yml")));
    assert.ok(existsSync(path.join(dir, "harmonic-bridge.service")));
    assert.match(await stdoutPromise, /wrote/);
  });
});

test("runCommand: help prints usage and returns 0", async () => {
  const stdout = new PassThrough();
  const stdoutPromise = collect(stdout);
  const code = await runCommand(["help"], { stdout });
  stdout.end();
  assert.equal(code, 0);
  const out = await stdoutPromise;
  assert.match(out, /Usage: harmonic-bridge/);
  assert.match(out, /init/);
});

test("runCommand: --help is treated like help", async () => {
  const stdout = new PassThrough();
  const stdoutPromise = collect(stdout);
  const code = await runCommand(["--help"], { stdout });
  stdout.end();
  assert.equal(code, 0);
  assert.match(await stdoutPromise, /Usage: harmonic-bridge/);
});

test("runCommand: unknown command returns 64 and writes to stderr", async () => {
  const stdout = new PassThrough();
  const stderr = new PassThrough();
  const stderrPromise = collect(stderr);
  const code = await runCommand(["bogus"], { stdout, stderr });
  stdout.end();
  stderr.end();
  assert.equal(code, 64);
  assert.match(await stderrPromise, /unknown command/);
});

test("runCommand: stub commands return 2 with a not-implemented message", async () => {
  const stdout = new PassThrough();
  const stderr = new PassThrough();
  const stderrPromise = collect(stderr);
  const code = await runCommand(["status"], { stdout, stderr });
  stdout.end();
  stderr.end();
  assert.equal(code, 2);
  assert.match(await stderrPromise, /not implemented/i);
});

test("runCommand: bare invocation fails fast if configDir is missing", async () => {
  const stdout = new PassThrough();
  const stderr = new PassThrough();
  const stderrPromise = collect(stderr);
  const code = await runCommand([], {
    configDir: "/nonexistent/harmonic-bridge-config-dir",
    stdout,
    stderr,
  });
  stdout.end();
  stderr.end();
  assert.equal(code, 1);
  assert.match(await stderrPromise, /failed to start/);
});

// ---------- reload ----------

test("runCommand reload: missing daemon.pid prints a clear error", async () => {
  await withTempDir(async (dir) => {
    const stdout = new PassThrough();
    const stderr = new PassThrough();
    const stderrPromise = collect(stderr);
    const code = await runCommand(["reload"], { configDir: dir, stdout, stderr });
    stdout.end();
    stderr.end();
    assert.equal(code, 1);
    assert.match(await stderrPromise, /no daemon\.pid.*is the daemon running/);
  });
});

test("runCommand reload: malformed daemon.pid prints a clear error", async () => {
  await withTempDir(async (dir) => {
    writeFileSync(path.join(dir, "daemon.pid"), "not-a-number");
    const stdout = new PassThrough();
    const stderr = new PassThrough();
    const stderrPromise = collect(stderr);
    const code = await runCommand(["reload"], { configDir: dir, stdout, stderr });
    stdout.end();
    stderr.end();
    assert.equal(code, 1);
    assert.match(await stderrPromise, /not a valid PID/);
  });
});

test("runCommand reload: stale daemon.pid (process gone) prints a clear error", async () => {
  await withTempDir(async (dir) => {
    // PID that won't exist: 0x7fffffff is well beyond a typical max-pid.
    writeFileSync(path.join(dir, "daemon.pid"), "2147483640");
    const stdout = new PassThrough();
    const stderr = new PassThrough();
    const stderrPromise = collect(stderr);
    const code = await runCommand(["reload"], { configDir: dir, stdout, stderr });
    stdout.end();
    stderr.end();
    assert.equal(code, 1);
    assert.match(await stderrPromise, /no process with PID.*stale/);
  });
});

test("runCommand reload: sends SIGHUP and prints success when the PID exists", async () => {
  await withTempDir(async (dir) => {
    // Stub process.kill so we can verify the call without depending on
    // actual OS signal delivery (which races with node:test's harness
    // teardown when targeting our own PID).
    const calls: Array<[number, NodeJS.Signals | number]> = [];
    const origKill = process.kill;
    process.kill = ((pid: number, signal: NodeJS.Signals | number) => {
      calls.push([pid, signal]);
      return true;
    }) as typeof process.kill;
    try {
      writeFileSync(path.join(dir, "daemon.pid"), "12345");
      const stdout = new PassThrough();
      const stdoutPromise = collect(stdout);
      const code = await runCommand(["reload"], { configDir: dir, stdout });
      stdout.end();
      assert.equal(code, 0);
      assert.deepEqual(calls, [[12345, "SIGHUP"]]);
      assert.match(await stdoutPromise, /SIGHUP sent.*re-reading per-agent configs/);
    } finally {
      process.kill = origKill;
    }
  });
});
