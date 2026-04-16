/**
 * HMAC-SHA256 request signing for internal API communication.
 *
 * The signed payload is `{nonce}.{timestamp}.{body}`. The nonce narrows the
 * replay window from the full 5-minute timestamp tolerance down to "once" —
 * Rails tracks seen nonces in Redis for the tolerance period and rejects
 * repeats. Without a nonce, any captured request could be replayed for up
 * to 5 minutes against a less-privileged endpoint (e.g. `/complete` with
 * stale step data).
 */

import { createHmac, randomUUID } from "node:crypto";

/**
 * Sign a request body with HMAC-SHA256.
 * Format: sha256={HMAC-SHA256(secret, "{nonce}.{timestamp}.{body}")}
 */
export function sign(body: string, timestamp: number, nonce: string, secret: string): string {
  const data = `${nonce}.${timestamp}.${body}`;
  const hmac = createHmac("sha256", secret).update(data).digest("hex");
  return `sha256=${hmac}`;
}

/**
 * Build HMAC headers for an internal API request.
 */
export function buildHeaders(body: string, secret: string): Record<string, string> {
  const timestamp = Math.floor(Date.now() / 1000);
  const nonce = randomUUID();
  const signature = sign(body, timestamp, nonce, secret);
  return {
    "X-Internal-Signature": signature,
    "X-Internal-Timestamp": String(timestamp),
    "X-Internal-Nonce": nonce,
    "Content-Type": "application/json",
  };
}
