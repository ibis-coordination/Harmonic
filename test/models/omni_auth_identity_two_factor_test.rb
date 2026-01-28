require "test_helper"

class OmniAuthIdentityTwoFactorTest < ActiveSupport::TestCase
  setup do
    @identity = OmniAuthIdentity.create!(
      email: "2fa-test@example.com",
      name: "2FA Test User",
      password: "validpassword123",
      password_confirmation: "validpassword123",
    )
  end

  # === OTP Secret Generation ===

  test "generate_otp_secret! creates a valid base32 secret" do
    secret = @identity.generate_otp_secret!

    assert secret.present?
    assert_equal secret, @identity.otp_secret
    # ROTP Base32 secrets are typically 32 characters
    assert secret.length >= 16, "OTP secret should be at least 16 characters"
    # Should be valid base32
    assert secret.match?(/\A[A-Z2-7]+\z/), "OTP secret should be valid base32"
  end

  test "generate_otp_secret! persists the secret" do
    @identity.generate_otp_secret!

    reloaded = OmniAuthIdentity.find(@identity.id)
    assert_equal @identity.otp_secret, reloaded.otp_secret
  end

  # === OTP Provisioning URI ===

  test "otp_provisioning_uri generates valid URI" do
    @identity.generate_otp_secret!
    uri = @identity.otp_provisioning_uri

    assert uri.start_with?("otpauth://totp/")
    assert_includes uri, URI.encode_www_form_component(@identity.email)
    assert_includes uri, "issuer=Harmonic"
    assert_includes uri, "secret=#{@identity.otp_secret}"
  end

  # === OTP Verification ===

  test "verify_otp returns true for valid code" do
    @identity.generate_otp_secret!
    totp = ROTP::TOTP.new(@identity.otp_secret)
    valid_code = totp.now

    assert @identity.verify_otp(valid_code)
  end

  test "verify_otp returns false for invalid code" do
    @identity.generate_otp_secret!

    assert_not @identity.verify_otp("000000")
  end

  test "verify_otp returns false when no secret is set" do
    assert_not @identity.verify_otp("123456")
  end

  test "verify_otp resets failed attempts on success" do
    @identity.generate_otp_secret!
    @identity.update!(otp_failed_attempts: 3)

    totp = ROTP::TOTP.new(@identity.otp_secret)
    @identity.verify_otp(totp.now)

    assert_equal 0, @identity.otp_failed_attempts
  end

  test "verify_otp increments failed attempts on failure" do
    @identity.generate_otp_secret!
    initial_attempts = @identity.otp_failed_attempts

    @identity.verify_otp("000000")

    assert_equal initial_attempts + 1, @identity.otp_failed_attempts
  end

  test "verify_otp returns false when locked" do
    @identity.generate_otp_secret!
    @identity.update!(otp_locked_until: 1.hour.from_now)

    totp = ROTP::TOTP.new(@identity.otp_secret)
    valid_code = totp.now

    assert_not @identity.verify_otp(valid_code)
  end

  # === Recovery Codes ===

  test "generate_recovery_codes! creates 10 codes" do
    codes = @identity.generate_recovery_codes!

    assert_equal OmniAuthIdentity::RECOVERY_CODE_COUNT, codes.length
    assert_equal OmniAuthIdentity::RECOVERY_CODE_COUNT, @identity.otp_recovery_codes.length
  end

  test "generate_recovery_codes! returns uppercase hex codes" do
    codes = @identity.generate_recovery_codes!

    codes.each do |code|
      assert_equal 16, code.length, "Recovery code should be 16 characters"
      assert code.match?(/\A[A-F0-9]+\z/), "Recovery code should be uppercase hex"
    end
  end

  test "generate_recovery_codes! stores hashes not plaintext" do
    codes = @identity.generate_recovery_codes!

    @identity.otp_recovery_codes.each_with_index do |stored, i|
      expected_hash = Digest::SHA256.hexdigest(codes[i])
      assert_equal expected_hash, stored["hash"]
      assert_nil stored["used_at"]
    end
  end

  test "verify_recovery_code returns true and marks code as used" do
    codes = @identity.generate_recovery_codes!
    code_to_use = codes.first

    assert @identity.verify_recovery_code(code_to_use)

    # Check that the code is marked as used
    @identity.reload
    used_code = @identity.otp_recovery_codes.find { |c| c["hash"] == Digest::SHA256.hexdigest(code_to_use) }
    assert used_code["used_at"].present?
  end

  test "verify_recovery_code returns false for already used code" do
    codes = @identity.generate_recovery_codes!
    code_to_use = codes.first

    # Use it once
    assert @identity.verify_recovery_code(code_to_use)

    # Try to use it again
    assert_not @identity.verify_recovery_code(code_to_use)
  end

  test "verify_recovery_code returns false for invalid code" do
    @identity.generate_recovery_codes!

    assert_not @identity.verify_recovery_code("INVALIDCODE12345")
  end

  test "verify_recovery_code handles whitespace and lowercase" do
    codes = @identity.generate_recovery_codes!
    code = codes.first

    # Should work with lowercase and spaces
    formatted_code = code.downcase.insert(4, " ").insert(9, " ").insert(14, " ")

    assert @identity.verify_recovery_code(formatted_code)
  end

  test "verify_recovery_code resets failed attempts on success" do
    codes = @identity.generate_recovery_codes!
    @identity.update!(otp_failed_attempts: 3)

    @identity.verify_recovery_code(codes.first)

    assert_equal 0, @identity.otp_failed_attempts
  end

  test "verify_recovery_code returns false when locked" do
    codes = @identity.generate_recovery_codes!
    @identity.update!(otp_locked_until: 1.hour.from_now)

    assert_not @identity.verify_recovery_code(codes.first)
  end

  test "remaining_recovery_codes_count returns correct count" do
    codes = @identity.generate_recovery_codes!
    assert_equal 10, @identity.remaining_recovery_codes_count

    @identity.verify_recovery_code(codes[0])
    assert_equal 9, @identity.remaining_recovery_codes_count

    @identity.verify_recovery_code(codes[1])
    assert_equal 8, @identity.remaining_recovery_codes_count
  end

  test "remaining_recovery_codes_count returns 0 when no codes" do
    assert_equal 0, @identity.remaining_recovery_codes_count
  end

  # === Lockout Behavior ===

  test "otp_locked? returns false when not locked" do
    assert_not @identity.otp_locked?
  end

  test "otp_locked? returns true when locked" do
    @identity.update!(otp_locked_until: 1.hour.from_now)

    assert @identity.otp_locked?
  end

  test "otp_locked? returns false when lock has expired" do
    @identity.update!(otp_locked_until: 1.hour.ago)

    assert_not @identity.otp_locked?
  end

  test "increment_otp_failed_attempts! locks account after max attempts" do
    @identity.generate_otp_secret!

    # Fail MAX_OTP_ATTEMPTS times
    OmniAuthIdentity::MAX_OTP_ATTEMPTS.times do
      @identity.verify_otp("000000")
    end

    assert @identity.otp_locked?
    assert @identity.otp_locked_until > Time.current
  end

  test "reset_otp_failed_attempts! clears attempts and unlocks" do
    @identity.update!(
      otp_failed_attempts: 5,
      otp_locked_until: 1.hour.from_now,
    )

    @identity.reset_otp_failed_attempts!

    assert_equal 0, @identity.otp_failed_attempts
    assert_nil @identity.otp_locked_until
  end

  # === Enable/Disable 2FA ===

  test "enable_otp! sets enabled flag and timestamp" do
    @identity.generate_otp_secret!

    @identity.enable_otp!

    assert @identity.otp_enabled
    assert @identity.otp_enabled_at.present?
  end

  test "disable_otp! clears all 2FA data" do
    @identity.generate_otp_secret!
    @identity.generate_recovery_codes!
    @identity.enable_otp!
    @identity.update!(otp_failed_attempts: 3, otp_locked_until: 1.hour.from_now)

    @identity.disable_otp!

    assert_not @identity.otp_enabled
    assert_nil @identity.otp_enabled_at
    assert_nil @identity.otp_secret
    assert_equal [], @identity.otp_recovery_codes
    assert_equal 0, @identity.otp_failed_attempts
    assert_nil @identity.otp_locked_until
  end

  # === Constants ===

  test "constants are defined correctly" do
    assert_equal "Harmonic", OmniAuthIdentity::OTP_ISSUER
    assert_equal 10, OmniAuthIdentity::RECOVERY_CODE_COUNT
    assert_equal 5, OmniAuthIdentity::MAX_OTP_ATTEMPTS
    assert_equal 15.minutes, OmniAuthIdentity::OTP_LOCKOUT_DURATION
  end
end
