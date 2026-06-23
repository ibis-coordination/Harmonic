import { test } from "node:test";
import assert from "node:assert/strict";
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { writeClaudeMcpConfig } from "./claude-mcp-config.js";

async function withTempDir<T>(fn: (dir: string) => Promise<T>): Promise<T> {
  const dir = mkdtempSync(path.join(tmpdir(), "harmonic-bridge-claude-mcp-"));
  try {
    return await fn(dir);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

test("writeClaudeMcpConfig: writes mcp-config.json with server-name convention", async () => {
  await withTempDir(async (dir) => {
    const filePath = await writeClaudeMcpConfig({
      agentDir: dir,
      agentHandle: "melody",
      mcpEndpoint: "https://app.harmonic.example/mcp",
    });
    assert.equal(filePath, path.join(dir, "mcp-config.json"));
    assert.ok(existsSync(filePath));

    const config = JSON.parse(readFileSync(filePath, "utf8"));
    assert.ok(config.mcpServers["harmonic-melody"], "server name should be harmonic-<handle>");
    assert.equal(config.mcpServers["harmonic-melody"].type, "http");
    assert.equal(config.mcpServers["harmonic-melody"].url, "https://app.harmonic.example/mcp");
  });
});

test("writeClaudeMcpConfig: Authorization header references ${MELODIC_HARMONIC_TOKEN} literally", async () => {
  await withTempDir(async (dir) => {
    await writeClaudeMcpConfig({
      agentDir: dir,
      agentHandle: "melody",
      mcpEndpoint: "https://app.harmonic.example/mcp",
    });
    const raw = readFileSync(path.join(dir, "mcp-config.json"), "utf8");
    // Critical: the file must contain the literal ${...} reference, not a
    // resolved token. harmonic-bridge never writes secrets to disk.
    assert.match(raw, /\$\{MELODIC_HARMONIC_TOKEN\}/);
    assert.doesNotMatch(raw, /Bearer (?!\$\{)/);
  });
});

test("writeClaudeMcpConfig: overwrites existing file (idempotent re-runs)", async () => {
  await withTempDir(async (dir) => {
    const filePath = path.join(dir, "mcp-config.json");
    writeFileSync(filePath, '{"stale": true}');

    await writeClaudeMcpConfig({
      agentDir: dir,
      agentHandle: "melody",
      mcpEndpoint: "https://example/mcp",
    });

    const config = JSON.parse(readFileSync(filePath, "utf8"));
    assert.equal(config.stale, undefined);
    assert.ok(config.mcpServers["harmonic-melody"]);
  });
});

test("writeClaudeMcpConfig: different agents get different server names", async () => {
  await withTempDir(async (dir) => {
    const aDir = path.join(dir, "alice");
    const bDir = path.join(dir, "bob");
    // The function shouldn't need the agent dir to exist — but to be safe:
    const { mkdirSync } = await import("node:fs");
    mkdirSync(aDir);
    mkdirSync(bDir);

    await writeClaudeMcpConfig({ agentDir: aDir, agentHandle: "alice", mcpEndpoint: "https://x/mcp" });
    await writeClaudeMcpConfig({ agentDir: bDir, agentHandle: "bob", mcpEndpoint: "https://x/mcp" });

    const a = JSON.parse(readFileSync(path.join(aDir, "mcp-config.json"), "utf8"));
    const b = JSON.parse(readFileSync(path.join(bDir, "mcp-config.json"), "utf8"));
    assert.ok(a.mcpServers["harmonic-alice"]);
    assert.ok(!a.mcpServers["harmonic-bob"]);
    assert.ok(b.mcpServers["harmonic-bob"]);
    assert.ok(!b.mcpServers["harmonic-alice"]);
  });
});
