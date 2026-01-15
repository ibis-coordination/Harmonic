import { describe, it, expect } from "vitest";
import * as crypto from "node:crypto";
import { Effect } from "effect";
import {
  extractWebhookHeaders,
  verifyWebhookSignature,
} from "./WebhookVerification.js";

describe("WebhookVerification", () => {
  describe("extractWebhookHeaders", () => {
    it("should extract all required headers", async () => {
      const headers = new Headers({
        "x-harmonic-signature": "sha256=abc123",
        "x-harmonic-timestamp": "1234567890",
        "x-harmonic-event": "note.created",
        "x-harmonic-delivery": "uuid-1234",
      });

      const result = await Effect.runPromise(
        extractWebhookHeaders(headers).pipe(Effect.either)
      );

      expect(result._tag).toBe("Right");
      if (result._tag === "Right") {
        expect(result.right).toEqual({
          signature: "sha256=abc123",
          timestamp: "1234567890",
          event: "note.created",
          delivery: "uuid-1234",
        });
      }
    });

    it("should fail if signature is missing", async () => {
      const headers = new Headers({
        "x-harmonic-timestamp": "1234567890",
        "x-harmonic-event": "note.created",
        "x-harmonic-delivery": "uuid-1234",
      });

      const result = await Effect.runPromise(
        extractWebhookHeaders(headers).pipe(Effect.either)
      );

      expect(result._tag).toBe("Left");
      if (result._tag === "Left") {
        expect(result.left.message).toContain("Missing X-Harmonic-Signature");
      }
    });
  });

  describe("verifyWebhookSignature", () => {
    const secret = "test-secret";

    function createSignature(body: string, timestamp: string): string {
      const hash = crypto
        .createHmac("sha256", secret)
        .update(`${timestamp}.${body}`)
        .digest("hex");
      return `sha256=${hash}`;
    }

    it("should verify a valid signature", async () => {
      const body = '{"test": "data"}';
      const timestamp = Math.floor(Date.now() / 1000).toString();
      const signature = createSignature(body, timestamp);

      const result = await Effect.runPromise(
        verifyWebhookSignature(body, timestamp, signature, secret).pipe(
          Effect.either
        )
      );

      expect(result._tag).toBe("Right");
    });

    it("should reject an invalid signature", async () => {
      const body = '{"test": "data"}';
      const timestamp = Math.floor(Date.now() / 1000).toString();
      const signature = "sha256=invalid";

      const result = await Effect.runPromise(
        verifyWebhookSignature(body, timestamp, signature, secret).pipe(
          Effect.either
        )
      );

      expect(result._tag).toBe("Left");
      if (result._tag === "Left") {
        expect(result.left.message).toContain("Invalid signature");
      }
    });

    it("should reject an old timestamp", async () => {
      const body = '{"test": "data"}';
      const oldTimestamp = (Math.floor(Date.now() / 1000) - 600).toString(); // 10 minutes ago
      const signature = createSignature(body, oldTimestamp);

      const result = await Effect.runPromise(
        verifyWebhookSignature(body, oldTimestamp, signature, secret).pipe(
          Effect.either
        )
      );

      expect(result._tag).toBe("Left");
      if (result._tag === "Left") {
        expect(result.left.message).toContain("timestamp too old");
      }
    });
  });
});
