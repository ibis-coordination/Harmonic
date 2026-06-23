import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir, homedir } from "node:os";
import path from "node:path";
import { ConfigError } from "./config.js";
import {
  expandTilde,
  listAgentNames,
  loadAgentConfig,
  loadDaemonConfig,
} from "./config-loader.js";

async function withTempDir<T>(fn: (dir: string) => Promise<T>): Promise<T> {
  const dir = mkdtempSync(path.join(tmpdir(), "harmonic-bridge-loader-"));
  try {
    return await fn(dir);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

// ---------- expandTilde ----------

test("expandTilde: replaces leading ~ with $HOME", () => {
  assert.equal(expandTilde("~/.harmonic-bridge/config.yml"), path.join(homedir(), ".harmonic-bridge/config.yml"));
});

test("expandTilde: bare ~ becomes home", () => {
  assert.equal(expandTilde("~"), homedir());
});

test("expandTilde: leaves non-tilde paths alone", () => {
  assert.equal(expandTilde("/etc/harmonic-bridge.yml"), "/etc/harmonic-bridge.yml");
  assert.equal(expandTilde("./relative/path"), "./relative/path");
});

test("expandTilde: only expands at start", () => {
  assert.equal(expandTilde("/some/~/path"), "/some/~/path");
});

// ---------- loadDaemonConfig ----------

test("loadDaemonConfig: reads and parses a valid YAML file", async () => {
  await withTempDir(async (dir) => {
    const file = path.join(dir, "config.yml");
    writeFileSync(file, `
listen: 127.0.0.1:8080
log_dir: /var/log/harmonic-bridge
`);
    const cfg = await loadDaemonConfig(file);
    assert.equal(cfg.listen.host, "127.0.0.1");
    assert.equal(cfg.listen.port, 8080);
    assert.equal(cfg.logDir, "/var/log/harmonic-bridge");
  });
});

test("loadDaemonConfig: expands ~ in log_dir", async () => {
  await withTempDir(async (dir) => {
    const file = path.join(dir, "config.yml");
    writeFileSync(file, `
listen: 127.0.0.1:8080
log_dir: ~/.harmonic-bridge/logs
`);
    const cfg = await loadDaemonConfig(file);
    assert.equal(cfg.logDir, path.join(homedir(), ".harmonic-bridge/logs"));
  });
});

test("loadDaemonConfig: file not found throws ConfigError", async () => {
  await assert.rejects(
    () => loadDaemonConfig("/nonexistent/path/harmonic-bridge-config.yml"),
    (e: unknown) => e instanceof ConfigError && /not found|cannot read|no such/i.test(e.message),
  );
});

test("loadDaemonConfig: malformed YAML throws ConfigError", async () => {
  await withTempDir(async (dir) => {
    const file = path.join(dir, "config.yml");
    writeFileSync(file, "listen: 127.0.0.1:8080\n  invalid: : indent\n");
    await assert.rejects(
      () => loadDaemonConfig(file),
      (e: unknown) => e instanceof ConfigError,
    );
  });
});

// ---------- loadAgentConfig ----------

const validAgentYaml = `
harmonic_mcp_endpoint: https://app.harmonic.example/mcp
harmonic_token: op://x
webhook_secret: op://y
working_dir: ~/code/Harmonic
wake_command: |
  claude -p
`;

test("loadAgentConfig: reads and parses, expands working_dir", async () => {
  await withTempDir(async (dir) => {
    const file = path.join(dir, "harmonic-bridge.yml");
    writeFileSync(file, validAgentYaml);
    const cfg = await loadAgentConfig(file);
    assert.equal(cfg.harmonicMcpEndpoint, "https://app.harmonic.example/mcp");
    assert.equal(cfg.workingDir, path.join(homedir(), "code/Harmonic"));
  });
});

test("loadAgentConfig: file not found throws ConfigError", async () => {
  await assert.rejects(
    () => loadAgentConfig("/nonexistent/agents/foo/harmonic-bridge.yml"),
    (e: unknown) => e instanceof ConfigError,
  );
});

// ---------- listAgentNames ----------

test("listAgentNames: returns names of directories containing harmonic-bridge.yml", async () => {
  await withTempDir(async (dir) => {
    mkdirSync(path.join(dir, "alice"));
    writeFileSync(path.join(dir, "alice/harmonic-bridge.yml"), "x: y\n");
    mkdirSync(path.join(dir, "bob"));
    writeFileSync(path.join(dir, "bob/harmonic-bridge.yml"), "x: y\n");
    // A directory without harmonic-bridge.yml should be skipped
    mkdirSync(path.join(dir, "no-config"));
    // A file directly in the base dir should be skipped
    writeFileSync(path.join(dir, "stray.txt"), "");

    const names = await listAgentNames(dir);
    assert.deepEqual(names.sort(), ["alice", "bob"]);
  });
});

test("listAgentNames: missing base dir returns empty list", async () => {
  const names = await listAgentNames("/nonexistent/agents-base-dir");
  assert.deepEqual(names, []);
});
