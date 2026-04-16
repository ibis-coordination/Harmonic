import { describe, it, expect } from "vitest";
import { sign, buildHeaders } from "../../src/services/HmacSigner.js";
import { createHmac } from "node:crypto";

describe("sign", () => {
  it("produces correct HMAC-SHA256 signature", () => {
    const body = '{"task_run_id":"123"}';
    const timestamp = 1713000000;
    const secret = "test-secret";

    const expected = createHmac("sha256", secret)
      .update(`${timestamp}.${body}`)
      .digest("hex");

    expect(sign(body, timestamp, secret)).toBe(`sha256=${expected}`);
  });

  it("produces different signatures for different bodies", () => {
    const secret = "test-secret";
    const timestamp = 1713000000;
    const sig1 = sign("body1", timestamp, secret);
    const sig2 = sign("body2", timestamp, secret);
    expect(sig1).not.toBe(sig2);
  });
});

describe("buildHeaders", () => {
  it("returns signature and timestamp headers", () => {
    const headers = buildHeaders('{"test": true}', "my-secret");
    expect(headers["X-Internal-Signature"]).toMatch(/^sha256=[a-f0-9]{64}$/);
    expect(headers["X-Internal-Timestamp"]).toMatch(/^\d+$/);
    expect(headers["Content-Type"]).toBe("application/json");
  });
});
