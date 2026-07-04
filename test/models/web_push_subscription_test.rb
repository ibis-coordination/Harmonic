require "test_helper"

class WebPushSubscriptionTest < ActiveSupport::TestCase
  ENDPOINT = "https://push.example.com/send/abc123".freeze

  setup do
    @user = create_user
  end

  def subscribe!(user: @user, endpoint: ENDPOINT)
    WebPushSubscription.upsert_for!(
      user: user,
      endpoint: endpoint,
      p256dh_key: "p256dh-key",
      auth_key: "auth-key"
    )
  end

  test "upsert_for! creates a subscription with keys and last_seen_at" do
    subscription = subscribe!

    assert_equal @user.id, subscription.user_id
    assert_equal ENDPOINT, subscription.endpoint
    assert_equal "p256dh-key", subscription.p256dh_key
    assert_equal "auth-key", subscription.auth_key
    assert_not_nil subscription.last_seen_at
  end

  test "upsert_for! updates the existing row for the same user and endpoint" do
    first = subscribe!
    second = WebPushSubscription.upsert_for!(
      user: @user,
      endpoint: ENDPOINT,
      p256dh_key: "rotated-p256dh",
      auth_key: "rotated-auth"
    )

    assert_equal first.id, second.id
    assert_equal "rotated-p256dh", second.p256dh_key
    assert_equal 1, WebPushSubscription.where(user: @user).count
  end

  test "upsert_for! clears revocation on re-subscribe" do
    subscription = subscribe!
    subscription.revoke!(reason: "gone")

    resubscribed = subscribe!

    assert_equal subscription.id, resubscribed.id
    assert_nil resubscribed.revoked_at
    assert_nil resubscribed.revoked_reason
  end

  test "refresh_for! stamps last_seen_at and keys on an active row" do
    subscription = subscribe!
    subscription.update!(last_seen_at: 2.days.ago)

    refreshed = WebPushSubscription.refresh_for!(
      user: @user, endpoint: ENDPOINT, p256dh_key: "rotated-p256dh", auth_key: "rotated-auth"
    )

    assert_equal subscription.id, refreshed.id
    assert_in_delta Time.current, refreshed.last_seen_at, 5.seconds
    assert_equal "rotated-p256dh", refreshed.p256dh_key
  end

  test "refresh_for! creates a row for an endpoint the server has never seen" do
    refreshed = WebPushSubscription.refresh_for!(
      user: @user, endpoint: ENDPOINT, p256dh_key: "p256dh-key", auth_key: "auth-key"
    )

    assert refreshed.active?
    assert_equal 1, WebPushSubscription.where(user: @user).count
  end

  test "refresh_for! never revives a revoked row" do
    # Re-enabling is an explicit user action (the settings button →
    # upsert_for!); the background resync must not undo a revocation.
    subscription = subscribe!
    subscription.revoke!(reason: "user")

    result = WebPushSubscription.refresh_for!(
      user: @user, endpoint: ENDPOINT, p256dh_key: "p256dh-key", auth_key: "auth-key"
    )

    assert_nil result
    assert_not subscription.reload.active?
    assert_equal "user", subscription.revoked_reason
  end

  test "the same endpoint can belong to multiple users" do
    other_user = create_user

    subscribe!
    other = subscribe!(user: other_user)

    assert_equal 2, WebPushSubscription.where(endpoint: ENDPOINT).count
    assert_not_equal @user.id, other.user_id
  end

  test "requires endpoint and both keys" do
    subscription = WebPushSubscription.new(user: @user)

    assert_not subscription.valid?
    assert subscription.errors[:endpoint].any?
    assert subscription.errors[:p256dh_key].any?
    assert subscription.errors[:auth_key].any?
  end

  test "non-human users cannot subscribe" do
    tenant, _collective, human = create_tenant_collective_user
    agent = create_ai_agent(parent: human)

    error = assert_raises(ActiveRecord::RecordInvalid) { subscribe!(user: agent) }
    assert_match(/human/, error.message)
  ensure
    Tenant.current_id = nil if tenant
  end

  test "revoke! stamps revoked_at and reason" do
    subscription = subscribe!
    subscription.revoke!(reason: "gone")

    assert_not_nil subscription.revoked_at
    assert_equal "gone", subscription.revoked_reason
    assert_not subscription.active?
  end

  test "revoke! rejects unknown reasons" do
    subscription = subscribe!

    assert_raises(ArgumentError) { subscription.revoke!(reason: "whatever") }
  end

  test "active scope excludes revoked subscriptions" do
    live = subscribe!
    revoked = subscribe!(endpoint: "https://push.example.com/send/other")
    revoked.revoke!(reason: "gone")

    assert_includes WebPushSubscription.active, live
    assert_not_includes WebPushSubscription.active, revoked
  end

  test "revoke_all_for_user! revokes every active subscription for the user" do
    laptop = subscribe!
    phone = subscribe!(endpoint: "https://push.example.com/send/phone")
    other_user = create_user
    other_users_device = subscribe!(user: other_user)

    WebPushSubscription.revoke_all_for_user!(@user.id, reason: "admin")

    assert_equal "admin", laptop.reload.revoked_reason
    assert_equal "admin", phone.reload.revoked_reason
    assert other_users_device.reload.active?, "another user's subscription must be untouched"
  end

  test "revoke_all_for_user! leaves already-revoked rows and their reasons untouched" do
    gone = subscribe!
    gone.revoke!(reason: "gone")
    revoked_at = gone.revoked_at

    WebPushSubscription.revoke_all_for_user!(@user.id, reason: "admin")

    assert_equal "gone", gone.reload.revoked_reason
    assert_equal revoked_at, gone.revoked_at
  end

  test "revoke_all_for_user! rejects unknown reasons" do
    assert_raises(ArgumentError) { WebPushSubscription.revoke_all_for_user!(@user.id, reason: "whatever") }
  end

  test "record_error! stamps the error fields without revoking" do
    subscription = subscribe!
    subscription.record_error!("Forbidden")

    assert_equal "Forbidden", subscription.last_error
    assert_not_nil subscription.last_error_at
    assert subscription.active?
  end

  test "is not tenant scoped" do
    assert_not WebPushSubscription.belongs_to_tenant?
  end
end
