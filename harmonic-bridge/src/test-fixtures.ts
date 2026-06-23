// Loaders + assertions for the shared bridge_protocol fixtures at
// <Harmonic-repo>/test/fixtures/bridge_protocol/. The Ruby controller
// tests load the same fixtures via test/support/bridge_protocol_fixtures.rb.
// If a field is renamed on either side, the OTHER side's tests fail at
// the structural conformance check.
//
// The helpers assert TYPE and key PRESENCE, not value equality — fixtures
// document the wire shape, not specific values.

import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const SELF_DIR = path.dirname(fileURLToPath(import.meta.url));
/** Resolves <repo>/test/fixtures/bridge_protocol from harmonic-bridge/src. */
const FIXTURE_DIR = path.resolve(SELF_DIR, "..", "..", "test", "fixtures", "bridge_protocol");

export function loadProtocolFixture(name: string): unknown {
  return JSON.parse(readFileSync(path.join(FIXTURE_DIR, name), "utf8"));
}

/** Build a fetch-compatible Response from a fixture. */
export function protocolFixtureResponse(name: string, init?: { status?: number }): Response {
  const body = readFileSync(path.join(FIXTURE_DIR, name), "utf8");
  return new Response(body, {
    status: init?.status ?? 200,
    headers: { "Content-Type": "application/json" },
  });
}

/**
 * Assert `actual` has the same structural shape as the fixture: every key
 * in the fixture must be present in `actual` with a value of the same type.
 * Extra keys in `actual` are allowed (responses can grow without breaking
 * old clients).
 */
export function assertMatchesProtocolFixture(actual: unknown, fixtureName: string): void {
  const fixture = loadProtocolFixture(fixtureName);
  assertShapeMatches(fixture, actual, `(${fixtureName})`);
}

function assertShapeMatches(expected: unknown, actual: unknown, path: string): void {
  if (Array.isArray(expected)) {
    if (!Array.isArray(actual)) {
      throw new Error(`expected Array at ${path}, got ${typeof actual}`);
    }
    const next = expected[0];
    if (next !== undefined) {
      actual.forEach((item, i) => assertShapeMatches(next, item, `${path}[${i}]`));
    }
    return;
  }
  if (expected === null) {
    if (actual !== null) throw new Error(`expected null at ${path}, got ${JSON.stringify(actual)}`);
    return;
  }
  if (typeof expected === "object") {
    if (typeof actual !== "object" || actual === null || Array.isArray(actual)) {
      throw new Error(`expected object at ${path}, got ${actual === null ? "null" : typeof actual}`);
    }
    for (const [k, v] of Object.entries(expected)) {
      if (!(k in actual)) {
        throw new Error(`missing key "${k}" at ${path} (have: ${Object.keys(actual).join(", ")})`);
      }
      assertShapeMatches(v, (actual as Record<string, unknown>)[k], `${path}.${k}`);
    }
    return;
  }
  if (typeof expected === "string") {
    if (typeof actual !== "string") throw new Error(`expected string at ${path}, got ${typeof actual}`);
    return;
  }
  if (typeof expected === "number") {
    if (typeof actual !== "number") throw new Error(`expected number at ${path}, got ${typeof actual}`);
    return;
  }
  if (typeof expected === "boolean") {
    if (typeof actual !== "boolean") throw new Error(`expected boolean at ${path}, got ${typeof actual}`);
    return;
  }
}
