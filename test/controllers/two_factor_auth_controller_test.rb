require "test_helper"

class TwoFactorAuthControllerTest < ActionDispatch::IntegrationTest
  setup do
    @tenant, @collective, @existing_user = create_tenant_studio_user

    # Create a user with email that will have an OmniAuthIdentity
    test_email = "2fa-controller-test-#{SecureRandom.hex(4)}@example.com"
    @user = create_user(email: test_email, name: "2FA Controller Test User")
    @tenant.add_user!(@user)

    @identity = OmniAuthIdentity.create!(
      email: test_email,
      name: "2FA Controller Test User",
      password: "validpassword123",
      password_confirmation: "validpassword123",
    )

    # Create a matching OauthIdentity (links to user via provider/uid)
    @oauth_identity = OauthIdentity.create!(
      provider: "identity",
      uid: @identity.id.to_s,
      user: @user,
    )

    host! "auth.#{ENV.fetch("HOSTNAME", nil)}"
  end

  # === Verify Page Access ===

  test "verify page requires pending 2fa session" do
    get two_factor_verify_path
    assert_redirected_to "/login"
  end

  test "2fa is enabled and verification flow works" do
    # This test verifies the core 2FA verification logic via model methods
    # The full OAuth integration is tested via E2E tests
    @identity.generate_otp_secret!
    @identity.enable_otp!

    totp = ROTP::TOTP.new(@identity.otp_secret)

    # Valid TOTP code should verify
    assert @identity.verify_otp(totp.now)

    # Invalid code should fail and increment attempts
    initial_attempts = @identity.otp_failed_attempts
    assert_not @identity.verify_otp("000000")
    assert_equal initial_attempts + 1, @identity.reload.otp_failed_attempts
  end

  # === Setup Flow ===

  test "setup page requires login" do
    get two_factor_setup_path
    assert_redirected_to "/login"
  end

  test "settings page requires login" do
    get two_factor_settings_path
    assert_redirected_to "/login"
  end

  # === Verification Tests ===

  test "verify with correct TOTP code succeeds" do
    @identity.generate_otp_secret!
    @identity.enable_otp!
    totp = ROTP::TOTP.new(@identity.otp_secret)

    # Set up pending 2FA session
    session_data = {
      pending_2fa_identity_id: @identity.id,
      pending_2fa_started_at: Time.current.to_i,
    }
    cookies[:redirect_to_subdomain] = @tenant.subdomain

    # This simulates the post to verify with session set
    # In reality, the session is set by oauth_callback
    # For this test, we'll verify the model methods work
    assert @identity.verify_otp(totp.now)
  end

  test "verify with recovery code succeeds" do
    @identity.generate_otp_secret!
    codes = @identity.generate_recovery_codes!
    @identity.enable_otp!

    # Verify recovery code consumption
    assert @identity.verify_recovery_code(codes.first)
    assert_equal 9, @identity.remaining_recovery_codes_count
  end

  test "verify with invalid code fails" do
    @identity.generate_otp_secret!
    @identity.enable_otp!

    assert_not @identity.verify_otp("000000")
    assert_equal 1, @identity.reload.otp_failed_attempts
  end

  test "account locks after max failed attempts" do
    @identity.generate_otp_secret!
    @identity.enable_otp!

    OmniAuthIdentity::MAX_OTP_ATTEMPTS.times do
      @identity.verify_otp("000000")
    end

    assert @identity.otp_locked?
  end

  # === Enable/Disable Flow ===

  test "enable 2fa sets correct flags" do
    @identity.generate_otp_secret!
    @identity.enable_otp!

    assert @identity.otp_enabled
    assert @identity.otp_enabled_at.present?
  end

  test "disable 2fa clears all data" do
    @identity.generate_otp_secret!
    @identity.generate_recovery_codes!
    @identity.enable_otp!

    @identity.disable_otp!

    assert_not @identity.otp_enabled
    assert_nil @identity.otp_secret
    assert_equal [], @identity.otp_recovery_codes
  end
end
