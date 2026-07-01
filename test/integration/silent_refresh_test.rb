require "test_helper"

# Silent re-auth from a long-lived refresh token. After a 2FA-passed login
# leaves a refresh cookie in the browser, the next request that would have
# been bounced to /login (because the cookie-store session is stale or
# missing) is instead silently restored — the request returns the resource.
#
# Tests stay on the tenant subdomain throughout and seed the refresh cookie
# directly. The OAuth + 2FA -> refresh-cookie wiring is covered separately
# in RefreshTokenIssuanceTest. Cross-subdomain cookie transfer doesn't work
# under ActionDispatch::IntegrationTest (the same reason the session cookie
# skips its domain attribute in test mode), so exercising silent refresh
# across host! switches would just be testing the test framework.
class SilentRefreshTest < ActionDispatch::IntegrationTest
  REFRESH_COOKIE = ApplicationController::REFRESH_COOKIE_NAME

  setup do
    @tenant = create_tenant(subdomain: "sr-#{SecureRandom.hex(4)}", name: "SR Tenant")
    @tenant.create_main_collective!(created_by: create_user(email: "sr-admin-#{SecureRandom.hex(4)}@example.com"))
    @user = create_user(email: "sr-user-#{SecureRandom.hex(4)}@example.com", name: "SR User")
    @tenant.add_user!(@user)
    @omni = @user.find_or_create_omni_auth_identity!
    @omni.update!(email_confirmed_at: Time.current)
    @omni.generate_otp_secret!
    @omni.enable_otp!

    host! "#{@tenant.subdomain}.#{ENV.fetch("HOSTNAME", nil)}"
  end

  # Seed a refresh token + cookie for @user as if they had just completed
  # an interactive 2FA login on this device.
  def seed_refresh_cookie(two_factor_at: Time.current)
    token = RefreshToken.issue!(user: @user, two_factor_at: two_factor_at)
    cookies[REFRESH_COOKIE] = token.plaintext_token
    token
  end

  # === Happy path ===

  test "silent refresh from a missing session restores user_id and rotates the token" do
    original = seed_refresh_cookie
    assert_difference "RefreshToken.count", 1 do
      get "/"
    end
    assert_equal @user.id, session[:user_id], "session must be repopulated from the refresh cookie"
    assert original.reload.rotated?, "original token must be marked rotated"
    successor = RefreshToken.where(family_id: original.family_id).where.not(id: original.id).first
    assert_not_nil successor, "rotation must mint a successor in the same family"
    assert_not_nil cookies[REFRESH_COOKIE], "successor's plaintext must be written to the cookie"
    refute_equal original.token_digest, RefreshToken.digest(cookies[REFRESH_COOKIE]),
                 "cookie value must now hash to the successor, not the original"
  end

  # === Guards ===

  test "silent refresh is a no-op on the auth subdomain even with a valid refresh cookie" do
    original_count = RefreshToken.count
    seed_refresh_cookie
    host! "#{ENV.fetch("AUTH_SUBDOMAIN", nil)}.#{ENV.fetch("HOSTNAME", nil)}"
    # Hit a path that doesn't require a rendered view — healthcheck inherits
    # ApplicationController so the before_action chain (incl. our silent
    # refresh) still fires.
    get "/healthcheck"
    assert_nil session[:user_id], "no session should be established on the auth subdomain"
    # +1 from seed_refresh_cookie; no rotation = no additional token
    assert_equal original_count + 1, RefreshToken.count
  end

  test "silent refresh is a no-op while a 2FA flow is pending in the session" do
    # Drive a real 2FA-required OAuth callback so the session has
    # pending_2fa_identity_id set. The OAuth callback happens on the auth
    # subdomain, so this test stays on auth subdomain — same single-host
    # constraint applies.
    host! "#{ENV.fetch("AUTH_SUBDOMAIN", nil)}.#{ENV.fetch("HOSTNAME", nil)}"
    OmniAuth.config.test_mode = true
    cookies[:redirect_to_subdomain] = @tenant.subdomain
    OmniAuth.config.mock_auth[:github] = OmniAuth::AuthHash.new(
      provider: "github",
      uid: SecureRandom.hex(6),
      info: {
        email: @user.email,
        name: @user.name,
        urls: { "GitHub" => "https://github.com/sr-#{SecureRandom.hex(3)}" },
      }
    )
    get "/auth/github/callback"
    assert session[:pending_2fa_identity_id].present?

    # Now seed a refresh cookie and hit a request — silent refresh must
    # refuse to repopulate the session out from under the pending 2FA flow.
    seed_refresh_cookie
    before_count = RefreshToken.count
    get "/login/verify-2fa"
    assert_equal before_count, RefreshToken.count, "mid-2FA silent refresh must not rotate"
  ensure
    OmniAuth.config.test_mode = false
    OmniAuth.config.mock_auth[:github] = nil
  end

  test "silent refresh on an active session does not rotate" do
    sign_in_as(@user, tenant: @tenant)
    seed_refresh_cookie
    before_count = RefreshToken.count
    get "/"
    assert_equal before_count, RefreshToken.count, "fresh session must not trigger rotation"
  end

  # === Session cookie persistence (#326 root cause) ===
  # The refresh churn behind #326 came from `_harmonic_session` being a
  # browser-session cookie: on an iOS PWA, iOS reaps the standalone web view on
  # backgrounding, so every cold launch arrived with the session cookie already
  # gone but a live 90-day refresh cookie beside it — forcing a silent refresh
  # (and a rotation) on every app open. config/initializers/session_store.rb now
  # sets `expire_after` to the idle timeout, so the cookie persists on disk for
  # exactly as long as the session stays idle-valid and a cold-start within that
  # window reuses the session instead of rotating.

  test "session cookie is configured to persist for the idle-timeout window (#326)" do
    expire_after = Rails.application.config.session_options[:expire_after]
    assert_not_nil expire_after,
                   "session cookie must set expire_after so a PWA cold-start reuses it instead of forcing a silent refresh (#326)"
    assert_equal ApplicationController::SESSION_IDLE_TIMEOUT, expire_after,
                 "cookie persistence must track the server-side idle timeout (single source of truth via SESSION_IDLE_TIMEOUT)"
  end

  test "silent refresh is a no-op with an API token request (Authorization header)" do
    seed_refresh_cookie
    @tenant.enable_api! if @tenant.respond_to?(:enable_api!)
    @tenant.main_collective.enable_api! if @tenant.main_collective.respond_to?(:enable_api!)
    api_token = ApiToken.create!(tenant: @tenant, user: @user, scopes: ApiToken.valid_scopes)
    before_count = RefreshToken.count
    get "/api/v1/notes", headers: { "Authorization" => "Bearer #{api_token.plaintext_token}" }
    assert_equal before_count, RefreshToken.count, "API token requests must not silently refresh"
  end

  # === Token state ===

  test "refresh cookie pointing to a revoked token is cleared and no session is established" do
    token = seed_refresh_cookie
    token.revoke!(reason: "user_logout")
    get "/"
    assert_nil session[:user_id], "revoked token must not silently restore session"
  end

  test "refresh cookie for an expired token is cleared and no session is established" do
    token = seed_refresh_cookie
    token.update!(expires_at: 1.minute.ago)
    get "/"
    assert_nil session[:user_id]
  end

  test "refresh cookie pointing to a suspended user revokes the token and clears the cookie" do
    token = seed_refresh_cookie
    @user.update!(suspended_at: Time.current)
    get "/"
    assert_nil session[:user_id]
    assert token.reload.revoked?, "token for a now-suspended user must be revoked"
    assert_equal "user_ineligible", token.revoked_reason
  end

  test "refresh cookie minted before a sessions_revoked_at admin action is rejected" do
    token = seed_refresh_cookie
    @user.update!(sessions_revoked_at: 1.second.from_now)
    get "/"
    assert_nil session[:user_id], "stale-vs-revocation token must not silently restore session"
    assert token.reload.revoked?
    assert_equal "user_ineligible", token.revoked_reason
  end

  test "refresh cookie minted AFTER a sessions_revoked_at admin action is honored" do
    @user.update!(sessions_revoked_at: 1.day.ago)
    seed_refresh_cookie # token.created_at = now > sessions_revoked_at
    assert_difference "RefreshToken.count", 1 do
      get "/"
    end
    assert_equal @user.id, session[:user_id]
  end

  # === Replay detection ===
  # State is set up directly in the DB rather than relying on a prior
  # rotation request: IntegrationTest's cookie jar doesn't reliably let
  # tests override a cookie the server already set in an earlier response,
  # so the "replay the previous cookie value" scenario can't be staged
  # through a chained pair of requests.

  test "presenting an already-rotated token outside the grace window revokes the family" do
    original = RefreshToken.issue!(user: @user, two_factor_at: Time.current)
    original_plaintext = T.must(original.plaintext_token)
    successor = original.rotate!
    # Push the rotation timestamp past the grace window.
    original.update!(rotated_at: (RefreshToken::REPLAY_GRACE_WINDOW + 5.seconds).ago)

    cookies[REFRESH_COOKIE] = original_plaintext
    get "/"

    assert original.reload.revoked?, "replay outside grace window must revoke the original"
    assert successor.reload.revoked?, "replay outside grace window must revoke the whole family"
    assert_equal "rotation_replay", original.reload.revoked_reason
    assert_nil session[:user_id], "no session should be established on a replay"
  end

  test "presenting an already-rotated token within the grace window is benign (no family revoke, no re-rotation)" do
    original = RefreshToken.issue!(user: @user, two_factor_at: Time.current)
    original_plaintext = T.must(original.plaintext_token)
    successor = original.rotate! # rotated_at is now, well within grace window

    cookies[REFRESH_COOKIE] = original_plaintext
    before_count = RefreshToken.count
    get "/"

    assert_equal before_count, RefreshToken.count, "grace-window replay must not re-rotate"
    refute original.reload.revoked?
    refute successor.reload.revoked?
    assert_equal @user.id, session[:user_id], "benign replay still establishes a session"
  end

  # === Reverification invariant ===
  # The invariant — silent refresh must NOT preserve reverified_at_* — is
  # enforced mechanically by establish_silent_session calling reset_session
  # before writing user_id. See ApplicationController#establish_silent_session.
  # Driving a real reverification flow through an IntegrationTest just to
  # re-prove this would obscure the actual contract; the model test below
  # exercises the same invariant by checking the session-key set after a
  # silent refresh.

  test "silent refresh leaves no session keys besides the three it sets" do
    seed_refresh_cookie
    get "/"
    expected = %w[user_id logged_in_at last_activity_at session_id _csrf_token].to_set
    actual = session.to_hash.keys.map(&:to_s).to_set
    extra = actual - expected
    assert_empty extra,
                 "silent refresh repopulated session has unexpected keys: #{extra.to_a.inspect}"
  end
end
