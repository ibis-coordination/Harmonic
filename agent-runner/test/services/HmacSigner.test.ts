import { describe, it, expect } from "vitest";
import { sign, buildHeaders } from "../../src/services/HmacSigner.js";
import { createHmac } from "node:crypto";

describe("sign", () => {
  it("produces correct HMAC-SHA256 signature over {nonce}.{timestamp}.{body}", () => {
    const body = '{"task_run_id":"123"}';
    const timestamp = 1713000000;
    const nonce = "test-nonce-abc";
    const secret = "test-secret";

    const expected = createHmac("sha256", secret)
      .update(`${nonce}.${timestamp}.${body}`)
      .digest("hex");

    expect(sign(body, timestamp, nonce, secret)).toBe(`sha256=${expected}`);
  });

  it("produces different signatures for different bodies", () => {
    const secret = "test-secret";
    const timestamp = 1713000000;
    const nonce = "same-nonce";
    const sig1 = sign("body1", timestamp, nonce, secret);
    const sig2 = sign("body2", timestamp, nonce, secret);
    expect(sig1).not.toBe(sig2);
  });

  it("produces different signatures for different nonces", () => {
    const secret = "test-secret";
    const timestamp = 1713000000;
    const sig1 = sign("body", timestamp, "nonce-a", secret);
    const sig2 = sign("body", timestamp, "nonce-b", secret);
    expect(sig1).not.toBe(sig2);
  });
});

describe("buildHeaders", () => {
  it("returns signature, timestamp, and nonce headers", () => {
    const headers = buildHeaders('{"test": true}', "my-secret");
    expect(headers["X-Internal-Signature"]).toMatch(/^sha256=[a-f0-9]{64}$/);
    expect(headers["X-Internal-Timestamp"]).toMatch(/^\d+$/);
    expect(headers["X-Internal-Nonce"]).toMatch(/^[0-9a-f-]{36}$/);
    expect(headers["Content-Type"]).toBe("application/json");
  });

  it("generates a unique nonce per call", () => {
    const a = buildHeaders("body", "secret");
    const b = buildHeaders("body", "secret");
    expect(a["X-Internal-Nonce"]).not.toBe(b["X-Internal-Nonce"]);
  });
});
