import { test } from "node:test";
import assert from "node:assert/strict";
import { PassThrough } from "node:stream";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { spawnWake } from "./spawn.js";

function collect(stream: PassThrough): Promise<string> {
  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = [];
    stream.on("data", (c: Buffer) => chunks.push(c));
    stream.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
    stream.on("error", reject);
  });
}

test("spawnWake: zero exit on success", async () => {
  const result = await spawnWake({
    command: "true",
    cwd: process.cwd(),
    env: {},
    stdin: "",
  });
  assert.equal(result.exitCode, 0);
  assert.equal(result.signal, null);
  assert.equal(result.timedOut, false);
});

test("spawnWake: non-zero exit code surfaces", async () => {
  const result = await spawnWake({
    command: "exit 5",
    cwd: process.cwd(),
    env: {},
    stdin: "",
  });
  assert.equal(result.exitCode, 5);
  assert.equal(result.timedOut, false);
});

test("spawnWake: stdin is piped to the wake command", async () => {
  const stdout = new PassThrough();
  const collectPromise = collect(stdout);
  const result = await spawnWake({
    command: "cat",
    cwd: process.cwd(),
    env: {},
    stdin: "hello from harmonic-bridge",
    stdout,
  });
  assert.equal(result.exitCode, 0);
  assert.equal(await collectPromise, "hello from harmonic-bridge");
});

test("spawnWake: stdout is streamed to the provided writable", async () => {
  const stdout = new PassThrough();
  const collectPromise = collect(stdout);
  await spawnWake({
    command: "printf 'one\\ntwo\\n'",
    cwd: process.cwd(),
    env: {},
    stdin: "",
    stdout,
  });
  assert.equal(await collectPromise, "one\ntwo\n");
});

test("spawnWake: env vars reach the wake command", async () => {
  const stdout = new PassThrough();
  const collectPromise = collect(stdout);
  await spawnWake({
    command: "printf '%s' \"$HARMONIC_BRIDGE_TEST_VAR\"",
    cwd: process.cwd(),
    env: { HARMONIC_BRIDGE_TEST_VAR: "value-from-config", PATH: process.env["PATH"] ?? "" },
    stdin: "",
    stdout,
  });
  assert.equal(await collectPromise, "value-from-config");
});

test("spawnWake: cwd is honored", async () => {
  const dir = mkdtempSync(path.join(tmpdir(), "harmonic-bridge-spawn-"));
  try {
    const stdout = new PassThrough();
    const collectPromise = collect(stdout);
    await spawnWake({
      command: "pwd",
      cwd: dir,
      env: { PATH: process.env["PATH"] ?? "" },
      stdin: "",
      stdout,
    });
    // macOS routes /var to /private/var; both forms are valid for the same dir.
    const actual = (await collectPromise).trim();
    assert.ok(actual === dir || actual === path.join("/private", dir),
              `expected pwd ${dir} or /private prefix, got ${actual}`);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("spawnWake: timeout kills a long-running process", async () => {
  const start = Date.now();
  const result = await spawnWake({
    command: "sleep 10",
    cwd: process.cwd(),
    env: { PATH: process.env["PATH"] ?? "" },
    stdin: "",
    timeoutSeconds: 1,
  });
  const elapsed = Date.now() - start;
  assert.equal(result.timedOut, true);
  assert.ok(elapsed < 3000, `expected to exit within ~1s, took ${elapsed}ms`);
  assert.notEqual(result.signal, null);
});

test("spawnWake: stderr is streamed to the provided writable", async () => {
  const stderr = new PassThrough();
  const collectPromise = collect(stderr);
  await spawnWake({
    command: "printf 'error info' >&2",
    cwd: process.cwd(),
    env: { PATH: process.env["PATH"] ?? "" },
    stdin: "",
    stderr,
  });
  assert.equal(await collectPromise, "error info");
});

test("spawnWake: durationMs is reasonable", async () => {
  const result = await spawnWake({
    command: "true",
    cwd: process.cwd(),
    env: {},
    stdin: "",
  });
  assert.ok(result.durationMs >= 0);
  assert.ok(result.durationMs < 5000, `expected fast exit, got ${result.durationMs}ms`);
});
