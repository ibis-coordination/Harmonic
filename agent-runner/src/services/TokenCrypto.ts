/**
 * Symmetric decryption for agent tokens received via Redis stream.
 * Matches the Ruby AgentRunnerCrypto implementation:
 * AES-256-GCM with HKDF-derived key from the shared secret.
 */

import { createDecipheriv, hkdfSync } from "node:crypto";

const IV_LENGTH = 12;
const AUTH_TAG_LENGTH = 16;
const HKDF_INFO = "agent-runner-token-encryption";

/**
 * Derive the 32-byte encryption key from the shared secret using HKDF.
 */
function deriveKey(secret: string): Buffer {
  // hkdfSync(digest, ikm, salt, info, keylen)
  const key = hkdfSync("sha256", secret, "", HKDF_INFO, 32);
  return Buffer.from(key);
}

/**
 * Decrypt a token that was encrypted by Rails AgentRunnerCrypto.encrypt.
 * Input is base64-encoded: iv (12 bytes) + auth_tag (16 bytes) + ciphertext.
 */
export function decryptToken(encoded: string, secret: string): string {
  const key = deriveKey(secret);
  const raw = Buffer.from(encoded, "base64");

  const iv = raw.subarray(0, IV_LENGTH);
  const authTag = raw.subarray(IV_LENGTH, IV_LENGTH + AUTH_TAG_LENGTH);
  const ciphertext = raw.subarray(IV_LENGTH + AUTH_TAG_LENGTH);

  const decipher = createDecipheriv("aes-256-gcm", key, iv);
  decipher.setAuthTag(authTag);
  decipher.setAAD(Buffer.alloc(0));

  const decrypted = Buffer.concat([decipher.update(ciphertext), decipher.final()]);
  return decrypted.toString("utf8");
}
