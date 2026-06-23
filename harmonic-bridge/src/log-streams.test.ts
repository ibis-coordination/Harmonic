import { test } from "node:test";
import assert from "node:assert/strict";
import { existsSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { openAgentLogStreams } from "./log-streams.js";

async function withTempDir<T>(fn: (dir: string) => Promise<T>): Promise<T> {
  const dir = mkdtempSync(path.join(tmpdir(), "harmonic-bridge-logs-"));
  try {
    return await fn(dir);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

test("openAgentLogStreams: creates the agent log directory if missing", async () => {
  await withTempDir(async (logDir) => {
    const expected = path.join(logDir, "agents", "alice");
    assert.equal(existsSync(expected), false);
    const streams = await openAgentLogStreams(logDir, "alice");
    assert.equal(existsSync(expected), true);
    assert.equal(streams.dir, expected);
    await streams.close();
  });
});

test("openAgentLogStreams: stdout writes land in stdout.log", async () => {
  await withTempDir(async (logDir) => {
    const streams = await openAgentLogStreams(logDir, "alice");
    streams.stdout.write("first line\n");
    streams.stdout.write("second line\n");
    await streams.close();
    const contents = readFileSync(path.join(logDir, "agents", "alice", "stdout.log"), "utf8");
    assert.equal(contents, "first line\nsecond line\n");
  });
});

test("openAgentLogStreams: stderr writes land in stderr.log", async () => {
  await withTempDir(async (logDir) => {
    const streams = await openAgentLogStreams(logDir, "alice");
    streams.stderr.write("oops\n");
    await streams.close();
    const contents = readFileSync(path.join(logDir, "agents", "alice", "stderr.log"), "utf8");
    assert.equal(contents, "oops\n");
  });
});

test("openAgentLogStreams: appends across re-opens (doesn't truncate)", async () => {
  await withTempDir(async (logDir) => {
    const first = await openAgentLogStreams(logDir, "alice");
    first.stdout.write("wake-1\n");
    await first.close();

    const second = await openAgentLogStreams(logDir, "alice");
    second.stdout.write("wake-2\n");
    await second.close();

    const contents = readFileSync(path.join(logDir, "agents", "alice", "stdout.log"), "utf8");
    assert.equal(contents, "wake-1\nwake-2\n");
  });
});

test("openAgentLogStreams: error events on streams are swallowed (don't crash the daemon)", async () => {
  await withTempDir(async (logDir) => {
    const streams = await openAgentLogStreams(logDir, "alice");
    // Without an error listener attached, EventEmitter.emit("error", ...)
    // throws synchronously. With one, it returns true. This catches the
    // regression where logs would crash the daemon on EACCES/ENOSPC.
    assert.doesNotThrow(() => streams.stdout.emit("error", new Error("simulated write fail")));
    assert.doesNotThrow(() => streams.stderr.emit("error", new Error("simulated write fail")));
    await streams.close();
  });
});

test("openAgentLogStreams: different agents get separate dirs and files", async () => {
  await withTempDir(async (logDir) => {
    const a = await openAgentLogStreams(logDir, "alice");
    const b = await openAgentLogStreams(logDir, "bob");
    a.stdout.write("alice\n");
    b.stdout.write("bob\n");
    await a.close();
    await b.close();
    assert.equal(readFileSync(path.join(logDir, "agents", "alice", "stdout.log"), "utf8"), "alice\n");
    assert.equal(readFileSync(path.join(logDir, "agents", "bob", "stdout.log"), "utf8"), "bob\n");
  });
});
