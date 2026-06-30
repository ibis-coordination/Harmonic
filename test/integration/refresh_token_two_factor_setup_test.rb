require "test_helper"

# Refresh-token issuance when the user enables 2FA for the first time
# (`TwoFactorAuthController#confirm_setup`). Separate file from
# refresh_token_issuance_test.rb because that file's setup hosts on the
# auth subdomain for OAuth-bounce tests, which fights with sign_in_as.
class RefreshTokenTwoFactorSetupTest < ActionDispatch::IntegrationTest
  REFRESH_COOKIE = ApplicationController::REFRESH_COOKIE_NAME

  setup do
    @tenant = create_tenant(subdomain: "rts-#{SecureRandom.hex(4)}")
    @tenant.settings["require_2fa"] = "false"
    @tenant.save!
    @user = create_user(email: "rts-#{SecureRandom.hex(4)}@example.com", name: "Setup User")
    @tenant.add_user!(@user)
    @tenant.create_main_collective!(created_by: @user)
  end

  test "completing 2FA setup mints a refresh token so 'Devices' is populated immediately" do
    # sign_in_as activates the user (which enables OTP). Use activate: false
    # so we can drive the actual setup flow.
    sign_in_as(@user, tenant: @tenant, activate: false)

    # Mark the email confirmed so the activation gate doesn't bounce us
    # before we reach /settings/two-factor/confirm.
    identity = @user.find_or_create_omni_auth_identity!
    identity.update!(email_confirmed_at: Time.current)

    # GET /settings/two-factor generates the OTP secret (server-side state
    # that confirm_setup verifies against).
    get "/settings/two-factor"
    identity.reload

    totp = ROTP::TOTP.new(identity.otp_secret)
    assert_difference "RefreshToken.count", 1 do
      post "/settings/two-factor/confirm", params: { code: totp.now }
    end

    token = RefreshToken.where(user: @user).last
    assert_not_nil token
    assert_in_delta Time.current.to_i, T.must(token.two_factor_at).to_i, 5
    assert_not_nil cookies[REFRESH_COOKIE],
                   "refresh cookie must be set so the user's current browser is in their Devices list"
  end

  test "failed 2FA setup (wrong code) does NOT issue a refresh token" do
    sign_in_as(@user, tenant: @tenant, activate: false)
    identity = @user.find_or_create_omni_auth_identity!
    identity.update!(email_confirmed_at: Time.current)
    get "/settings/two-factor"

    assert_no_difference "RefreshToken.count" do
      post "/settings/two-factor/confirm", params: { code: "000000" }
    end
    assert_nil cookies[REFRESH_COOKIE]
  end
end
