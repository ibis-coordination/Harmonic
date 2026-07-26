import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { parse as parseYaml } from "yaml";
import { writeGooseConfig, gooseConfigRoot } from "./goose-config.js";

function makeAgentDir(): string {
  return mkdtempSync(path.join(tmpdir(), "goose-config-"));
}

const ARGS = {
  agentHandle: "alice",
  mcpEndpoint: "https://app.harmonic.example/mcp",
};

function readConfig(dir: string): Record<string, any> {
  return parseYaml(readFileSync(path.join(gooseConfigRoot(dir), "goose", "config.yaml"), "utf8"));
}

test("goose-config: writes the extension under the relocated config root", async (t) => {
  const dir = makeAgentDir();
  t.after(() => rmSync(dir, { recursive: true, force: true }));

  const filePath = await writeGooseConfig({ agentDir: dir, ...ARGS });
  assert.equal(filePath, path.join(dir, "home", ".config", "goose", "config.yaml"));

  const config = readConfig(dir);
  const ext = config["extensions"]["harmonic-alice"];
  assert.ok(ext, "extension must be keyed harmonic-<handle>");
  assert.equal(ext["type"], "streamable_http", "the hyphenated form is silently wrong");
  assert.equal(ext["name"], "harmonic-alice");
  assert.equal(ext["uri"], "https://app.harmonic.example/mcp");
  assert.equal(ext["enabled"], true);
  assert.equal(ext["timeout"], 300);
});

test("goose-config: carries the token as an env reference, never a literal", async (t) => {
  const dir = makeAgentDir();
  t.after(() => rmSync(dir, { recursive: true, force: true }));

  const filePath = await writeGooseConfig({ agentDir: dir, ...ARGS });
  const config = readConfig(dir);
  assert.equal(config["extensions"]["harmonic-alice"]["headers"]["Authorization"], "Bearer ${HARMONIC_BRIDGE_TOKEN}");
  // Belt and braces: nothing token-shaped reaches disk.
  const raw = readFileSync(filePath, "utf8");
  assert.doesNotMatch(raw, /Bearer [A-Za-z0-9_-]{8}/);
  // Quoted, so the brace cannot read as a flow mapping to whichever YAML
  // implementation Goose ships. Our own parser tolerates it unquoted; theirs
  // is a different one, and the documented form is quoted.
  assert.match(raw, /Authorization: "Bearer \$\{HARMONIC_BRIDGE_TOKEN\}"/);
});

test("goose-config: is idempotent across two runs", async (t) => {
  const dir = makeAgentDir();
  t.after(() => rmSync(dir, { recursive: true, force: true }));

  const filePath = await writeGooseConfig({ agentDir: dir, ...ARGS });
  const afterFirst = readFileSync(filePath, "utf8");
  await writeGooseConfig({ agentDir: dir, ...ARGS });
  assert.equal(readFileSync(filePath, "utf8"), afterFirst);
});

test("goose-config: preserves settings the operator added", async (t) => {
  const dir = makeAgentDir();
  t.after(() => rmSync(dir, { recursive: true, force: true }));

  const root = path.join(gooseConfigRoot(dir), "goose");
  mkdirSync(root, { recursive: true });
  writeFileSync(
    path.join(root, "config.yaml"),
    [
      "GOOSE_MODE: auto",
      "extensions:",
      "  my-own-thing:",
      "    enabled: true",
      "    type: stdio",
      "    cmd: /usr/bin/thing",
      "  harmonic-alice:",
      "    enabled: true",
      "    type: streamable_http",
      "    uri: https://stale.example/mcp",
      "",
    ].join("\n"),
  );

  await writeGooseConfig({ agentDir: dir, ...ARGS });

  const config = readConfig(dir);
  assert.equal(config["GOOSE_MODE"], "auto", "top-level settings survive");
  assert.equal(config["extensions"]["my-own-thing"]["cmd"], "/usr/bin/thing", "other extensions survive");
  assert.equal(
    config["extensions"]["harmonic-alice"]["uri"],
    "https://app.harmonic.example/mcp",
    "a stale Harmonic endpoint is corrected",
  );
});
