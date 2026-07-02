require "test_helper"

# A live session never rotates its refresh token, so the device you're actively
# using would show a stale "last used" in the device list unless ordinary
# request activity refreshes it. touch_current_device_activity (an
# ApplicationController before_action) keeps the current device's row current,
# throttled by RefreshToken::ACTIVITY_TOUCH_THROTTLE (#346).
class RefreshTokenActivityTest < ActionDispatch::IntegrationTest
  REFRESH_COOKIE = ApplicationController::REFRESH_COOKIE_NAME

  setup do
    @tenant = create_tenant(subdomain: "rta-#{SecureRandom.hex(4)}")
    @user = create_user(email: "rta-#{SecureRandom.hex(4)}@example.com", name: "RTA User")
    @tenant.add_user!(@user)
    @tenant.create_main_collective!(created_by: @user)
  end

  test "an ordinary request refreshes the current device's stale last_used_at" do
    sign_in_as(@user, tenant: @tenant)
    device = RefreshToken.issue!(user: @user, two_factor_at: Time.current)
    device.update_column(:last_used_at, 3.hours.ago)
    cookies[REFRESH_COOKIE] = T.must(device.plaintext_token)

    get "/"

    assert_in_delta Time.current, device.reload.last_used_at, 5.seconds,
                    "an ordinary authenticated request must refresh the current device's last_used_at"
  end

  test "an ordinary request does not touch a device whose cookie it is not carrying" do
    sign_in_as(@user, tenant: @tenant)
    current = RefreshToken.issue!(user: @user, two_factor_at: Time.current)
    other = RefreshToken.issue!(user: @user, two_factor_at: Time.current)
    other_stale = 3.hours.ago
    other.update_column(:last_used_at, other_stale)
    cookies[REFRESH_COOKIE] = T.must(current.plaintext_token)

    get "/"

    assert_in_delta other_stale.to_i, other.reload.last_used_at.to_i, 1,
                    "only the device making the request is touched; others keep their real last_used_at"
  end

  test "a recently-touched device is not written again within the throttle window" do
    sign_in_as(@user, tenant: @tenant)
    device = RefreshToken.issue!(user: @user, two_factor_at: Time.current)
    fresh = 30.seconds.ago
    device.update_column(:last_used_at, fresh)
    cookies[REFRESH_COOKIE] = T.must(device.plaintext_token)

    get "/"

    assert_in_delta fresh.to_i, device.reload.last_used_at.to_i, 1,
                    "a request within ACTIVITY_TOUCH_THROTTLE must not rewrite last_used_at"
  end
end
