require "test_helper"

# The absolute device-trust cap. Silent refresh silently re-authenticates a
# device from its refresh token, but a device trusted longer than
# RefreshToken::MAX_TRUST_LIFETIME (1 year, matching the API-token max lifetime)
# must re-authenticate rather than be re-authed indefinitely. `two_factor_at`
# marks the establishing 2FA login and is preserved verbatim across every
# rotation, so it anchors a true absolute cap — ordinary use does not extend it,
# only a fresh full login resets it.
#
# Redteam framing: a stolen refresh cookie must not grant unbounded access to an
# account — the cap bounds how long the theft stays useful even as the token
# rotates, and a legitimately long-lived session is periodically forced through
# a full re-login.
class RefreshTokenTwoFactorTrustTest < ActionDispatch::IntegrationTest
  REFRESH_COOKIE = ApplicationController::REFRESH_COOKIE_NAME

  setup do
    @tenant = create_tenant(subdomain: "rt2fa-#{SecureRandom.hex(4)}")
    @user = create_user(email: "rt2fa-#{SecureRandom.hex(4)}@example.com", name: "RT2FA User")
    @tenant.add_user!(@user)
    @tenant.create_main_collective!(created_by: @user)
    host! "#{@tenant.subdomain}.#{ENV.fetch("HOSTNAME", nil)}"
  end

  # Stage a live refresh token whose establishing 2FA login is `established_at`,
  # and present its cookie with NO browser session so a request must silent-refresh.
  def stage_token(established_at:)
    token = RefreshToken.issue!(user: @user, two_factor_at: Time.current)
    token.update_column(:two_factor_at, established_at)
    cookies[REFRESH_COOKIE] = T.must(token.plaintext_token)
    token
  end

  test "a token within the trust lifetime silently re-authenticates" do
    token = stage_token(established_at: 6.months.ago)

    get "/"

    assert token.reload.rotated?, "an in-lifetime token must silent-refresh (rotate) into a live session"
    refute token.revoked?, "an in-lifetime token must not be revoked"
    assert_not_nil cookies[REFRESH_COOKIE].presence, "the successor cookie must be set"
  end

  test "a token past the trust lifetime is revoked instead of silently re-authenticating" do
    token = stage_token(established_at: (RefreshToken::MAX_TRUST_LIFETIME + 1.day).ago)

    get "/"

    assert token.reload.revoked?, "a token past the trust lifetime must be revoked"
    assert_equal "trust_expired", token.revoked_reason
    refute token.rotated?, "an expired-trust token must NOT rotate into a session"
    assert_predicate cookies[REFRESH_COOKIE].to_s, :empty?, "the refresh cookie must be cleared"
  end

  test "a token just past the trust-lifetime boundary is treated as expired" do
    token = stage_token(established_at: (RefreshToken::MAX_TRUST_LIFETIME + 1.second).ago)

    get "/"

    assert token.reload.revoked?, "just past the lifetime must be treated as expired"
    assert_equal "trust_expired", token.revoked_reason
  end
end
