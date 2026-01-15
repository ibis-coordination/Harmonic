import * as crypto from "node:crypto";
import { Effect } from "effect";
import { WebhookVerificationError } from "../errors/Errors.js";

export interface WebhookHeaders {
  signature: string;
  timestamp: string;
  event: string;
  delivery: string;
}

export function extractWebhookHeaders(headers: Headers): Effect.Effect<WebhookHeaders, WebhookVerificationError> {
  return Effect.gen(function* () {
    const signature = headers.get("x-harmonic-signature");
    const timestamp = headers.get("x-harmonic-timestamp");
    const event = headers.get("x-harmonic-event");
    const delivery = headers.get("x-harmonic-delivery");

    if (!signature) {
      return yield* Effect.fail(
        new WebhookVerificationError({ message: "Missing X-Harmonic-Signature header" })
      );
    }
    if (!timestamp) {
      return yield* Effect.fail(
        new WebhookVerificationError({ message: "Missing X-Harmonic-Timestamp header" })
      );
    }
    if (!event) {
      return yield* Effect.fail(
        new WebhookVerificationError({ message: "Missing X-Harmonic-Event header" })
      );
    }
    if (!delivery) {
      return yield* Effect.fail(
        new WebhookVerificationError({ message: "Missing X-Harmonic-Delivery header" })
      );
    }

    return { signature, timestamp, event, delivery };
  });
}

export function verifyWebhookSignature(
  body: string,
  timestamp: string,
  signature: string,
  secret: string
): Effect.Effect<void, WebhookVerificationError> {
  return Effect.gen(function* () {
    const maxAge = 5 * 60 * 1000; // 5 minutes
    const timestampNum = parseInt(timestamp, 10);
    const now = Date.now();

    if (isNaN(timestampNum)) {
      return yield* Effect.fail(
        new WebhookVerificationError({ message: "Invalid timestamp format" })
      );
    }

    if (Math.abs(now - timestampNum * 1000) > maxAge) {
      return yield* Effect.fail(
        new WebhookVerificationError({ message: "Webhook timestamp too old or in future" })
      );
    }

    const expected = crypto
      .createHmac("sha256", secret)
      .update(`${timestamp}.${body}`)
      .digest("hex");

    const actual = signature.replace(/^sha256=/, "");

    const expectedBuffer = Buffer.from(expected, "hex");
    const actualBuffer = Buffer.from(actual, "hex");

    if (expectedBuffer.length !== actualBuffer.length) {
      return yield* Effect.fail(
        new WebhookVerificationError({ message: "Invalid signature" })
      );
    }

    if (!crypto.timingSafeEqual(expectedBuffer, actualBuffer)) {
      return yield* Effect.fail(
        new WebhookVerificationError({ message: "Invalid signature" })
      );
    }
  });
}
