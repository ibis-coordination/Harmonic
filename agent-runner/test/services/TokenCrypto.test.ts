import { describe, it, expect } from "vitest";
import { decryptToken } from "../../src/services/TokenCrypto.js";
import { createCipheriv, hkdfSync } from "node:crypto";

const TEST_SECRET = "test-secret-for-crypto";
const HKDF_INFO = "agent-runner-token-encryption";

/**
 * Encrypt a token using the same algorithm as Rails AgentRunnerCrypto.encrypt.
 * Used for testing only — in production, encryption happens in Rails.
 */
function encryptToken(plaintext: string, secret: string): string {
  const key = Buffer.from(hkdfSync("sha256", secret, "", HKDF_INFO, 32));
  const iv = Buffer.alloc(12);
  // Use deterministic IV for testing (production uses random)
  iv.fill(0);
  iv[0] = 1;

  const cipher = createCipheriv("aes-256-gcm", key, iv);
  cipher.setAAD(Buffer.alloc(0));
  const encrypted = Buffer.concat([cipher.update(plaintext, "utf8"), cipher.final()]);
  const authTag = cipher.getAuthTag();

  // Pack as: iv (12 bytes) + auth_tag (16 bytes) + ciphertext, then base64
  return Buffer.concat([iv, authTag, encrypted]).toString("base64");
}

describe("decryptToken", () => {
  it("decrypts a token encrypted with the same algorithm", () => {
    const plaintext = "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2";
    const encrypted = encryptToken(plaintext, TEST_SECRET);
    const result = decryptToken(encrypted, TEST_SECRET);
    expect(result).toBe(plaintext);
  });

  it("fails with wrong secret", () => {
    const plaintext = "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2";
    const encrypted = encryptToken(plaintext, TEST_SECRET);
    expect(() => decryptToken(encrypted, "wrong-secret")).toThrow();
  });

  it("fails with tampered ciphertext", () => {
    const plaintext = "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2";
    const encrypted = encryptToken(plaintext, TEST_SECRET);
    // Tamper with one character in the base64
    const tampered = encrypted.slice(0, -2) + "XX";
    expect(() => decryptToken(tampered, TEST_SECRET)).toThrow();
  });

  it("handles short tokens", () => {
    const plaintext = "short";
    const encrypted = encryptToken(plaintext, TEST_SECRET);
    const result = decryptToken(encrypted, TEST_SECRET);
    expect(result).toBe(plaintext);
  });
});
