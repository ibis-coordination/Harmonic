# typed: false

require "test_helper"

class WebPushSubscriptionsControllerTest < ActionDispatch::IntegrationTest
  def setup
    @tenant = @global_tenant
    @user = @global_user
    enable_web_push!(@tenant)
    host! "#{@tenant.subdomain}.#{ENV.fetch("HOSTNAME", nil)}"
    @handle = @tenant.tenant_users.find_by(user: @user).handle
  end

  def subscription_params(endpoint: "https://push.example.com/send/abc123")
    {
      subscription: {
        endpoint: endpoint,
        keys: { p256dh: "p256dh-key", auth: "auth-key" },
      },
    }
  end

  test "create registers a subscription for the current user" do
    sign_in_as(@user, tenant: @tenant)

    assert_difference -> { WebPushSubscription.where(user: @user).count }, 1 do
      post "/u/#{@handle}/settings/push-subscriptions", params: subscription_params, as: :json
    end

    assert_response :success
    subscription = WebPushSubscription.find_by(user: @user, endpoint: "https://push.example.com/send/abc123")
    assert_equal "p256dh-key", subscription.p256dh_key
    assert_not_nil subscription.device_label
  end

  test "create upserts on repeat subscribe from the same endpoint" do
    sign_in_as(@user, tenant: @tenant)

    2.times do
      post "/u/#{@handle}/settings/push-subscriptions", params: subscription_params, as: :json
    end

    assert_equal 1, WebPushSubscription.where(user: @user).count
  end

  test "create returns not_found when the web_push flag is off" do
    @tenant.disable_feature_flag!(:web_push)
    sign_in_as(@user, tenant: @tenant)

    post "/u/#{@handle}/settings/push-subscriptions", params: subscription_params, as: :json

    assert_response :not_found
    assert_equal 0, WebPushSubscription.where(user: @user).count
  end

  test "create requires authentication" do
    post "/u/#{@handle}/settings/push-subscriptions", params: subscription_params, as: :json

    assert_not_equal 200, response.status
    assert_equal 0, WebPushSubscription.count
  end

  test "create rejects subscribing on someone else's settings page" do
    other = create_user
    @tenant.add_user!(other)
    other_handle = @tenant.tenant_users.find_by(user: other).handle
    sign_in_as(@user, tenant: @tenant)

    post "/u/#{other_handle}/settings/push-subscriptions", params: subscription_params, as: :json

    assert_response :forbidden
    assert_equal 0, WebPushSubscription.count
  end

  test "destroy revokes the subscription" do
    sign_in_as(@user, tenant: @tenant)
    subscription = WebPushSubscription.upsert_for!(
      user: @user, endpoint: "https://push.example.com/send/abc123", p256dh_key: "k", auth_key: "a"
    )

    delete "/u/#{@handle}/settings/push-subscriptions/#{subscription.id}"

    assert_response :redirect
    subscription.reload
    assert_not subscription.active?
    assert_equal "user", subscription.revoked_reason
  end

  test "destroy cannot touch another user's subscription" do
    other = create_user
    @tenant.add_user!(other)
    subscription = WebPushSubscription.upsert_for!(
      user: other, endpoint: "https://push.example.com/send/other", p256dh_key: "k", auth_key: "a"
    )
    sign_in_as(@user, tenant: @tenant)

    delete "/u/#{@handle}/settings/push-subscriptions/#{subscription.id}"

    assert subscription.reload.active?, "another user's subscription must not be revoked"
  end
end
