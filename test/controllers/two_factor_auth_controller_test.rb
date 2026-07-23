require "test_helper"

class TwoFactorAuthControllerTest < ActionDispatch::IntegrationTest
  setup do
    @tenant, @collective, @existing_user = create_tenant_collective_user

    # Create a user with email that will have an OmniAuthIdentity
    test_email = "2fa-controller-test-#{SecureRandom.hex(4)}@example.com"
    @user = create_user(email: test_email, name: "2FA Controller Test User")
    @tenant.add_user!(@user)

    @identity = OmniAuthIdentity.create!(
      user: @user,
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

  # === Post-Setup Continue Destination ===

  test "GET settings hides the Disable section when the current tenant requires 2FA" do
    @tenant.update!(main_collective_id: @collective.id)
    @tenant.settings["require_2fa"] = true  # explicit; this is the default
    @tenant.save!
    user = create_user(email: "no-disable-#{SecureRandom.hex(4)}@example.com", name: "No Disable")
    user.find_or_create_omni_auth_identity!
    sign_in_as(user, tenant: @tenant)

    get two_factor_settings_path
    assert_response :success
    assert_no_match(%r{<form[^>]+action="/settings/two-factor/disable"}, response.body,
                    "expected the disable form to be hidden when the tenant requires 2FA")
  end

  test "GET settings shows the Disable section when the current tenant does not require 2FA" do
    @tenant.update!(main_collective_id: @collective.id)
    @tenant.settings["require_2fa"] = false
    @tenant.save!
    user = create_user(email: "can-disable-#{SecureRandom.hex(4)}@example.com", name: "Can Disable")
    user.find_or_create_omni_auth_identity!
    sign_in_as(user, tenant: @tenant)

    get two_factor_settings_path
    assert_response :success
    assert_match(%r{<form[^>]+action="/settings/two-factor/disable"}, response.body,
                 "expected the disable form to be present when the tenant doesn't require 2FA")
  end

  test "POST disable refuses when the current tenant requires 2FA (server-side guard)" do
    @tenant.update!(main_collective_id: @collective.id)
    # Default require_2fa = true
    user = create_user(email: "block-#{SecureRandom.hex(4)}@example.com", name: "Block User")
    identity = user.find_or_create_omni_auth_identity!
    identity.generate_otp_secret!
    identity.enable_otp!
    sign_in_as(user, tenant: @tenant)

    totp = ROTP::TOTP.new(identity.otp_secret)
    post two_factor_disable_path, params: { code: totp.now }

    assert_redirected_to two_factor_settings_path
    assert_match(/required/i, flash[:alert].to_s)
    assert identity.reload.otp_enabled,
           "expected 2FA to remain enabled — the tenant requires it"
  end

  test "POST disable with an array-valued code param is rejected cleanly, not a 500" do
    @tenant.update!(main_collective_id: @collective.id)
    @tenant.settings["require_2fa"] = "false"
    @tenant.save!
    user = create_user(email: "arraycode-#{SecureRandom.hex(4)}@example.com", name: "Array Code")
    identity = user.find_or_create_omni_auth_identity!
    identity.generate_otp_secret!
    identity.enable_otp!
    sign_in_as(user, tenant: @tenant)

    # Rails turns code[]=x into an Array; params[:code]&.strip would raise
    # NoMethodError (500). It must be treated as an invalid code instead.
    post two_factor_disable_path, params: { code: ["x"] }

    assert_redirected_to two_factor_settings_path
    assert_match(/invalid/i, flash[:alert].to_s)
    assert identity.reload.otp_enabled, "2FA must remain enabled after an invalid disable attempt"
  end

  test "post-setup Continue button defaults to the user's settings page" do
    # The shared setup uses create_tenant_collective_user, which doesn't set
    # main_collective_id — sign_in_as needs it to resolve current_collective.
    @tenant.update!(main_collective_id: @collective.id)
    user = create_user(email: "post2fa-#{SecureRandom.hex(4)}@example.com", name: "Post 2FA")
    # 2FA setup requires an OmniAuthIdentity (it's identity-provider-only).
    # The signup flow normally creates one; here we create it explicitly.
    user.find_or_create_omni_auth_identity!
    sign_in_as(user, tenant: @tenant, activate: false)
    # Visit setup to seed session[:pending_otp_secret], then complete it.
    get two_factor_setup_path
    secret = session[:pending_otp_secret]
    raise "expected pending_otp_secret to be seeded by GET setup" if secret.blank?
    totp = ROTP::TOTP.new(secret)
    post two_factor_confirm_path, params: { code: totp.now }

    expected_path = "/settings"
    assert_match(/href="#{Regexp.escape(expected_path)}"/, response.body,
                 "expected the Continue link to point to the user's settings page by default")
    assert_no_match(%r{href="/settings/two-factor/manage"}, response.body,
                    "should no longer default to the awkward 2FA management page")
  end

  # === Setup page mobile UX ===
  # Users signing up on their phone can't scan the QR code with the same
  # device, so the setup page must offer same-device paths: an otpauth://
  # deep link that opens the installed authenticator app, and a one-tap
  # copyable secret key.

  test "setup page offers an otpauth:// deep link to open the authenticator app" do
    @tenant.update!(main_collective_id: @collective.id)
    user = create_user(email: "deeplink-#{SecureRandom.hex(4)}@example.com", name: "Deep Link")
    user.find_or_create_omni_auth_identity!
    sign_in_as(user, tenant: @tenant, activate: false)

    get two_factor_setup_path

    assert_response :success
    assert_match(/href="otpauth:\/\//, response.body,
                 "expected an otpauth:// link so mobile users can open their authenticator app directly")
  end

  test "setup page shows the secret key with a copy button" do
    @tenant.update!(main_collective_id: @collective.id)
    user = create_user(email: "copykey-#{SecureRandom.hex(4)}@example.com", name: "Copy Key")
    user.find_or_create_omni_auth_identity!
    sign_in_as(user, tenant: @tenant, activate: false)

    get two_factor_setup_path

    assert_response :success
    secret = session[:pending_otp_secret]
    chunked = secret.scan(/.{4}/).join(" ")
    assert_match(/#{Regexp.escape(chunked)}/, response.body,
                 "expected the secret displayed in readable 4-character groups")
    assert_match(/data-action="click->clipboard#copy"/, response.body,
                 "expected a one-tap copy button for the secret")
    assert_match(/value="#{Regexp.escape(secret)}"/, response.body,
                 "expected the copy button to copy the raw secret without spaces")
  end

  test "recovery codes page presents Copy as the primary action" do
    @tenant.update!(main_collective_id: @collective.id)
    user = create_user(email: "reccopy-#{SecureRandom.hex(4)}@example.com", name: "Rec Copy")
    user.find_or_create_omni_auth_identity!
    sign_in_as(user, tenant: @tenant, activate: false)
    get two_factor_setup_path
    totp = ROTP::TOTP.new(session[:pending_otp_secret])

    post two_factor_confirm_path, params: { code: totp.now }

    assert_response :success
    assert_select "button.pulse-action-btn[data-action='recovery-codes#copy']", { count: 1 },
                  "Copy should be the primary button (downloads are flaky on mobile browsers)"
    assert_select "button.pulse-action-btn-secondary[data-action='recovery-codes#download']", { count: 1 },
                  "Download stays available as the secondary action"
  end

  # === Bot protection (honeypot only on verify_submit) ===

  test "POST /login/verify-2fa with filled honeypot is rejected by bot protection before any OTP check" do
    with_bot_protection do
      @identity.generate_otp_secret!
      @identity.enable_otp!
      initial_attempts = @identity.otp_failed_attempts

      # No pending_2fa session — but protect_from_bots runs BEFORE
      # require_pending_2fa, so a filled honeypot still trips the bot signal
      # and produces the "Submission could not be processed" alert.
      post two_factor_verify_path, params: { code: "000000", company_website: "spam" }

      assert_response :redirect
      assert_match(/could not be processed/i, flash[:alert])
      # OTP counter must not have advanced — the verify code never ran.
      assert_equal initial_attempts, @identity.reload.otp_failed_attempts
    end
  end

  private

  def with_bot_protection
    original_force = ENV["FORCE_BOT_PROTECTION_IN_TEST"]
    original_turnstile = ENV["TURNSTILE_SECRET_KEY"]
    ENV["FORCE_BOT_PROTECTION_IN_TEST"] = "1"
    ENV.delete("TURNSTILE_SECRET_KEY")
    yield
  ensure
    if original_force.nil?
      ENV.delete("FORCE_BOT_PROTECTION_IN_TEST")
    else
      ENV["FORCE_BOT_PROTECTION_IN_TEST"] = original_force
    end
    if original_turnstile.nil?
      ENV.delete("TURNSTILE_SECRET_KEY")
    else
      ENV["TURNSTILE_SECRET_KEY"] = original_turnstile
    end
  end
end
