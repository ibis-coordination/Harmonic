require "test_helper"

# Revocation paths that kill refresh tokens:
#   * Explicit logout — revoke the current device's token only
#   * 2FA disabled — revoke ALL of the user's tokens (device-trust gone)
#   * Password changed — revoke ALL of the user's tokens
#
# Each test stages a refresh token directly (the issuance flow is covered
# in RefreshTokenIssuanceTest) and drives the action that should kill it.
class RefreshTokenRevocationTest < ActionDispatch::IntegrationTest
  REFRESH_COOKIE = ApplicationController::REFRESH_COOKIE_NAME

  setup do
    @tenant = create_tenant(subdomain: "rtr-#{SecureRandom.hex(4)}")
    # Allow 2FA disable in tests — default tenants require_2fa, which would
    # block the disable endpoint before our revocation hook runs.
    @tenant.settings["require_2fa"] = "false"
    @tenant.save!
    @user = create_user(email: "rtr-#{SecureRandom.hex(4)}@example.com", name: "RTR User")
    @tenant.add_user!(@user)
    @tenant.create_main_collective!(created_by: @user)

    @omni = OmniAuthIdentity.create!(
      user: @user,
      email: @user.email,
      name: @user.name,
      password: "validpassword123",
      password_confirmation: "validpassword123",
    )
    @omni.update!(email_confirmed_at: Time.current)
    @omni.generate_otp_secret!
    @omni.enable_otp!
  end

  # === Logout ===

  test "logout revokes the current device's refresh token" do
    sign_in_as(@user, tenant: @tenant)
    this_device = RefreshToken.issue!(user: @user, two_factor_at: Time.current)
    other_device = RefreshToken.issue!(user: @user, two_factor_at: Time.current)
    cookies[REFRESH_COOKIE] = T.must(this_device.plaintext_token)

    delete "/logout"

    assert this_device.reload.revoked?, "current device's token must be revoked on logout"
    assert_equal "user_logout", this_device.revoked_reason
    refute other_device.reload.revoked?, "other devices' tokens must NOT be revoked on logout"
    assert_predicate cookies[REFRESH_COOKIE].to_s, :empty?, "refresh cookie must be cleared"
  end

  test "logout without a refresh cookie still succeeds (no token, no revoke)" do
    sign_in_as(@user, tenant: @tenant)
    other_device = RefreshToken.issue!(user: @user, two_factor_at: Time.current)
    delete "/logout"
    refute other_device.reload.revoked?
  end

  test "logout with a refresh cookie whose digest matches no token still clears the cookie" do
    sign_in_as(@user, tenant: @tenant)
    untouched = RefreshToken.issue!(user: @user, two_factor_at: Time.current)
    cookies[REFRESH_COOKIE] = "this-string-hashes-to-no-stored-digest"
    delete "/logout"
    refute untouched.reload.revoked?, "unrelated tokens must not be revoked"
    assert_predicate cookies[REFRESH_COOKIE].to_s, :empty?, "the bogus cookie must still be cleared"
  end

  # === 2FA disabled ===

  test "disabling 2FA revokes ALL of the user's refresh tokens" do
    sign_in_as(@user, tenant: @tenant)
    this_device = RefreshToken.issue!(user: @user, two_factor_at: Time.current)
    other_device = RefreshToken.issue!(user: @user, two_factor_at: Time.current)
    cookies[REFRESH_COOKIE] = T.must(this_device.plaintext_token)

    @omni.reload
    totp = ROTP::TOTP.new(@omni.otp_secret)
    post "/settings/two-factor/disable", params: { code: totp.now }
    assert this_device.reload.revoked?, "current device's token must be revoked"
    assert other_device.reload.revoked?, "ALL tokens must be revoked when 2FA is disabled"
    assert_equal "two_factor_disabled", this_device.revoked_reason
    assert_equal "two_factor_disabled", other_device.revoked_reason
  end

  test "failed 2FA disable does NOT revoke any tokens" do
    sign_in_as(@user, tenant: @tenant)
    token = RefreshToken.issue!(user: @user, two_factor_at: Time.current)
    post "/settings/two-factor/disable", params: { code: "000000" }
    refute token.reload.revoked?
  end

  # === Password change ===

  test "completing a password reset revokes ALL of the user's refresh tokens" do
    # Drive the real password-reset flow: request token, submit new password.
    token = @omni.generate_reset_password_token!
    this_device = RefreshToken.issue!(user: @user, two_factor_at: Time.current)
    other_device = RefreshToken.issue!(user: @user, two_factor_at: Time.current)

    host! "#{ENV.fetch("AUTH_SUBDOMAIN", nil)}.#{ENV.fetch("HOSTNAME", nil)}"
    patch "/password/reset/#{token}",
          params: { password: "newvalidpassword123", password_confirmation: "newvalidpassword123" }

    assert this_device.reload.revoked?
    assert other_device.reload.revoked?
    assert_equal "password_change", this_device.revoked_reason
  end

  test "failed password reset (mismatched confirmation) does NOT revoke any tokens" do
    token = @omni.generate_reset_password_token!
    rt = RefreshToken.issue!(user: @user, two_factor_at: Time.current)

    host! "#{ENV.fetch("AUTH_SUBDOMAIN", nil)}.#{ENV.fetch("HOSTNAME", nil)}"
    patch "/password/reset/#{token}",
          params: { password: "newvalidpassword123", password_confirmation: "WRONG" }

    refute rt.reload.revoked?
  end
end
