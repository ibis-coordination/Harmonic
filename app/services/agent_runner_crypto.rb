# typed: true
# frozen_string_literal: true

# Symmetric encryption for agent-runner service communication.
# Uses AES-256-GCM with an HKDF-derived key from the shared secret.
# The encryption key is derived separately from the HMAC signing key
# so that compromising one doesn't compromise the other.
class AgentRunnerCrypto
  extend T::Sig

  ALGORITHM = "aes-256-gcm"
  IV_LENGTH = 12
  AUTH_TAG_LENGTH = 16
  # HKDF info string — distinct from HMAC usage to derive a separate key
  HKDF_INFO = "agent-runner-token-encryption"

  sig { params(plaintext: String).returns(String) }
  def self.encrypt(plaintext)
    secret = ENV.fetch("AGENT_RUNNER_SECRET")
    key = derive_key(secret)

    cipher = OpenSSL::Cipher.new(ALGORITHM)
    cipher.encrypt
    cipher.key = key
    iv = cipher.random_iv
    cipher.auth_data = ""

    ciphertext = cipher.update(plaintext) + cipher.final
    auth_tag = cipher.auth_tag(AUTH_TAG_LENGTH)

    # Pack as: iv (12 bytes) + auth_tag (16 bytes) + ciphertext, then base64
    Base64.strict_encode64(iv + auth_tag + ciphertext)
  end

  sig { params(encoded: String).returns(String) }
  def self.decrypt(encoded)
    secret = ENV.fetch("AGENT_RUNNER_SECRET")
    key = derive_key(secret)

    raw = Base64.strict_decode64(encoded)
    iv = raw[0, IV_LENGTH]
    auth_tag = raw[IV_LENGTH, AUTH_TAG_LENGTH]
    ciphertext = raw[(IV_LENGTH + AUTH_TAG_LENGTH)..]

    cipher = OpenSSL::Cipher.new(ALGORITHM)
    cipher.decrypt
    cipher.key = key
    cipher.iv = T.must(iv)
    cipher.auth_tag = T.must(auth_tag)
    cipher.auth_data = ""

    cipher.update(T.must(ciphertext)) + cipher.final
  end

  sig { params(secret: String).returns(String) }
  def self.derive_key(secret)
    # HKDF: extract-then-expand to derive a 32-byte key
    OpenSSL::KDF.hkdf(
      secret,
      salt: "",
      info: HKDF_INFO,
      length: 32,
      hash: "sha256",
    )
  end

  private_class_method :derive_key
end
