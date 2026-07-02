require "test_helper"

class WebPushDeliveryJobTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @tenant, @collective, @user = create_tenant_collective_user
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)

    @subscription = WebPushSubscription.upsert_for!(
      user: @user,
      endpoint: "https://push.example.com/send/abc123",
      p256dh_key: "p256dh-key",
      auth_key: "auth-key"
    )

    event = Event.create!(tenant: @tenant, collective: @collective, event_type: "note.created")
    notification = Notification.create!(
      tenant: @tenant,
      event: event,
      notification_type: "mention",
      title: "Ada mentioned you",
      body: "Some note text",
      url: "/n/test123"
    )
    @recipient = NotificationRecipient.create!(
      notification: notification,
      user: @user,
      channel: "web_push",
      status: "pending"
    )

    @old_public = ENV.fetch("VAPID_PUBLIC_KEY", nil)
    @old_private = ENV.fetch("VAPID_PRIVATE_KEY", nil)
    ENV["VAPID_PUBLIC_KEY"] = "test-vapid-public"
    ENV["VAPID_PRIVATE_KEY"] = "test-vapid-private"
  end

  teardown do
    ENV["VAPID_PUBLIC_KEY"] = @old_public
    ENV["VAPID_PRIVATE_KEY"] = @old_private
  end

  def response_error(klass)
    response = Struct.new(:code, :body, :message).new("410", "", "Gone")
    klass.new(response, "push.example.com")
  end

  test "sends an encrypted payload to the subscription endpoint" do
    sent = nil
    WebPush.stub(:payload_send, lambda { |**kwargs|
      sent = kwargs
      true
    }) do
      WebPushDeliveryJob.perform_now(@recipient.id, @subscription.id)
    end

    assert_not_nil sent
    assert_equal @subscription.endpoint, sent[:endpoint]
    assert_equal "p256dh-key", sent[:p256dh]
    assert_equal "auth-key", sent[:auth]
    assert_equal "test-vapid-public", sent.dig(:vapid, :public_key)
    assert_equal "test-vapid-private", sent.dig(:vapid, :private_key)

    payload = JSON.parse(sent[:message])
    assert_equal "Ada mentioned you", payload["title"]
    assert_equal "Some note text", payload["body"]
    assert_equal "mention", payload["notification_type"]
    assert_equal "#{@tenant.url}/n/test123", payload["url"], "payload URL must be absolute on the notification's tenant host"
  end

  test "falls back to the tenant root URL when the notification has no url" do
    @recipient.notification.update!(url: nil)

    sent = nil
    WebPush.stub(:payload_send, ->(**kwargs) { sent = kwargs }) do
      WebPushDeliveryJob.perform_now(@recipient.id, @subscription.id)
    end

    assert_equal @tenant.url, JSON.parse(sent[:message])["url"]
  end

  test "revokes the subscription when the endpoint is gone" do
    WebPush.stub(:payload_send, ->(**) { raise response_error(WebPush::ExpiredSubscription) }) do
      WebPushDeliveryJob.perform_now(@recipient.id, @subscription.id)
    end

    @subscription.reload
    assert_not @subscription.active?
    assert_equal "gone", @subscription.revoked_reason
  end

  test "revokes the subscription when the push service rejects it as invalid" do
    WebPush.stub(:payload_send, ->(**) { raise response_error(WebPush::InvalidSubscription) }) do
      WebPushDeliveryJob.perform_now(@recipient.id, @subscription.id)
    end

    assert_not @subscription.reload.active?
  end

  test "revokes the subscription when the push service rejects the VAPID signature" do
    # 401/403 means our keys don't match the subscription's applicationServerKey
    # (e.g. after a VAPID rotation) — that subscription can never deliver again,
    # so it must be revoked to unblock the client-side re-subscribe repair path.
    WebPush.stub(:payload_send, ->(**) { raise response_error(WebPush::Unauthorized) }) do
      WebPushDeliveryJob.perform_now(@recipient.id, @subscription.id)
    end

    @subscription.reload
    assert_not @subscription.active?
    assert_equal "unauthorized", @subscription.revoked_reason
  end

  test "retries on rate limiting" do
    WebPush.stub(:payload_send, ->(**) { raise response_error(WebPush::TooManyRequests) }) do
      WebPushDeliveryJob.perform_now(@recipient.id, @subscription.id)
    end

    # retry_on intercepts the error and re-enqueues with backoff.
    assert_enqueued_jobs 1, only: WebPushDeliveryJob
    assert @subscription.reload.active?, "rate limiting must not revoke the subscription"
  end

  test "records other response errors without revoking" do
    WebPush.stub(:payload_send, ->(**) { raise response_error(WebPush::PayloadTooLarge) }) do
      WebPushDeliveryJob.perform_now(@recipient.id, @subscription.id)
    end

    @subscription.reload
    assert @subscription.active?
    assert_not_nil @subscription.last_error_at
    assert_match(/PayloadTooLarge/, @subscription.last_error)
  end

  test "does nothing for a revoked subscription" do
    @subscription.revoke!(reason: "user")

    called = false
    WebPush.stub(:payload_send, ->(**) { called = true }) do
      WebPushDeliveryJob.perform_now(@recipient.id, @subscription.id)
    end

    assert_not called
  end

  test "does nothing when recipient or subscription is missing" do
    assert_nothing_raised do
      WebPushDeliveryJob.perform_now("nonexistent", @subscription.id)
      WebPushDeliveryJob.perform_now(@recipient.id, "nonexistent")
    end
  end
end
