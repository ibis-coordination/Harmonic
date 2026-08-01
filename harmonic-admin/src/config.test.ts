import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { loadConfig, CONFIG_KEYS, SECRET_KEYS, defaultConfigPath } from "./config.js";

async function withTempDir<T>(fn: (dir: string) => Promise<T>): Promise<T> {
  const dir = mkdtempSync(path.join(tmpdir(), "harmonic-admin-config-"));
  try {
    return await fn(dir);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

test("loadConfig: reads KEY=VALUE lines from the env file", async () => {
  await withTempDir(async (dir) => {
    const configPath = path.join(dir, "env");
    writeFileSync(configPath, "SENTRY_ORG=ibis\nSENTRY_PROJECT=harmonic\n");
    const config = await loadConfig({ configPath, env: {} });
    assert.equal(config.values.SENTRY_ORG, "ibis");
    assert.equal(config.values.SENTRY_PROJECT, "harmonic");
    assert.equal(config.sources.SENTRY_ORG, "file");
  });
});

test("loadConfig: ignores comments, blank lines, and tolerates export prefix and quotes", async () => {
  await withTempDir(async (dir) => {
    const configPath = path.join(dir, "env");
    writeFileSync(
      configPath,
      [
        "# Sentry read-only token",
        "",
        'export SENTRY_API_TOKEN="abc123"',
        "SENTRY_ORG='ibis'",
      ].join("\n"),
    );
    const config = await loadConfig({ configPath, env: {} });
    assert.equal(config.values.SENTRY_API_TOKEN, "abc123");
    assert.equal(config.values.SENTRY_ORG, "ibis");
  });
});

test("loadConfig: environment variables override file values", async () => {
  await withTempDir(async (dir) => {
    const configPath = path.join(dir, "env");
    writeFileSync(configPath, "SENTRY_ORG=from-file\n");
    const config = await loadConfig({ configPath, env: { SENTRY_ORG: "from-env" } });
    assert.equal(config.values.SENTRY_ORG, "from-env");
    assert.equal(config.sources.SENTRY_ORG, "env");
  });
});

test("loadConfig: missing file yields defaults only, and fileExists false", async () => {
  await withTempDir(async (dir) => {
    const configPath = path.join(dir, "nope", "env");
    const config = await loadConfig({ configPath, env: {} });
    assert.equal(config.fileExists, false);
    assert.equal(config.values.SENTRY_API_TOKEN, undefined);
    assert.equal(config.values.HARMONIC_PROD_URL, "https://www.harmonic.social");
    assert.equal(config.sources.HARMONIC_PROD_URL, "default");
    assert.equal(config.values.SENTRY_BASE_URL, "https://sentry.io");
  });
});

test("loadConfig: unknown keys in the file are ignored", async () => {
  await withTempDir(async (dir) => {
    const configPath = path.join(dir, "env");
    writeFileSync(configPath, "SOME_RANDOM_KEY=x\nSENTRY_ORG=ibis\n");
    const config = await loadConfig({ configPath, env: {} });
    assert.equal(config.values.SENTRY_ORG, "ibis");
    assert.ok(!("SOME_RANDOM_KEY" in config.values));
  });
});

test("loadConfig: HARMONIC_ADMIN_CONFIG env var overrides the default path", async () => {
  await withTempDir(async (dir) => {
    const configPath = path.join(dir, "custom-env");
    writeFileSync(configPath, "SENTRY_ORG=via-custom-path\n");
    const config = await loadConfig({ env: { HARMONIC_ADMIN_CONFIG: configPath } });
    assert.equal(config.values.SENTRY_ORG, "via-custom-path");
    assert.equal(config.path, configPath);
  });
});

test("CONFIG_KEYS covers the v1 sources and SECRET_KEYS is a subset", () => {
  for (const key of ["HARMONIC_PROD_URL", "HARMONIC_METRICS_TOKEN", "SENTRY_API_TOKEN", "SENTRY_ORG", "SENTRY_PROJECT", "SENTRY_BASE_URL"]) {
    assert.ok((CONFIG_KEYS as readonly string[]).includes(key), `missing ${key}`);
  }
  for (const key of SECRET_KEYS) {
    assert.ok((CONFIG_KEYS as readonly string[]).includes(key));
  }
  assert.ok(SECRET_KEYS.includes("SENTRY_API_TOKEN"));
  assert.ok(SECRET_KEYS.includes("HARMONIC_METRICS_TOKEN"));
  assert.ok(!SECRET_KEYS.includes("SENTRY_ORG"));
});

test("defaultConfigPath: lives under ~/.config/harmonic-admin", () => {
  assert.match(defaultConfigPath(), /\.config\/harmonic-admin\/env$/);
});
