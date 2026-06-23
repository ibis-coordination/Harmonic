import { test } from "node:test";
import assert from "node:assert/strict";
import { createHmac } from "node:crypto";
import { verifyWebhook } from "./webhook.js";

const SECRET = "test-secret";
const BODY = '{"event":"notifications.delivered"}';
const TS = 1735200000;

function sign(body: string, ts: number, secret: string): string {
  const hex = createHmac("sha256", secret).update(`${ts}.${body}`).digest("hex");
  return `sha256=${hex}`;
}

test("verifyWebhook: valid signature passes", () => {
  const result = verifyWebhook({
    body: BODY,
    signatureHeader: sign(BODY, TS, SECRET),
    timestampHeader: String(TS),
    secret: SECRET,
    now: TS,
  });
  assert.deepEqual(result, { valid: true });
});

test("verifyWebhook: missing signature header", () => {
  const result = verifyWebhook({
    body: BODY,
    signatureHeader: undefined,
    timestampHeader: String(TS),
    secret: SECRET,
    now: TS,
  });
  assert.deepEqual(result, { valid: false, reason: "missing_signature" });
});

test("verifyWebhook: missing timestamp header", () => {
  const result = verifyWebhook({
    body: BODY,
    signatureHeader: sign(BODY, TS, SECRET),
    timestampHeader: undefined,
    secret: SECRET,
    now: TS,
  });
  assert.deepEqual(result, { valid: false, reason: "missing_timestamp" });
});

test("verifyWebhook: non-numeric timestamp", () => {
  const result = verifyWebhook({
    body: BODY,
    signatureHeader: sign(BODY, TS, SECRET),
    timestampHeader: "not-a-number",
    secret: SECRET,
    now: TS,
  });
  assert.deepEqual(result, { valid: false, reason: "invalid_timestamp" });
});

test("verifyWebhook: timestamp too old (replay window)", () => {
  const oldTs = TS - 600;
  const result = verifyWebhook({
    body: BODY,
    signatureHeader: sign(BODY, oldTs, SECRET),
    timestampHeader: String(oldTs),
    secret: SECRET,
    now: TS,
  });
  assert.deepEqual(result, { valid: false, reason: "expired" });
});

test("verifyWebhook: timestamp too far in the future (clock skew bound)", () => {
  const futureTs = TS + 600;
  const result = verifyWebhook({
    body: BODY,
    signatureHeader: sign(BODY, futureTs, SECRET),
    timestampHeader: String(futureTs),
    secret: SECRET,
    now: TS,
  });
  assert.deepEqual(result, { valid: false, reason: "expired" });
});

test("verifyWebhook: wrong signature value", () => {
  const result = verifyWebhook({
    body: BODY,
    signatureHeader: "sha256=" + "0".repeat(64),
    timestampHeader: String(TS),
    secret: SECRET,
    now: TS,
  });
  assert.deepEqual(result, { valid: false, reason: "mismatch" });
});

test("verifyWebhook: tampered body", () => {
  const result = verifyWebhook({
    body: BODY + "tampered",
    signatureHeader: sign(BODY, TS, SECRET),
    timestampHeader: String(TS),
    secret: SECRET,
    now: TS,
  });
  assert.deepEqual(result, { valid: false, reason: "mismatch" });
});

test("verifyWebhook: wrong secret", () => {
  const result = verifyWebhook({
    body: BODY,
    signatureHeader: sign(BODY, TS, "different-secret"),
    timestampHeader: String(TS),
    secret: SECRET,
    now: TS,
  });
  assert.deepEqual(result, { valid: false, reason: "mismatch" });
});

test("verifyWebhook: missing sha256= prefix is rejected", () => {
  const hex = createHmac("sha256", SECRET).update(`${TS}.${BODY}`).digest("hex");
  const result = verifyWebhook({
    body: BODY,
    signatureHeader: hex,
    timestampHeader: String(TS),
    secret: SECRET,
    now: TS,
  });
  assert.deepEqual(result, { valid: false, reason: "mismatch" });
});

test("verifyWebhook: custom maxAgeSeconds tightens the replay window", () => {
  const ts = TS - 10;
  const result = verifyWebhook({
    body: BODY,
    signatureHeader: sign(BODY, ts, SECRET),
    timestampHeader: String(ts),
    secret: SECRET,
    now: TS,
    maxAgeSeconds: 5,
  });
  assert.deepEqual(result, { valid: false, reason: "expired" });
});

test("verifyWebhook: now defaults to current time", () => {
  const nowSec = Math.floor(Date.now() / 1000);
  const result = verifyWebhook({
    body: BODY,
    signatureHeader: sign(BODY, nowSec, SECRET),
    timestampHeader: String(nowSec),
    secret: SECRET,
  });
  assert.deepEqual(result, { valid: true });
});

test("verifyWebhook: different-length signatures don't throw (timing-safe)", () => {
  const result = verifyWebhook({
    body: BODY,
    signatureHeader: "sha256=short",
    timestampHeader: String(TS),
    secret: SECRET,
    now: TS,
  });
  assert.deepEqual(result, { valid: false, reason: "mismatch" });
});
