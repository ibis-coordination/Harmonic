# typed: true

class OmniAuthIdentity < OmniAuth::Identity::Models::ActiveRecord
  extend T::Sig

  # Load common passwords list for validation
  COMMON_PASSWORDS_FILE = Rails.root.join("config", "common_passwords.txt")
  COMMON_PASSWORDS = T.let(
    if File.exist?(COMMON_PASSWORDS_FILE)
      Set.new(
        File.readlines(COMMON_PASSWORDS_FILE)
            .map(&:strip)
            .reject { |line| line.empty? || line.start_with?("#") }
            .map(&:downcase)
      )
    else
      Set.new
    end,
    T::Set[String]
  )

  auth_key :email
  validate :password_valid?
  validate :password_not_common

  # Password reset functionality
  # Tokens are stored as SHA256 hashes for security - if the database is compromised,
  # attackers cannot use the hashed tokens to reset passwords.
  sig { returns(String) }
  def generate_reset_password_token!
    raw_token = SecureRandom.urlsafe_base64(32)
    self.reset_password_token = Digest::SHA256.hexdigest(raw_token)
    self.reset_password_sent_at = T.cast(Time.current, ActiveSupport::TimeWithZone)
    save!
    raw_token # Return raw token for email
  end

  sig { returns(T::Boolean) }
  def reset_password_token_valid?
    reset_password_sent_at.present? && T.must(reset_password_sent_at) > 2.hours.ago
  end

  sig { void }
  def clear_reset_password_token!
    self.reset_password_token = nil
    self.reset_password_sent_at = nil
    save!
  end

  sig { params(raw_token: T.nilable(String)).returns(T.nilable(OmniAuthIdentity)) }
  def self.find_by_reset_password_token(raw_token)
    return nil if raw_token.blank?
    hashed_token = Digest::SHA256.hexdigest(raw_token)
    find_by(reset_password_token: hashed_token)
  end

  sig { params(new_password: String).void }
  def update_password!(new_password)
    self.password = new_password
    self.password_confirmation = new_password
    clear_reset_password_token!
    save!
  end

  sig { void }
  def password_valid?
    # Passwords themselves are not persisted in the database, only the digest.
    # If password is nil and password_digest is not nil, that means the record has already been saved in the db.
    return if password.nil? && password_digest.present?
    return if password.present? && password.length >= 14

    errors.add(:password, "must be at least 14 characters long")
  end

  sig { void }
  def password_not_common
    return if password.nil?
    return if password_digest.present? && !password_digest_changed?

    if COMMON_PASSWORDS.include?(password.downcase)
      errors.add(:password, "is too common. Please choose a more unique password.")
    end
  end

  # =============================================================================
  # Two-Factor Authentication (TOTP)
  # =============================================================================

  OTP_ISSUER = "Harmonic"
  RECOVERY_CODE_COUNT = 10
  MAX_OTP_ATTEMPTS = 5
  OTP_LOCKOUT_DURATION = 15.minutes

  # Generate a new OTP secret for 2FA setup
  sig { returns(String) }
  def generate_otp_secret!
    self.otp_secret = ROTP::Base32.random
    save!
    T.must(otp_secret)
  end

  # Get the provisioning URI for QR code generation
  sig { returns(String) }
  def otp_provisioning_uri
    totp = ROTP::TOTP.new(otp_secret, issuer: OTP_ISSUER)
    totp.provisioning_uri(email)
  end

  # Verify a TOTP code
  sig { params(code: String).returns(T::Boolean) }
  def verify_otp(code)
    return false if otp_secret.blank?
    return false if otp_locked?

    totp = ROTP::TOTP.new(otp_secret, issuer: OTP_ISSUER)
    # drift_behind and drift_ahead allow for 30 seconds of clock drift
    if totp.verify(code, drift_behind: 30, drift_ahead: 30)
      reset_otp_failed_attempts!
      true
    else
      increment_otp_failed_attempts!
      false
    end
  end

  # Generate new recovery codes
  sig { returns(T::Array[String]) }
  def generate_recovery_codes!
    codes = RECOVERY_CODE_COUNT.times.map { SecureRandom.hex(8).upcase }
    hashed_codes = codes.map do |code|
      { "hash" => Digest::SHA256.hexdigest(code), "used_at" => nil }
    end
    self.otp_recovery_codes = hashed_codes
    save!
    codes # Return plaintext codes to show user once
  end

  # Verify and consume a recovery code
  sig { params(code: String).returns(T::Boolean) }
  def verify_recovery_code(code)
    return false if otp_recovery_codes.blank?
    return false if otp_locked?

    code_hash = Digest::SHA256.hexdigest(code.upcase.gsub(/\s/, ""))
    codes = otp_recovery_codes.dup

    matching_index = codes.find_index do |c|
      c["hash"] == code_hash && c["used_at"].nil?
    end

    if matching_index
      codes[matching_index]["used_at"] = Time.current.iso8601
      self.otp_recovery_codes = codes
      reset_otp_failed_attempts!
      save!
      true
    else
      increment_otp_failed_attempts!
      false
    end
  end

  # Count remaining unused recovery codes
  sig { returns(Integer) }
  def remaining_recovery_codes_count
    return 0 if otp_recovery_codes.blank?
    otp_recovery_codes.count { |c| c["used_at"].nil? }
  end

  # Check if account is locked due to too many failed attempts
  sig { returns(T::Boolean) }
  def otp_locked?
    otp_locked_until.present? && otp_locked_until > Time.current
  end

  # Increment failed attempts and lock if threshold reached
  sig { void }
  def increment_otp_failed_attempts!
    new_count = otp_failed_attempts + 1
    self.otp_failed_attempts = new_count

    if new_count >= MAX_OTP_ATTEMPTS
      self.otp_locked_until = OTP_LOCKOUT_DURATION.from_now
    end

    save!
  end

  # Reset failed attempts counter and unlock
  sig { void }
  def reset_otp_failed_attempts!
    self.otp_failed_attempts = 0
    self.otp_locked_until = nil
    save!
  end

  # Enable 2FA after successful setup verification
  sig { void }
  def enable_otp!
    self.otp_enabled = true
    self.otp_enabled_at = Time.current
    save!
  end

  # Disable 2FA (requires valid code verification first)
  sig { void }
  def disable_otp!
    self.otp_enabled = false
    self.otp_enabled_at = nil
    self.otp_secret = nil
    self.otp_recovery_codes = []
    self.otp_failed_attempts = 0
    self.otp_locked_until = nil
    save!
  end
end
