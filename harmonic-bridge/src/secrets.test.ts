import { test } from "node:test";
import assert from "node:assert/strict";
import { writeFileSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { BUILTIN_RESOLVERS } from "./config.js";
import { parseReference, resolveSecret, SecretError } from "./secrets.js";

// ---------- parseReference ----------

test("parseReference: splits scheme and body", () => {
  assert.deepEqual(parseReference("op://Personal/foo/bar"), { scheme: "op", body: "Personal/foo/bar" });
  assert.deepEqual(parseReference("file:///tmp/x"), { scheme: "file", body: "/tmp/x" });
  assert.deepEqual(parseReference("env://HARMONIC_TOKEN"), { scheme: "env", body: "HARMONIC_TOKEN" });
});

test("parseReference: returns null for plain strings", () => {
  assert.equal(parseReference("just a string"), null);
  assert.equal(parseReference("nothttps"), null);
  assert.equal(parseReference(""), null);
});

test("parseReference: requires non-empty body", () => {
  assert.equal(parseReference("op://"), null);
});

// ---------- resolveSecret: built-in resolvers ----------

test("resolveSecret: file:// resolver reads the file's contents", async () => {
  const dir = mkdtempSync(join(tmpdir(), "harmonic-bridge-secrets-"));
  try {
    const path = join(dir, "secret.txt");
    writeFileSync(path, "supersecret\n");

    const value = await resolveSecret(`file://${path}`, BUILTIN_RESOLVERS);
    assert.equal(value, "supersecret");
  } finally {
    rmSync(dir, { recursive: true });
  }
});

test("resolveSecret: env:// resolver reads the env var", async () => {
  process.env["MELODIC_TEST_SECRET"] = "from-env";
  try {
    const value = await resolveSecret("env://MELODIC_TEST_SECRET", BUILTIN_RESOLVERS);
    assert.equal(value, "from-env");
  } finally {
    delete process.env["MELODIC_TEST_SECRET"];
  }
});

test("resolveSecret: trims trailing newlines from resolver stdout", async () => {
  process.env["MELODIC_TEST_TRIM"] = "x";
  try {
    // `printenv` always appends \n; resolver should strip it.
    const value = await resolveSecret("env://MELODIC_TEST_TRIM", BUILTIN_RESOLVERS);
    assert.equal(value, "x");
  } finally {
    delete process.env["MELODIC_TEST_TRIM"];
  }
});

// ---------- resolveSecret: custom resolvers ----------

test("resolveSecret: custom resolver template substitutes the body", async () => {
  const resolvers = { ...BUILTIN_RESOLVERS, demo: "printf '%s' {ref}" };
  const value = await resolveSecret("demo://hello-there", resolvers);
  assert.equal(value, "hello-there");
});

test("resolveSecret: placeholder name in template doesn't have to be a known one", async () => {
  // The README documents {path}, {name}, {ref} but the substitution is by
  // pattern, not name — any {identifier} in the template gets the body.
  const resolvers = { ...BUILTIN_RESOLVERS, demo: "printf '%s' {whatever}" };
  const value = await resolveSecret("demo://hi", resolvers);
  assert.equal(value, "hi");
});

// ---------- resolveSecret: error paths ----------

test("resolveSecret: throws when reference isn't scheme://body", async () => {
  await assert.rejects(
    () => resolveSecret("not a reference", BUILTIN_RESOLVERS),
    (e: unknown) => e instanceof SecretError && /reference/i.test(e.message),
  );
});

test("resolveSecret: throws when scheme has no configured resolver", async () => {
  await assert.rejects(
    () => resolveSecret("nope://x", BUILTIN_RESOLVERS),
    (e: unknown) => e instanceof SecretError && /scheme/i.test(e.message) && /nope/.test(e.message),
  );
});

test("resolveSecret: throws when resolver command exits non-zero", async () => {
  await assert.rejects(
    () => resolveSecret("file:///nonexistent/path/harmonic-bridge-test", BUILTIN_RESOLVERS),
    (e: unknown) => e instanceof SecretError,
  );
});
