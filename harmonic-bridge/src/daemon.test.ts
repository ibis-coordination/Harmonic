import { test, after } from "node:test";
import assert from "node:assert/strict";
import { createHmac } from "node:crypto";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { startDaemon, type RunningDaemon } from "./daemon.js";

const HOST = "127.0.0.1";
const TS = Math.floor(Date.now() / 1000);

function sign(body: string, ts: number, secret: string): string {
  const hex = createHmac("sha256", secret).update(`${ts}.${body}`).digest("hex");
  return `sha256=${hex}`;
}

interface Fixture {
  configDir: string;
  outputFile: string;
  envDumpFile: string;
  token: string;
  webhookSecret: string;
}

function makeFixture(opts?: { events?: string[] }): Fixture {
  const configDir = mkdtempSync(path.join(tmpdir(), "harmonic-bridge-daemon-"));
  const secretsDir = path.join(configDir, "secrets");
  const agentDir = path.join(configDir, "agents", "alice");
  mkdirSync(secretsDir, { recursive: true });
  mkdirSync(agentDir, { recursive: true });

  const token = "tok-" + Math.random().toString(36).slice(2);
  const webhookSecret = "ws-" + Math.random().toString(36).slice(2);
  writeFileSync(path.join(secretsDir, "token"), token);
  writeFileSync(path.join(secretsDir, "webhook-secret"), webhookSecret);

  const outputFile = path.join(configDir, "wake-output.txt");
  const envDumpFile = path.join(configDir, "wake-env.txt");

  // Config-file port is a placeholder — tests pass listenOverride { port: 0 }
  // to actually bind on an ephemeral port. The parser validates 1..65535.
  writeFileSync(path.join(configDir, "config.yml"), `
listen: 127.0.0.1:8080
log_dir: ${path.join(configDir, "logs")}
`);

  const wakeCommand = [
    `cat > ${outputFile}`,
    `printf 'agent=%s\\nevent=%s\\nendpoint=%s\\ntoken=%s\\n' ` +
      `"$HARMONIC_BRIDGE_AGENT_NAME" "$HARMONIC_BRIDGE_EVENT_TYPE" ` +
      `"$HARMONIC_BRIDGE_MCP_ENDPOINT" "$HARMONIC_BRIDGE_TOKEN" > ${envDumpFile}`,
  ].join(" && ");

  const eventsBlock = opts?.events
    ? "events:\n" + opts.events.map((e) => `  - ${e}`).join("\n") + "\n"
    : "";

  writeFileSync(path.join(agentDir, "harmonic-bridge.yml"), `
harmonic_mcp_endpoint: https://app.harmonic.example/mcp
harmonic_token: file://${path.join(secretsDir, "token")}
webhook_secret: file://${path.join(secretsDir, "webhook-secret")}
working_dir: ${configDir}
wake_command: |
  ${wakeCommand}
${eventsBlock}`);

  return { configDir, outputFile, envDumpFile, token, webhookSecret };
}

const cleanups: Array<() => Promise<void> | void> = [];

after(async () => {
  for (const c of cleanups) await c();
});

async function startWithFixture(f: Fixture): Promise<RunningDaemon> {
  const d = await startDaemon({
    configDir: f.configDir,
    listenOverride: { host: HOST, port: 0 },
  });
  cleanups.push(async () => {
    await d.stop();
    rmSync(f.configDir, { recursive: true, force: true });
  });
  return d;
}

/**
 * Wait for a file to exist AND have non-zero content. The wake command does
 * `cat > $file && printf …`, and `cat` opens the file (creating it) before
 * it has finished consuming stdin — so existsSync alone races against the
 * stdin write. Polling for size > 0 closes that gap.
 */
async function waitForFile(filePath: string, timeoutMs = 3000): Promise<void> {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    if (existsSync(filePath) && statSync(filePath).size > 0) return;
    await new Promise((r) => setTimeout(r, 25));
  }
  throw new Error(`file not populated within ${timeoutMs}ms: ${filePath}`);
}

test("daemon: signed POST triggers the agent's wake command with the payload on stdin", async () => {
  const f = makeFixture();
  const d = await startWithFixture(f);
  const body = '{"event":"notifications.delivered","data":{"x":1}}';
  const res = await fetch(`http://${HOST}:${d.port}/webhook/alice`, {
    method: "POST",
    headers: {
      "X-Harmonic-Signature": sign(body, TS, f.webhookSecret),
      "X-Harmonic-Timestamp": String(TS),
      "X-Harmonic-Event": "notifications.delivered",
    },
    body,
  });
  assert.equal(res.status, 204);
  await waitForFile(f.outputFile);
  assert.equal(readFileSync(f.outputFile, "utf8"), body);
});

test("daemon: wake command sees HARMONIC_BRIDGE_* env vars and resolved token", async () => {
  const f = makeFixture();
  const d = await startWithFixture(f);
  const body = "{}";
  await fetch(`http://${HOST}:${d.port}/webhook/alice`, {
    method: "POST",
    headers: {
      "X-Harmonic-Signature": sign(body, TS, f.webhookSecret),
      "X-Harmonic-Timestamp": String(TS),
      "X-Harmonic-Event": "comment.created",
    },
    body,
  });
  await waitForFile(f.envDumpFile);
  const env = readFileSync(f.envDumpFile, "utf8");
  assert.match(env, /agent=alice/);
  assert.match(env, /event=comment\.created/);
  assert.match(env, /endpoint=https:\/\/app\.harmonic\.example\/mcp/);
  assert.match(env, new RegExp(`token=${f.token}`));
});

test("daemon: wake command inherits HOME and other env vars from the daemon", async () => {
  // Wake harnesses like Claude Code read ~/.claude.json — without HOME
  // they can't find their MCP config. The daemon's subprocess env should
  // inherit process.env so common tooling works out of the box.
  const f = makeFixture();
  const agentYmlPath = path.join(f.configDir, "agents", "alice", "harmonic-bridge.yml");
  const yml = readFileSync(agentYmlPath, "utf8").replace(
    /wake_command: \|[\s\S]*$/,
    `wake_command: |
  printf 'HOME=%s\\n' "$HOME" > ${f.envDumpFile}
`,
  );
  writeFileSync(agentYmlPath, yml);

  const d = await startWithFixture(f);
  const body = "{}";
  await fetch(`http://${HOST}:${d.port}/webhook/alice`, {
    method: "POST",
    headers: {
      "X-Harmonic-Signature": sign(body, TS, f.webhookSecret),
      "X-Harmonic-Timestamp": String(TS),
    },
    body,
  });
  await waitForFile(f.envDumpFile);
  const env = readFileSync(f.envDumpFile, "utf8");
  assert.match(env, new RegExp(`HOME=${process.env["HOME"]}`));
});

test("daemon: wake command sees HARMONIC_BRIDGE_AGENT_DIR pointing at the per-agent config dir", async () => {
  const f = makeFixture();
  const agentYmlPath = path.join(f.configDir, "agents", "alice", "harmonic-bridge.yml");
  const yml = readFileSync(agentYmlPath, "utf8").replace(
    /wake_command: \|[\s\S]*$/,
    `wake_command: |
  printf '%s' "$HARMONIC_BRIDGE_AGENT_DIR" > ${f.envDumpFile}
`,
  );
  writeFileSync(agentYmlPath, yml);

  const d = await startWithFixture(f);
  const body = "{}";
  await fetch(`http://${HOST}:${d.port}/webhook/alice`, {
    method: "POST",
    headers: {
      "X-Harmonic-Signature": sign(body, TS, f.webhookSecret),
      "X-Harmonic-Timestamp": String(TS),
    },
    body,
  });
  await waitForFile(f.envDumpFile);
  assert.equal(
    readFileSync(f.envDumpFile, "utf8"),
    path.join(f.configDir, "agents", "alice"),
  );
});

test("daemon: events filter drops events not in the agent's list", async () => {
  const f = makeFixture({ events: ["notifications.delivered"] });
  const d = await startWithFixture(f);
  const body = "{}";
  const res = await fetch(`http://${HOST}:${d.port}/webhook/alice`, {
    method: "POST",
    headers: {
      "X-Harmonic-Signature": sign(body, TS, f.webhookSecret),
      "X-Harmonic-Timestamp": String(TS),
      "X-Harmonic-Event": "comment.created", // not in events list
    },
    body,
  });
  // Server still returns 204 — filtering is a wake-time decision, not a
  // signature-level rejection. Webhook delivered, just no wake.
  assert.equal(res.status, 204);
  // Give the dispatch a moment; the wake should NOT run.
  await new Promise((r) => setTimeout(r, 200));
  assert.equal(existsSync(f.outputFile), false, "wake should not have run for filtered event");
});

test("daemon: unknown agent returns 404", async () => {
  const f = makeFixture();
  const d = await startWithFixture(f);
  const res = await fetch(`http://${HOST}:${d.port}/webhook/no-such-agent`, {
    method: "POST",
    headers: {
      "X-Harmonic-Signature": "sha256=" + "0".repeat(64),
      "X-Harmonic-Timestamp": String(TS),
    },
    body: "{}",
  });
  assert.equal(res.status, 404);
});

test("daemon: bad signature returns 401 and no wake", async () => {
  const f = makeFixture();
  const d = await startWithFixture(f);
  const res = await fetch(`http://${HOST}:${d.port}/webhook/alice`, {
    method: "POST",
    headers: {
      "X-Harmonic-Signature": "sha256=" + "0".repeat(64),
      "X-Harmonic-Timestamp": String(TS),
    },
    body: "{}",
  });
  assert.equal(res.status, 401);
  await new Promise((r) => setTimeout(r, 200));
  assert.equal(existsSync(f.outputFile), false);
});

test("daemon: wake stdout/stderr land in per-agent log files", async () => {
  const f = makeFixture();
  // Override the wake command to write to stdout AND stderr so we can check both.
  const agentYmlPath = path.join(f.configDir, "agents", "alice", "harmonic-bridge.yml");
  let yml = readFileSync(agentYmlPath, "utf8");
  yml = yml.replace(/wake_command: \|[\s\S]*$/, `wake_command: |
  echo "out-marker" && echo "err-marker" >&2
`);
  writeFileSync(agentYmlPath, yml);

  const d = await startWithFixture(f);
  const body = "{}";
  await fetch(`http://${HOST}:${d.port}/webhook/alice`, {
    method: "POST",
    headers: {
      "X-Harmonic-Signature": sign(body, TS, f.webhookSecret),
      "X-Harmonic-Timestamp": String(TS),
    },
    body,
  });

  const stdoutLog = path.join(f.configDir, "logs", "agents", "alice", "stdout.log");
  const stderrLog = path.join(f.configDir, "logs", "agents", "alice", "stderr.log");
  await waitForFile(stdoutLog);
  await waitForFile(stderrLog);
  assert.match(readFileSync(stdoutLog, "utf8"), /out-marker/);
  assert.match(readFileSync(stderrLog, "utf8"), /err-marker/);
});

test("daemon: stop() drains in-flight wakes and closes the server", async () => {
  const f = makeFixture();
  const d = await startWithFixture(f);
  const body = "drain-test";
  await fetch(`http://${HOST}:${d.port}/webhook/alice`, {
    method: "POST",
    headers: {
      "X-Harmonic-Signature": sign(body, TS, f.webhookSecret),
      "X-Harmonic-Timestamp": String(TS),
    },
    body,
  });
  await d.stop();
  // After stop, the wake should have completed (drained) — output file exists.
  assert.equal(readFileSync(f.outputFile, "utf8"), body);
  // And the port is no longer listening.
  await assert.rejects(() => fetch(`http://${HOST}:${d.port}/webhook/alice`, { method: "POST", body: "{}" }));
});

// ---------- reload ----------

test("daemon.reload(): picks up an agent added to disk after startup", async () => {
  const f = makeFixture();
  const d = await startWithFixture(f);

  // POST to a not-yet-configured agent returns 404 (no entry in the map).
  let res = await fetch(`http://${HOST}:${d.port}/webhook/bob`, {
    method: "POST",
    headers: {
      "X-Harmonic-Signature": "sha256=" + "0".repeat(64),
      "X-Harmonic-Timestamp": String(TS),
    },
    body: "{}",
  });
  assert.equal(res.status, 404);

  // Drop bob's config + secret on disk, then reload.
  const bobDir = path.join(f.configDir, "agents", "bob");
  mkdirSync(bobDir, { recursive: true });
  const bobSecret = "ws-bob-" + Math.random().toString(36).slice(2);
  const bobToken = "tok-bob-" + Math.random().toString(36).slice(2);
  const bobSecretPath = path.join(f.configDir, "secrets", "bob-webhook");
  const bobTokenPath = path.join(f.configDir, "secrets", "bob-token");
  writeFileSync(bobSecretPath, bobSecret);
  writeFileSync(bobTokenPath, bobToken);
  const bobOutput = path.join(f.configDir, "bob-output.txt");
  writeFileSync(path.join(bobDir, "harmonic-bridge.yml"), `
harmonic_mcp_endpoint: https://app.harmonic.example/mcp
harmonic_token: file://${bobTokenPath}
webhook_secret: file://${bobSecretPath}
working_dir: ${f.configDir}
wake_command: |
  cat > ${bobOutput}
`);

  await d.reload();

  // Now bob's webhook accepts and dispatches.
  const body = "hello-bob";
  res = await fetch(`http://${HOST}:${d.port}/webhook/bob`, {
    method: "POST",
    headers: {
      "X-Harmonic-Signature": sign(body, TS, bobSecret),
      "X-Harmonic-Timestamp": String(TS),
    },
    body,
  });
  assert.equal(res.status, 204);
  await waitForFile(bobOutput);
  assert.equal(readFileSync(bobOutput, "utf8"), body);
});

test("daemon.reload(): drops an agent whose config directory was removed", async () => {
  const f = makeFixture();
  const d = await startWithFixture(f);

  // alice exists initially.
  let res = await fetch(`http://${HOST}:${d.port}/webhook/alice`, {
    method: "POST",
    headers: {
      "X-Harmonic-Signature": sign("{}", TS, f.webhookSecret),
      "X-Harmonic-Timestamp": String(TS),
    },
    body: "{}",
  });
  assert.equal(res.status, 204);

  // Remove alice's dir + reload.
  rmSync(path.join(f.configDir, "agents", "alice"), { recursive: true });
  await d.reload();

  // alice is now unknown.
  res = await fetch(`http://${HOST}:${d.port}/webhook/alice`, {
    method: "POST",
    headers: {
      "X-Harmonic-Signature": sign("{}", TS, f.webhookSecret),
      "X-Harmonic-Timestamp": String(TS),
    },
    body: "{}",
  });
  assert.equal(res.status, 404);
});

test("daemon.reload(): a broken per-agent config does not poison the rest", async () => {
  const f = makeFixture();
  const d = await startWithFixture(f);

  // Add a broken agent: missing wake_command.
  const brokenDir = path.join(f.configDir, "agents", "broken");
  mkdirSync(brokenDir, { recursive: true });
  writeFileSync(path.join(brokenDir, "harmonic-bridge.yml"), `
harmonic_mcp_endpoint: https://app.harmonic.example/mcp
harmonic_token: file:///dev/null
webhook_secret: file:///dev/null
working_dir: /tmp
`);

  // Capture the warning written to stderr.
  const origWrite = process.stderr.write.bind(process.stderr);
  const captured: string[] = [];
  process.stderr.write = ((chunk: string | Uint8Array) => {
    captured.push(typeof chunk === "string" ? chunk : Buffer.from(chunk).toString());
    return true;
  }) as typeof process.stderr.write;
  try {
    await d.reload();
  } finally {
    process.stderr.write = origWrite;
  }
  assert.ok(captured.some((s) => /broken/.test(s) && /wake_command/.test(s)),
    `expected stderr to warn about the broken agent; got: ${captured.join("")}`);

  // alice still works.
  const res = await fetch(`http://${HOST}:${d.port}/webhook/alice`, {
    method: "POST",
    headers: {
      "X-Harmonic-Signature": sign("{}", TS, f.webhookSecret),
      "X-Harmonic-Timestamp": String(TS),
    },
    body: "{}",
  });
  assert.equal(res.status, 204);
});

// ---------- PID file ----------

test("daemon: installSignalHandlers writes daemon.pid on start and removes it on stop", async () => {
  const f = makeFixture();
  const d = await startDaemon({
    configDir: f.configDir,
    listenOverride: { host: HOST, port: 0 },
    installSignalHandlers: true,
  });
  const pidFilePath = path.join(f.configDir, "daemon.pid");
  try {
    assert.ok(existsSync(pidFilePath), "PID file should be written on start");
    assert.equal(Number(readFileSync(pidFilePath, "utf8")), process.pid);
  } finally {
    await d.stop();
    rmSync(f.configDir, { recursive: true, force: true });
  }
  assert.equal(existsSync(pidFilePath), false, "PID file should be removed on stop");
});

test("daemon: without installSignalHandlers, no PID file is created", async () => {
  const f = makeFixture();
  const d = await startWithFixture(f);
  void d;
  assert.equal(existsSync(path.join(f.configDir, "daemon.pid")), false);
});

test("daemon: logs wake spawn and exit code per wake", async () => {
  const f = makeFixture();
  // Wake command that consumes stdin then fails with a distinctive code.
  writeFileSync(path.join(f.configDir, "agents", "alice", "harmonic-bridge.yml"), `
harmonic_mcp_endpoint: https://app.harmonic.example/mcp
harmonic_token: file://${path.join(f.configDir, "secrets", "token")}
webhook_secret: file://${path.join(f.configDir, "secrets", "webhook-secret")}
working_dir: ${f.configDir}
wake_command: |
  cat > /dev/null; exit 3
`);

  const logChunks: string[] = [];
  const { Writable } = await import("node:stream");
  const logStream = new Writable({
    write(chunk: Buffer, _enc: string, cb: () => void) {
      logChunks.push(chunk.toString());
      cb();
    },
  });

  const d = await startDaemon({
    configDir: f.configDir,
    listenOverride: { host: HOST, port: 0 },
    logStream,
  });
  cleanups.push(async () => {
    await d.stop();
    rmSync(f.configDir, { recursive: true, force: true });
  });

  const body = "{}";
  const res = await fetch(`http://${HOST}:${d.port}/webhook/alice`, {
    method: "POST",
    headers: {
      "X-Harmonic-Signature": sign(body, TS, f.webhookSecret),
      "X-Harmonic-Timestamp": String(TS),
      "X-Harmonic-Event": "notifications.delivered",
    },
    body,
  });
  assert.equal(res.status, 204);

  const deadline = Date.now() + 3000;
  while (!logChunks.join("").includes("exit=3") && Date.now() < deadline) {
    await new Promise((r) => setTimeout(r, 25));
  }
  const log = logChunks.join("");
  assert.match(log, /wake alice event=notifications\.delivered spawned/);
  assert.match(log, /wake alice exit=3 duration_ms=\d+/);
});

test("daemon: warns when hold-awake is on and an agent has no timeout_seconds", async () => {
  const f = makeFixture();
  writeFileSync(path.join(f.configDir, "config.yml"), `
listen: 127.0.0.1:8080
log_dir: ${path.join(f.configDir, "logs")}
public_url: https://bridge.example.com
hold_awake_during_wake: true
`);
  // makeFixture's agent config has no timeout_seconds.

  const logChunks: string[] = [];
  const { Writable } = await import("node:stream");
  const logStream = new Writable({
    write(chunk: Buffer, _enc: string, cb: () => void) {
      logChunks.push(chunk.toString());
      cb();
    },
  });

  const d = await startDaemon({ configDir: f.configDir, listenOverride: { host: HOST, port: 0 }, logStream });
  cleanups.push(async () => {
    await d.stop();
    rmSync(f.configDir, { recursive: true, force: true });
  });

  const log = logChunks.join("");
  assert.match(log, /warning: agent "alice" has no timeout_seconds/);
  assert.match(log, /hold_awake_during_wake/);
});

test("daemon: no timeout warning when the agent has timeout_seconds or hold-awake is off", async () => {
  // Case 1: hold-awake on, agent HAS a timeout.
  const f1 = makeFixture();
  writeFileSync(path.join(f1.configDir, "config.yml"), `
listen: 127.0.0.1:8080
log_dir: ${path.join(f1.configDir, "logs")}
public_url: https://bridge.example.com
hold_awake_during_wake: true
`);
  const agentYml = readFileSync(path.join(f1.configDir, "agents", "alice", "harmonic-bridge.yml"), "utf8");
  writeFileSync(path.join(f1.configDir, "agents", "alice", "harmonic-bridge.yml"), agentYml + "\ntimeout_seconds: 900\n");

  // Case 2: hold-awake off, agent has no timeout.
  const f2 = makeFixture();

  const { Writable } = await import("node:stream");
  for (const f of [f1, f2]) {
    const logChunks: string[] = [];
    const logStream = new Writable({
      write(chunk: Buffer, _enc: string, cb: () => void) {
        logChunks.push(chunk.toString());
        cb();
      },
    });
    const d = await startDaemon({ configDir: f.configDir, listenOverride: { host: HOST, port: 0 }, logStream });
    cleanups.push(async () => {
      await d.stop();
      rmSync(f.configDir, { recursive: true, force: true });
    });
    assert.doesNotMatch(logChunks.join(""), /has no timeout_seconds/);
  }
});

test("daemon: hold_awake_during_wake holds a connection to public_url for the duration of the wake", async () => {
  // Stub playing the role of the platform edge: records opens/closes of
  // held connections and streams a heartbeat like the real /hold route.
  const { createServer } = await import("node:http");
  let opens = 0;
  let closes = 0;
  const edge = createServer((req, res) => {
    opens += 1;
    res.writeHead(200, { "Content-Type": "text/plain" });
    const beat = setInterval(() => res.write("h\n"), 10);
    res.on("close", () => {
      clearInterval(beat);
      closes += 1;
    });
  });
  await new Promise<void>((resolve) => edge.listen(0, HOST, resolve));
  const edgeAddress = edge.address();
  const edgePort = typeof edgeAddress === "object" && edgeAddress ? edgeAddress.port : 0;
  cleanups.push(async () => new Promise<void>((resolve) => edge.close(() => resolve())));

  const f = makeFixture();
  // Rewrite daemon config with the hold flag and the stub edge as public_url,
  // and slow the wake down so the hold window is observable.
  writeFileSync(path.join(f.configDir, "config.yml"), `
listen: 127.0.0.1:8080
log_dir: ${path.join(f.configDir, "logs")}
public_url: http://${HOST}:${edgePort}
hold_awake_during_wake: true
`);
  writeFileSync(path.join(f.configDir, "agents", "alice", "harmonic-bridge.yml"), `
harmonic_mcp_endpoint: https://app.harmonic.example/mcp
harmonic_token: file://${path.join(f.configDir, "secrets", "token")}
webhook_secret: file://${path.join(f.configDir, "secrets", "webhook-secret")}
working_dir: ${f.configDir}
wake_command: |
  sleep 0.5 && echo done > ${f.outputFile}
`);

  const d = await startDaemon({
    configDir: f.configDir,
    listenOverride: { host: HOST, port: 0 },
    holdOverrides: { primeGraceMs: 200 },
  });
  cleanups.push(async () => {
    await d.stop();
    rmSync(f.configDir, { recursive: true, force: true });
  });
  const body = "{}";
  const res = await fetch(`http://${HOST}:${d.port}/webhook/alice`, {
    method: "POST",
    headers: {
      "X-Harmonic-Signature": sign(body, TS, f.webhookSecret),
      "X-Harmonic-Timestamp": String(TS),
      "X-Harmonic-Event": "notifications.delivered",
    },
    body,
  });
  assert.equal(res.status, 204);

  // The hold connection must open while the wake is still running (well
  // before the 0.5s sleep finishes).
  const holdOpenDeadline = Date.now() + 400;
  while (opens === 0 && Date.now() < holdOpenDeadline) {
    await new Promise((r) => setTimeout(r, 10));
  }
  assert.equal(opens, 1, "hold connection should open during the wake");
  assert.equal(existsSync(f.outputFile), false, "wake should still be in flight when the hold opens");

  await waitForFile(f.outputFile);
  // After the wake finishes, the hold should let go.
  const holdCloseDeadline = Date.now() + 2000;
  while (closes < opens && Date.now() < holdCloseDeadline) {
    await new Promise((r) => setTimeout(r, 10));
  }
  assert.equal(closes, opens, "hold connection should close once the wake completes");
});
