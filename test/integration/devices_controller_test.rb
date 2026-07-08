require "test_helper"

# Sign-in-devices settings actions: revoke a single device, or revoke
# every device except the current one. The listing itself is rendered
# inline on the user-settings page (UsersControllerTest covers that).
class DevicesControllerTest < ActionDispatch::IntegrationTest
  REFRESH_COOKIE = ApplicationController::REFRESH_COOKIE_NAME

  setup do
    @tenant = create_tenant(subdomain: "dev-#{SecureRandom.hex(4)}")
    @tenant.settings["require_2fa"] = "false"
    @tenant.save!
    @user = create_user(email: "dev-#{SecureRandom.hex(4)}@example.com", name: "Dev User")
    @tenant.add_user!(@user)
    @tenant.create_main_collective!(created_by: @user)
    sign_in_as(@user, tenant: @tenant)
  end

  # === settings page rendering ===
  # The accordion that hosts the revoke buttons is gated on
  # @active_devices.any?, so any existing settings-page test (e.g.
  # billing_gate_test) doesn't exercise the rendering path. Seed a refresh
  # token so the page actually renders the device list, catching things
  # like broken route helpers and missing partials.

  test "user settings page renders successfully with an active device" do
    RefreshToken.issue!(user: @user, two_factor_at: Time.current)
    get "/settings"
    assert_response :success
    assert_match(/\bDevices\b/, response.body)
    assert_match(/Sign out/i, response.body)
  end

  test "the device list shows one row per device even after many rotations (#326)" do
    current = RefreshToken.issue!(user: @user, two_factor_at: Time.current)
    4.times { current = current.rotate! }
    cookies[REFRESH_COOKIE] = T.must(current.plaintext_token)
    RefreshToken.issue!(user: @user, two_factor_at: Time.current) # one genuinely-other device

    get "/settings"

    assert_response :success
    # One "Last used … ago" hint is rendered per listed device: the rotated
    # predecessors of the current device must not each appear as their own row.
    assert_equal 2, response.body.scan(/Last used .*? ago/).size
  end

  # === destroy ===

  test "DELETE /settings/devices/:id revokes the specified device" do
    a = RefreshToken.issue!(user: @user, two_factor_at: Time.current)
    b = RefreshToken.issue!(user: @user, two_factor_at: Time.current)

    delete "/settings/devices/#{a.id}"

    assert a.reload.revoked?
    refute b.reload.revoked?
    assert_equal "user_logout", a.revoked_reason
  end

  test "signing out the device you're currently on logs you out on the very next request" do
    current = RefreshToken.issue!(user: @user, two_factor_at: Time.current)
    cookies[REFRESH_COOKIE] = T.must(current.plaintext_token)

    delete "/settings/devices/#{current.id}"
    assert current.reload.revoked?

    # First redirect: back to /settings — the destroy controller's plain
    # path. At this point the token is revoked but the session is intact.
    assert_redirected_to "/settings"

    # Following the redirect: enforce_refresh_token_revocation fires,
    # sees the revoked cookie, kills the session, redirects to /login.
    follow_redirect!
    assert_redirected_to "/login"
    assert_nil session[:user_id],
               "session must be ended so 'Sign out' actually signs the user out"
    assert_predicate cookies[REFRESH_COOKIE].to_s, :empty?
  end

  test "DELETE with an id belonging to another user is rejected" do
    other_user = create_user(email: "other-#{SecureRandom.hex(4)}@example.com")
    others_device = RefreshToken.issue!(user: other_user, two_factor_at: Time.current)

    delete "/settings/devices/#{others_device.id}"

    refute others_device.reload.revoked?, "must not be able to revoke another user's device through your own settings"
  end

  test "DELETE with a revoked id is a graceful no-op (the listing scope is .live only)" do
    revoked = RefreshToken.issue!(user: @user, two_factor_at: Time.current)
    revoked.revoke!(reason: "user_logout")
    original_time = revoked.revoked_at

    delete "/settings/devices/#{revoked.id}"

    assert_in_delta original_time.to_i, revoked.reload.revoked_at.to_i, 1,
                    "should not re-revoke; original revocation timestamp must be preserved"
  end

  # === revoke_others ===

  test "POST /settings/devices/revoke_others revokes every device except the current one" do
    current = RefreshToken.issue!(user: @user, two_factor_at: Time.current)
    cookies[REFRESH_COOKIE] = T.must(current.plaintext_token)
    other_a = RefreshToken.issue!(user: @user, two_factor_at: Time.current)
    other_b = RefreshToken.issue!(user: @user, two_factor_at: Time.current)

    post "/settings/devices/revoke_others"

    refute current.reload.revoked?, "the current device must NOT be revoked"
    assert other_a.reload.revoked?
    assert other_b.reload.revoked?
    assert_equal "user_logout", other_a.revoked_reason
  end

  test "revoke_others with no current refresh cookie revokes every active device" do
    a = RefreshToken.issue!(user: @user, two_factor_at: Time.current)
    b = RefreshToken.issue!(user: @user, two_factor_at: Time.current)

    post "/settings/devices/revoke_others"

    assert a.reload.revoked?
    assert b.reload.revoked?
  end

  test "rotated predecessors don't count as separate devices in revoke_others (#326)" do
    # One physical device that has silently refreshed many times. Each refresh
    # rotates the token, leaving a rotated-but-not-revoked predecessor behind.
    current = RefreshToken.issue!(user: @user, two_factor_at: Time.current)
    5.times { current = current.rotate! }
    cookies[REFRESH_COOKIE] = T.must(current.plaintext_token)
    other = RefreshToken.issue!(user: @user, two_factor_at: Time.current)

    post "/settings/devices/revoke_others"

    assert other.reload.revoked?, "the one genuinely-other device is signed out"
    refute current.reload.revoked?, "the current device stays signed in"
    assert_equal "Signed out of 1 other device.", flash[:notice],
                 "count reflects live devices, not the rotation chain"
  end

  test "revoke_others does not touch other users' devices" do
    current = RefreshToken.issue!(user: @user, two_factor_at: Time.current)
    cookies[REFRESH_COOKIE] = T.must(current.plaintext_token)
    other_user = create_user(email: "other-#{SecureRandom.hex(4)}@example.com")
    others_device = RefreshToken.issue!(user: other_user, two_factor_at: Time.current)

    post "/settings/devices/revoke_others"

    refute others_device.reload.revoked?
  end

  # === signing out revokes the whole token family, not just the live tail ===
  # A device is a token family (login + every silent rotation). Rotated
  # predecessors keep revoked_at nil so replay detection can still find them;
  # if "Sign out" revoked only the tail, a predecessor presented inside its
  # REPLAY_GRACE_WINDOW could re-establish a session on a just-signed-out
  # device. So both actions revoke by family.

  test "DELETE signs out the whole token family, including rotated predecessors" do
    device = RefreshToken.issue!(user: @user, two_factor_at: Time.current)
    successor = device.rotate! # `device` is now a rotated-but-not-revoked predecessor
    # The device list shows the live tail; that's the id the Sign-out button targets.
    delete "/settings/devices/#{successor.id}"

    assert successor.reload.revoked?, "the live tail is signed out"
    assert device.reload.revoked?,
           "the rotated predecessor must also be revoked so it can't re-establish a session in its grace window"
    assert_equal "user_logout", device.revoked_reason
  end

  test "revoke_others signs out other families whole, but never the current family's predecessors" do
    # Current device that just silently refreshed: the cookie holds the live
    # tail, and `current` is its in-flight rotated predecessor.
    current = RefreshToken.issue!(user: @user, two_factor_at: Time.current)
    current_tail = current.rotate!
    cookies[REFRESH_COOKIE] = T.must(current_tail.plaintext_token)

    # A genuinely-other device that has also rotated.
    other = RefreshToken.issue!(user: @user, two_factor_at: Time.current)
    other_tail = other.rotate!

    post "/settings/devices/revoke_others"

    assert other.reload.revoked?, "the other family's rotated predecessor is revoked"
    assert other_tail.reload.revoked?, "the other family's live tail is revoked"
    refute current_tail.reload.revoked?, "the current device stays signed in"
    refute current.reload.revoked?,
           "the current family's rotated predecessor must survive — a sibling tab may present it mid-race"
    assert_equal "Signed out of 1 other device.", flash[:notice],
                 "count reflects live devices (families), not tokens"
  end

  # === actual sign-out enforcement on revoked tokens ===
  # The whole point of "Sign out device X" is that device X actually loses
  # access. Because the refresh cookie is sent on every request, the
  # before_action that enforces revocation kicks the revoked device out on
  # its very next request — no waiting for session timeout.

  test "a request carrying a revoked refresh cookie is logged out on its next request" do
    token = RefreshToken.issue!(user: @user, two_factor_at: Time.current)
    cookies[REFRESH_COOKIE] = T.must(token.plaintext_token)
    # Simulate the device having been signed out from elsewhere.
    token.revoke!(reason: "user_logout")

    get "/settings"

    assert_nil session[:user_id], "session must be ended when carrying a revoked refresh cookie"
    assert_redirected_to "/login"
    assert_predicate cookies[REFRESH_COOKIE].to_s, :empty?
  end

  test "a request carrying a rotated-but-not-revoked refresh cookie is NOT logged out" do
    token = RefreshToken.issue!(user: @user, two_factor_at: Time.current)
    cookies[REFRESH_COOKIE] = T.must(token.plaintext_token)
    # Rotation is a benign in-flight signal, not a revocation.
    token.rotate!

    get "/settings"
    assert_response :success
    assert_equal @user.id, session[:user_id]
  end

  test "a request with no refresh cookie is unaffected by the revocation check" do
    cookies.delete(REFRESH_COOKIE)
    get "/settings"
    assert_response :success
    assert_equal @user.id, session[:user_id]
  end

  # === authorization ===

  test "the handle-free device-revoke route only reaches the signed-in user's own devices" do
    a = RefreshToken.issue!(user: @user, two_factor_at: Time.current)

    other_user = create_user(email: "another-#{SecureRandom.hex(4)}@example.com")
    @tenant.add_user!(other_user)
    sign_in_as(other_user, tenant: @tenant)

    delete "/settings/devices/#{a.id}"

    # a belongs to @user; the route carries no handle, so revocation is scoped to
    # other_user's own devices and @user's device stays live — structurally out
    # of another user's reach.
    refute a.reload.revoked?
  end
end
