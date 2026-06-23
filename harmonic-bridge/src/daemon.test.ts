import { test, after } from "node:test";
import assert from "node:assert/strict";
import { createHmac } from "node:crypto";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync, existsSync } from "node:fs";
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

/** Wait for a file to exist (the spawn is async after the 204 ack). */
async function waitForFile(filePath: string, timeoutMs = 3000): Promise<void> {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    if (existsSync(filePath)) return;
    await new Promise((r) => setTimeout(r, 25));
  }
  throw new Error(`file not created within ${timeoutMs}ms: ${filePath}`);
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
