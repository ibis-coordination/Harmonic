require "test_helper"
require "webmock/minitest"

class WebhookDeliveryServiceTest < ActiveSupport::TestCase
  setup do
    @tenant, @superagent, @user = create_tenant_superagent_user
    Superagent.scope_thread_to_superagent(subdomain: @tenant.subdomain, handle: @superagent.handle)

    @webhook = Webhook.create!(
      tenant: @tenant,
      name: "Test Webhook",
      url: "https://example.com/webhook",
      events: ["note.created"],
      created_by: @user,
    )

    @note = create_note(
      tenant: @tenant,
      superagent: @superagent,
      created_by: @user,
    )

    @event = Event.where(event_type: "note.created", subject: @note).last
    @delivery = WebhookDelivery.where(webhook: @webhook, event: @event).first
  end

  test "deliver! updates delivery to success on 2xx response" do
    stub_request(:post, "https://example.com/webhook")
      .to_return(status: 200, body: '{"received":true}')

    WebhookDeliveryService.deliver!(@delivery)

    @delivery.reload
    assert_equal "success", @delivery.status
    assert_equal 200, @delivery.response_code
    assert_equal '{"received":true}', @delivery.response_body
    assert_not_nil @delivery.delivered_at
    assert_equal 1, @delivery.attempt_count
  end

  test "deliver! sets retrying status on failure" do
    stub_request(:post, "https://example.com/webhook")
      .to_return(status: 500, body: "Internal Server Error")

    WebhookDeliveryService.deliver!(@delivery)

    @delivery.reload
    assert_equal "retrying", @delivery.status
    assert_match(/HTTP 500/, @delivery.error_message)
    assert_equal 1, @delivery.attempt_count
    assert_not_nil @delivery.next_retry_at
  end

  test "deliver! sets failed status after max attempts" do
    stub_request(:post, "https://example.com/webhook")
      .to_return(status: 500, body: "Internal Server Error")

    # Simulate reaching max attempts
    @delivery.update!(attempt_count: 4)

    WebhookDeliveryService.deliver!(@delivery)

    @delivery.reload
    assert_equal "failed", @delivery.status
    assert_equal 5, @delivery.attempt_count
  end

  test "deliver! handles network errors" do
    stub_request(:post, "https://example.com/webhook")
      .to_raise(Errno::ECONNREFUSED)

    WebhookDeliveryService.deliver!(@delivery)

    @delivery.reload
    assert_equal "retrying", @delivery.status
    assert_includes @delivery.error_message, "Connection refused"
  end

  test "deliver! handles timeout errors" do
    stub_request(:post, "https://example.com/webhook")
      .to_timeout

    WebhookDeliveryService.deliver!(@delivery)

    @delivery.reload
    assert_equal "retrying", @delivery.status
    assert_not_nil @delivery.error_message
  end

  test "deliver! skips disabled webhooks" do
    @webhook.update!(enabled: false)

    stub_request(:post, "https://example.com/webhook")

    WebhookDeliveryService.deliver!(@delivery)

    # Should not make the request
    assert_not_requested :post, "https://example.com/webhook"
  end

  test "deliver! sends correct headers" do
    stub_request(:post, "https://example.com/webhook")
      .with(
        headers: {
          "Content-Type" => "application/json",
          "X-Harmonic-Event" => "note.created",
        },
      )
      .to_return(status: 200)

    WebhookDeliveryService.deliver!(@delivery)

    assert_requested :post, "https://example.com/webhook", headers: {
      "Content-Type" => "application/json",
      "X-Harmonic-Event" => "note.created",
    }
  end

  test "sign generates correct HMAC signature" do
    body = '{"test":"data"}'
    timestamp = 1234567890
    secret = "test_secret"

    signature = WebhookDeliveryService.sign(body, timestamp, secret)

    expected = OpenSSL::HMAC.hexdigest("sha256", secret, "#{timestamp}.#{body}")
    assert_equal expected, signature
  end

  test "verify_signature validates correct signature" do
    body = '{"test":"data"}'
    timestamp = "1234567890"
    secret = "test_secret"

    signature = "sha256=" + WebhookDeliveryService.sign(body, timestamp.to_i, secret)

    assert WebhookDeliveryService.verify_signature(body, timestamp, signature, secret)
  end

  test "verify_signature rejects incorrect signature" do
    body = '{"test":"data"}'
    timestamp = "1234567890"
    secret = "test_secret"

    assert_not WebhookDeliveryService.verify_signature(body, timestamp, "sha256=wrong", secret)
  end

  test "retry delays increase exponentially" do
    delays = WebhookDeliveryService::RETRY_DELAYS
    assert_equal 1.minute, delays[0]
    assert_equal 5.minutes, delays[1]
    assert_equal 30.minutes, delays[2]
    assert_equal 2.hours, delays[3]
    assert_equal 24.hours, delays[4]
  end
end
