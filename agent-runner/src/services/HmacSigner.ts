/**
 * HMAC-SHA256 request signing for internal API communication.
 * Follows the same pattern as WebhookDeliveryService in Rails.
 */

import { createHmac } from "node:crypto";

/**
 * Sign a request body with HMAC-SHA256.
 * Format: sha256={HMAC-SHA256(secret, "#{timestamp}.#{body}")}
 */
export function sign(body: string, timestamp: number, secret: string): string {
  const data = `${timestamp}.${body}`;
  const hmac = createHmac("sha256", secret).update(data).digest("hex");
  return `sha256=${hmac}`;
}

/**
 * Build HMAC headers for an internal API request.
 */
export function buildHeaders(body: string, secret: string): Record<string, string> {
  const timestamp = Math.floor(Date.now() / 1000);
  const signature = sign(body, timestamp, secret);
  return {
    "X-Internal-Signature": signature,
    "X-Internal-Timestamp": String(timestamp),
    "Content-Type": "application/json",
  };
}
