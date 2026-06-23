import { test } from "node:test";
import assert from "node:assert/strict";
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { initConfig } from "./init.js";

async function withTempDir<T>(fn: (dir: string) => Promise<T>): Promise<T> {
  const dir = mkdtempSync(path.join(tmpdir(), "harmonic-bridge-init-"));
  try {
    return await fn(dir);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

test("initConfig: writes config.yml, harmonic-bridge.service, and agents/ dir", async () => {
  await withTempDir(async (dir) => {
    const result = await initConfig(dir);
    assert.ok(existsSync(path.join(dir, "config.yml")));
    assert.ok(existsSync(path.join(dir, "harmonic-bridge.service")));
    assert.ok(existsSync(path.join(dir, "agents")));
    assert.deepEqual(
      [...result.written].sort(),
      [path.join(dir, "config.yml"), path.join(dir, "harmonic-bridge.service")].sort(),
    );
    assert.deepEqual(result.skipped, []);
  });
});

test("initConfig: written config.yml parses as a valid daemon config", async () => {
  await withTempDir(async (dir) => {
    await initConfig(dir);
    // Make sure the skeleton round-trips through the loader the daemon will use.
    const { loadDaemonConfig } = await import("./config-loader.js");
    const cfg = await loadDaemonConfig(path.join(dir, "config.yml"));
    assert.ok(cfg.listen.host);
    assert.ok(cfg.listen.port);
    assert.ok(cfg.logDir);
  });
});

test("initConfig: doesn't overwrite an existing config.yml", async () => {
  await withTempDir(async (dir) => {
    const cfgPath = path.join(dir, "config.yml");
    writeFileSync(cfgPath, "# my custom config\n");
    const result = await initConfig(dir);
    assert.equal(readFileSync(cfgPath, "utf8"), "# my custom config\n");
    assert.ok(result.skipped.includes(cfgPath));
    assert.ok(!result.written.includes(cfgPath));
  });
});

test("initConfig: doesn't overwrite an existing harmonic-bridge.service", async () => {
  await withTempDir(async (dir) => {
    const unitPath = path.join(dir, "harmonic-bridge.service");
    writeFileSync(unitPath, "[Unit]\nDescription=custom\n");
    const result = await initConfig(dir);
    assert.equal(readFileSync(unitPath, "utf8"), "[Unit]\nDescription=custom\n");
    assert.ok(result.skipped.includes(unitPath));
  });
});

test("initConfig: creates configDir if it doesn't exist", async () => {
  await withTempDir(async (parent) => {
    const dir = path.join(parent, "deeper", "still-deeper");
    const result = await initConfig(dir);
    assert.ok(existsSync(dir));
    assert.ok(existsSync(path.join(dir, "config.yml")));
    assert.ok(result.written.length > 0);
  });
});
