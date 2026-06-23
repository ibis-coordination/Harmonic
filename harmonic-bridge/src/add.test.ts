import { test } from "node:test";
import assert from "node:assert/strict";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { PassThrough } from "node:stream";
import { runAdd } from "./add.js";

const SETUP_URL = "https://harmonic.example/bridge-setups/abc123";
const REGISTER_URL = "https://harmonic.example/bridge-setups/abc123/webhook";

function collect(stream: PassThrough): Promise<string> {
  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = [];
    stream.on("data", (c: Buffer) => chunks.push(c));
    stream.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
    stream.on("error", reject);
  });
}

interface Fixture {
  configDir: string;
  secretsDir: string;
  cleanup: () => void;
}

function makeFixture(opts?: { publicUrl?: string; afterAdd?: string }): Fixture {
  const configDir = mkdtempSync(path.join(tmpdir(), "harmonic-bridge-add-"));
  const secretsDir = path.join(configDir, "secrets");
  const publicUrl = opts?.publicUrl ?? "https://bridge.example.com";
  const after = opts?.afterAdd ?? "";
  writeFileSync(path.join(configDir, "config.yml"), `
listen: 127.0.0.1:8080
public_url: ${publicUrl ? `"${publicUrl}"` : '""'}
log_dir: ${path.join(configDir, "logs")}
secrets:
  backend: file
  base_dir: ${secretsDir}
${after}
`);
  // Pretend the daemon is running by writing a PID file.
  writeFileSync(path.join(configDir, "daemon.pid"), String(process.pid));
  return { configDir, secretsDir, cleanup: () => rmSync(configDir, { recursive: true, force: true }) };
}

function makeMetadataResponse(): Response {
  return new Response(JSON.stringify({
    harmonic_mcp_endpoint: "https://harmonic.example/mcp",
    harmonic_token: "tok_secret_token_plaintext",
    signing_secret: "whsec_signing_secret_plaintext",
    agent_handle: "alice",
    webhook_register_url: REGISTER_URL,
    events_recommended: ["notifications.delivered", "reminders.delivered"],
  }), { status: 200, headers: { "Content-Type": "application/json" } });
}

function makeOkResponse(): Response {
  return new Response(JSON.stringify({ ok: true }), { status: 200, headers: { "Content-Type": "application/json" } });
}

interface FetchCall {
  url: string;
  method: string;
  body?: string;
}

function recordingFetch(handlers: Array<(url: string, init?: RequestInit) => Response>): { fetch: typeof fetch; calls: FetchCall[] } {
  const calls: FetchCall[] = [];
  let i = 0;
  const fn = async (input: RequestInfo | URL, init?: RequestInit): Promise<Response> => {
    const url = typeof input === "string" ? input : input.toString();
    calls.push({ url, method: init?.method ?? "GET", body: init?.body as string | undefined });
    const handler = handlers[i++];
    if (!handler) throw new Error(`unexpected fetch call #${i}: ${init?.method ?? "GET"} ${url}`);
    return handler(url, init);
  };
  return { fetch: fn as typeof fetch, calls };
}

// ---------- happy path ----------

test("add: happy path writes secrets + config, sighups daemon, posts registration, returns 0", async () => {
  const f = makeFixture();
  try {
    const { fetch: fakeFetch, calls } = recordingFetch([
      () => makeMetadataResponse(),
      () => makeOkResponse(),
    ]);
    const signals: Array<[number, NodeJS.Signals]> = [];

    const stdout = new PassThrough();
    const stdoutPromise = collect(stdout);
    const code = await runAdd(["--from", SETUP_URL], {
      configDir: f.configDir,
      stdout,
      fetch: fakeFetch,
      kill: (pid, sig) => { signals.push([pid, sig]); },
    });
    stdout.end();
    const out = await stdoutPromise;
    assert.equal(code, 0, `expected exit 0; got ${code}; stdout=${out}`);

    // Secrets on disk, mode 0600.
    const tokenPath = path.join(f.secretsDir, "alice", "harmonic_token");
    const secretPath = path.join(f.secretsDir, "alice", "webhook_secret");
    assert.equal(readFileSync(tokenPath, "utf8"), "tok_secret_token_plaintext");
    assert.equal(readFileSync(secretPath, "utf8"), "whsec_signing_secret_plaintext");
    assert.equal(statSync(tokenPath).mode & 0o777, 0o600);
    assert.equal(statSync(secretPath).mode & 0o777, 0o600);

    // Per-agent config references the file:// secrets, has a stub wake_command,
    // and the events list returned by the GET.
    const agentYml = readFileSync(path.join(f.configDir, "agents", "alice", "harmonic-bridge.yml"), "utf8");
    assert.match(agentYml, /harmonic_mcp_endpoint: https:\/\/harmonic\.example\/mcp/);
    assert.match(agentYml, new RegExp(`harmonic_token: file://${tokenPath.replace(/\//g, "\\/")}`));
    assert.match(agentYml, new RegExp(`webhook_secret: file://${secretPath.replace(/\//g, "\\/")}`));
    assert.match(agentYml, /wake_command not configured/);
    assert.match(agentYml, /notifications\.delivered/);

    // SIGHUP sent to the daemon (own PID via the fixture).
    assert.equal(signals.length, 1);
    assert.equal(signals[0]![0], process.pid);
    assert.equal(signals[0]![1], "SIGHUP");

    // GET then POST.
    assert.equal(calls.length, 2);
    assert.equal(calls[0]!.method, "GET");
    assert.equal(calls[0]!.url, SETUP_URL);
    assert.equal(calls[1]!.method, "POST");
    assert.equal(calls[1]!.url, REGISTER_URL);
    const postBody = JSON.parse(calls[1]!.body!);
    assert.equal(postBody.webhook_url, "https://bridge.example.com/webhook/alice");
    assert.deepEqual(postBody.events, ["notifications.delivered", "reminders.delivered"]);

    // Output includes the "next: edit wake_command" instruction.
    assert.match(out, /Agent "alice" added/);
    assert.match(out, /Edit wake_command/);
  } finally {
    f.cleanup();
  }
});

test("add: runs after_add steps when configured", async () => {
  const f = makeFixture({ afterAdd: `after_add:\n  - command: 'printf STEP-RAN > $HARMONIC_BRIDGE_AGENT_DIR/probe.txt'\n` });
  try {
    const { fetch: fakeFetch } = recordingFetch([() => makeMetadataResponse(), () => makeOkResponse()]);
    const stdout = new PassThrough();
    const stdoutPromise = collect(stdout);
    const code = await runAdd(["--from", SETUP_URL], {
      configDir: f.configDir,
      stdout,
      fetch: fakeFetch,
      kill: () => undefined,
    });
    stdout.end();
    assert.equal(code, 0);
    await stdoutPromise;
    const probePath = path.join(f.configDir, "agents", "alice", "probe.txt");
    assert.ok(existsSync(probePath), "after_add command should have run");
    assert.equal(readFileSync(probePath, "utf8"), "STEP-RAN");
  } finally {
    f.cleanup();
  }
});

// ---------- argument + config-side errors ----------

test("add: missing --from returns 64 with usage", async () => {
  const f = makeFixture();
  try {
    const stderr = new PassThrough();
    const stderrPromise = collect(stderr);
    const code = await runAdd([], { configDir: f.configDir, stderr });
    stderr.end();
    assert.equal(code, 64);
    assert.match(await stderrPromise, /missing --from/);
  } finally {
    f.cleanup();
  }
});

test("add: --from value that isn't a URL returns 64", async () => {
  const f = makeFixture();
  try {
    const stderr = new PassThrough();
    const stderrPromise = collect(stderr);
    const code = await runAdd(["--from", "not a url"], { configDir: f.configDir, stderr });
    stderr.end();
    assert.equal(code, 64);
    assert.match(await stderrPromise, /not a valid URL/);
  } finally {
    f.cleanup();
  }
});

test("add: missing config file returns 1 with 'run init first' guidance", async () => {
  const dir = mkdtempSync(path.join(tmpdir(), "harmonic-bridge-noconf-"));
  try {
    const stderr = new PassThrough();
    const stderrPromise = collect(stderr);
    const code = await runAdd(["--from", SETUP_URL], { configDir: dir, stderr });
    stderr.end();
    assert.equal(code, 1);
    const err = await stderrPromise;
    assert.match(err, /failed to load daemon config/);
    assert.match(err, /harmonic-bridge init/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("add: blank public_url returns 1 with clear 'set me' message", async () => {
  const f = makeFixture({ publicUrl: "" });
  try {
    const stderr = new PassThrough();
    const stderrPromise = collect(stderr);
    const code = await runAdd(["--from", SETUP_URL], { configDir: f.configDir, stderr });
    stderr.end();
    assert.equal(code, 1);
    assert.match(await stderrPromise, /public_url is not set/);
  } finally {
    f.cleanup();
  }
});

test("add: non-HTTPS public_url returns 1 with clear message", async () => {
  const f = makeFixture({ publicUrl: "http://insecure.example" });
  try {
    const stderr = new PassThrough();
    const stderrPromise = collect(stderr);
    const code = await runAdd(["--from", SETUP_URL], { configDir: f.configDir, stderr });
    stderr.end();
    assert.equal(code, 1);
    assert.match(await stderrPromise, /must use https/);
  } finally {
    f.cleanup();
  }
});

// ---------- HTTP-side errors ----------

test("add: GET 404 reports expired URL + tells user to get a fresh one", async () => {
  const f = makeFixture();
  try {
    const { fetch: fakeFetch } = recordingFetch([
      () => new Response("not found", { status: 404 }),
    ]);
    const stderr = new PassThrough();
    const stderrPromise = collect(stderr);
    const code = await runAdd(["--from", SETUP_URL], { configDir: f.configDir, stderr, fetch: fakeFetch, kill: () => undefined });
    stderr.end();
    assert.equal(code, 1);
    assert.match(await stderrPromise, /invalid or expired.*fresh URL/);
  } finally {
    f.cleanup();
  }
});

test("add: missing daemon.pid before POST → cleans up local files, reports daemon-not-running", async () => {
  const f = makeFixture();
  try {
    // Drop the PID file so SIGHUP fails.
    rmSync(path.join(f.configDir, "daemon.pid"));
    const { fetch: fakeFetch, calls } = recordingFetch([() => makeMetadataResponse()]);
    const stderr = new PassThrough();
    const stderrPromise = collect(stderr);
    const code = await runAdd(["--from", SETUP_URL], { configDir: f.configDir, stderr, fetch: fakeFetch, kill: () => undefined });
    stderr.end();
    assert.equal(code, 1);
    const err = await stderrPromise;
    assert.match(err, /daemon not running/);
    assert.match(err, /Start it with 'harmonic-bridge'/);

    // No POST was made.
    assert.equal(calls.length, 1);

    // Local files were cleaned up (no agent dir, no secrets dir).
    assert.equal(existsSync(path.join(f.configDir, "agents", "alice")), false);
    assert.equal(existsSync(path.join(f.secretsDir, "alice")), false);
  } finally {
    f.cleanup();
  }
});

test("add: POST 422 webhook_unreachable → rolls back local files + sighups daemon to drop the agent", async () => {
  const f = makeFixture();
  try {
    const { fetch: fakeFetch } = recordingFetch([
      () => makeMetadataResponse(),
      () => new Response(JSON.stringify({ error: "webhook_unreachable", detail: "connection refused" }), { status: 422, headers: { "Content-Type": "application/json" } }),
    ]);
    const signals: Array<[number, NodeJS.Signals]> = [];
    const stderr = new PassThrough();
    const stderrPromise = collect(stderr);
    const code = await runAdd(["--from", SETUP_URL], {
      configDir: f.configDir,
      stderr,
      fetch: fakeFetch,
      kill: (pid, sig) => { signals.push([pid, sig]); },
    });
    stderr.end();
    assert.equal(code, 1);
    const err = await stderrPromise;
    assert.match(err, /didn't get a 2xx/);
    assert.match(err, /public_url \(https:\/\/bridge\.example\.com\) is not actually reachable/);
    assert.match(err, /connection refused/);

    // Local files were rolled back.
    assert.equal(existsSync(path.join(f.configDir, "agents", "alice")), false);
    assert.equal(existsSync(path.join(f.secretsDir, "alice")), false);

    // Two SIGHUPs: one before POST to load the agent, one after to drop it.
    assert.equal(signals.length, 2);
    assert.deepEqual(signals.map((s) => s[1]), ["SIGHUP", "SIGHUP"]);
  } finally {
    f.cleanup();
  }
});

test("add: rejects an unsafe agent_handle (path traversal defense)", async () => {
  const f = makeFixture();
  try {
    const evilMetadata = new Response(JSON.stringify({
      harmonic_mcp_endpoint: "https://harmonic.example/mcp",
      harmonic_token: "tok",
      signing_secret: "whsec_x",
      agent_handle: "../etc/passwd",
      webhook_register_url: REGISTER_URL,
      events_recommended: ["notifications.delivered"],
    }), { status: 200, headers: { "Content-Type": "application/json" } });
    const { fetch: fakeFetch, calls } = recordingFetch([() => evilMetadata]);
    const stderr = new PassThrough();
    const stderrPromise = collect(stderr);
    const code = await runAdd(["--from", SETUP_URL], { configDir: f.configDir, stderr, fetch: fakeFetch, kill: () => undefined });
    stderr.end();
    assert.equal(code, 1);
    assert.match(await stderrPromise, /unsafe agent_handle/);
    // Only GET was made — no secrets or POST.
    assert.equal(calls.length, 1);
    assert.equal(existsSync(path.join(f.secretsDir, "..", "etc")), false);
  } finally {
    f.cleanup();
  }
});

test("add: YAML output safely quotes MCP endpoint with a YAML-special char", async () => {
  const f = makeFixture();
  try {
    // A `#` in the URL would be interpreted as a YAML comment marker if
    // unquoted, truncating the value mid-string. The library must quote it.
    const trickyMetadata = new Response(JSON.stringify({
      harmonic_mcp_endpoint: "https://harmonic.example/mcp#with-fragment",
      harmonic_token: "tok",
      signing_secret: "whsec_x",
      agent_handle: "alice",
      webhook_register_url: REGISTER_URL,
      events_recommended: ["notifications.delivered"],
    }), { status: 200, headers: { "Content-Type": "application/json" } });
    const { fetch: fakeFetch } = recordingFetch([() => trickyMetadata, () => makeOkResponse()]);
    const stdout = new PassThrough();
    void collect(stdout);
    const code = await runAdd(["--from", SETUP_URL], {
      configDir: f.configDir,
      stdout,
      fetch: fakeFetch,
      kill: () => undefined,
    });
    stdout.end();
    assert.equal(code, 0);

    const agentYml = readFileSync(path.join(f.configDir, "agents", "alice", "harmonic-bridge.yml"), "utf8");
    // Reading the file back through a YAML parser should yield the original URL.
    const { parse: parseYaml } = await import("yaml");
    const parsed = parseYaml(agentYml) as { harmonic_mcp_endpoint: string };
    assert.equal(parsed.harmonic_mcp_endpoint, "https://harmonic.example/mcp#with-fragment",
      "URL with '#' must round-trip through YAML cleanly");
  } finally {
    f.cleanup();
  }
});

test("add: existing agent directory → refuses to overwrite, cleans up secrets it just wrote", async () => {
  const f = makeFixture();
  try {
    // Pre-create the agent directory so the write fails.
    const agentDir = path.join(f.configDir, "agents", "alice");
    mkdirSync(agentDir, { recursive: true });
    writeFileSync(path.join(agentDir, "harmonic-bridge.yml"), "# already here\n");

    const { fetch: fakeFetch } = recordingFetch([() => makeMetadataResponse()]);
    const stderr = new PassThrough();
    const stderrPromise = collect(stderr);
    const code = await runAdd(["--from", SETUP_URL], { configDir: f.configDir, stderr, fetch: fakeFetch, kill: () => undefined });
    stderr.end();
    assert.equal(code, 1);
    assert.match(await stderrPromise, /already configured/);

    // The pre-existing config was NOT overwritten.
    assert.equal(readFileSync(path.join(agentDir, "harmonic-bridge.yml"), "utf8"), "# already here\n");

    // Secrets just written by this add were rolled back.
    assert.equal(existsSync(path.join(f.secretsDir, "alice")), false);
  } finally {
    f.cleanup();
  }
});
