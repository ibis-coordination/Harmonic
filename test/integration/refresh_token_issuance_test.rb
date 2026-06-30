require "test_helper"

# Issuance of long-lived refresh tokens. The only site that mints a token is
# TwoFactorAuthController#verify_submit (i.e. after the user has actually
# passed 2FA on this device).
#
# OAuth callback for a user without 2FA enrolled does NOT mint a token, by
# design: a refresh token represents "this device passed 2FA recently", and
# handing one to a non-2FA user would silently re-auth them indefinitely if
# they later enabled 2FA — a 2FA bypass through the refresh-token cookie.
# Users without 2FA continue to redo the OAuth bounce on session expiry; only
# users with 2FA get silent re-auth.
#
# Setup uses OmniAuth test mode to drive the real oauth_callback through.
class RefreshTokenIssuanceTest < ActionDispatch::IntegrationTest
  REFRESH_COOKIE = ApplicationController::REFRESH_COOKIE_NAME

  setup do
    @tenant = create_tenant(subdomain: "rt-#{SecureRandom.hex(4)}", name: "RT Tenant")
    OmniAuth.config.test_mode = true
    host! "#{ENV.fetch("AUTH_SUBDOMAIN", nil)}.#{ENV.fetch("HOSTNAME", nil)}"
    cookies[:redirect_to_subdomain] = @tenant.subdomain
  end

  teardown do
    OmniAuth.config.test_mode = false
    OmniAuth.config.mock_auth[:github] = nil
  end

  def github_auth(email:)
    uid = SecureRandom.hex(6)
    OmniAuth::AuthHash.new(
      provider: "github",
      uid: uid,
      info: {
        email: email,
        name: "RT User",
        nickname: "rt-#{uid}",
        urls: { "GitHub" => "https://github.com/rt-#{uid}" },
      }
    )
  end

  def trigger_oauth_callback(auth)
    OmniAuth.config.mock_auth[:github] = auth
    get "/auth/github/callback"
  end

  # === OAuth callback ===

  test "OAuth callback for a user without 2FA does NOT issue a refresh token (2FA-bypass guard)" do
    email = "rt-nootp-#{SecureRandom.hex(4)}@example.com"

    assert_no_difference "RefreshToken.count" do
      trigger_oauth_callback(github_auth(email: email))
    end
    assert_nil cookies[REFRESH_COOKIE],
               "refresh token must not be issued unless 2FA was passed on this device"
  end

  # === OAuth callback with 2FA pending ===

  test "OAuth callback for a 2FA-enabled user does NOT issue a refresh token yet" do
    user = create_user(email: "rt-pending-#{SecureRandom.hex(4)}@example.com", name: "Pending 2FA")
    omni = user.find_or_create_omni_auth_identity!
    omni.generate_otp_secret!
    omni.enable_otp!

    assert_no_difference "RefreshToken.count" do
      trigger_oauth_callback(github_auth(email: user.email))
    end
    assert_nil cookies[REFRESH_COOKIE],
               "no refresh token should be issued before the 2FA challenge is completed"
  end

  # === 2FA verify_submit ===

  test "2FA verify_submit issues a refresh token with two_factor_at set to ~now" do
    user = create_user(email: "rt-otp-#{SecureRandom.hex(4)}@example.com", name: "2FA Done")
    omni = user.find_or_create_omni_auth_identity!
    omni.generate_otp_secret!
    omni.enable_otp!
    trigger_oauth_callback(github_auth(email: user.email))

    totp = ROTP::TOTP.new(omni.otp_secret)
    assert_difference "RefreshToken.count", 1 do
      post "/login/verify-2fa", params: { code: totp.now }
    end

    token = RefreshToken.where(user: user).last
    assert_not_nil token
    assert_in_delta Time.current.to_i, T.must(token.two_factor_at).to_i, 5
    assert_not_nil cookies[REFRESH_COOKIE]
  end

  test "2FA verify_submit with an invalid TOTP code does NOT issue a refresh token" do
    user = create_user(email: "rt-badotp-#{SecureRandom.hex(4)}@example.com", name: "Bad TOTP")
    omni = user.find_or_create_omni_auth_identity!
    omni.generate_otp_secret!
    omni.enable_otp!
    trigger_oauth_callback(github_auth(email: user.email))

    assert_no_difference "RefreshToken.count" do
      post "/login/verify-2fa", params: { code: "000000" }
    end
    assert_nil cookies[REFRESH_COOKIE]
  end

  # === Defensive: non-human users ===

  test "issue helper is a no-op for non-human users (defensive — should not be reachable in practice)" do
    # AI agents never go through OAuth/2FA login flows, but the helper guards
    # against accidental misuse so a non-human session establishment can't
    # mint a refresh token even if a future code path forgets the gate.
    controller = ApplicationController.new
    request = ActionDispatch::TestRequest.create
    controller.instance_variable_set(:@_request, request)

    _t, _c, parent = create_tenant_collective_user
    agent = create_ai_agent(parent: parent)

    assert_no_difference "RefreshToken.count" do
      result = controller.send(:issue_refresh_token_for!, agent)
      assert_nil result
    end
  end
end
