// Harmonic notification-webhook signature verification.
//
// Harmonic signs each outbound webhook with HMAC-SHA256 over
// `${X-Harmonic-Timestamp}.${raw body}`, sent as `X-Harmonic-Signature:
// sha256=<hex>`. The timestamp is also a replay-window check — Harmonic's
// receiver convention is 5 minutes; harmonic-bridge matches.
//
// Pure function: takes headers + body + secret, returns a result. No I/O,
// no logging. Callers (the HTTP server) decide what to do with rejections.

import { createHmac, timingSafeEqual } from "node:crypto";

export type WebhookVerification =
  | { readonly valid: true }
  | {
      readonly valid: false;
      readonly reason:
        | "missing_signature"
        | "missing_timestamp"
        | "invalid_timestamp"
        | "expired"
        | "mismatch";
    };

export interface WebhookVerifyArgs {
  readonly body: string;
  readonly signatureHeader: string | undefined;
  readonly timestampHeader: string | undefined;
  readonly secret: string;
  /** Override the current time (epoch seconds). Defaults to Date.now()/1000. */
  readonly now?: number;
  /** Replay window in seconds. Defaults to 300. */
  readonly maxAgeSeconds?: number;
}

const DEFAULT_MAX_AGE_SECONDS = 300;

export function verifyWebhook(args: WebhookVerifyArgs): WebhookVerification {
  if (!args.signatureHeader) {
    return { valid: false, reason: "missing_signature" };
  }
  if (!args.timestampHeader) {
    return { valid: false, reason: "missing_timestamp" };
  }

  const ts = Number(args.timestampHeader);
  if (!Number.isFinite(ts)) {
    return { valid: false, reason: "invalid_timestamp" };
  }

  const now = args.now ?? Math.floor(Date.now() / 1000);
  const maxAge = args.maxAgeSeconds ?? DEFAULT_MAX_AGE_SECONDS;
  if (Math.abs(now - ts) > maxAge) {
    return { valid: false, reason: "expired" };
  }

  const expected = "sha256=" + createHmac("sha256", args.secret)
    .update(`${ts}.${args.body}`)
    .digest("hex");

  // timingSafeEqual requires equal-length inputs; guard before calling.
  const provided = Buffer.from(args.signatureHeader);
  const expectedBuf = Buffer.from(expected);
  if (provided.length !== expectedBuf.length) {
    return { valid: false, reason: "mismatch" };
  }
  if (!timingSafeEqual(provided, expectedBuf)) {
    return { valid: false, reason: "mismatch" };
  }
  return { valid: true };
}
