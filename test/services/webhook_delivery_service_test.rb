require "test_helper"
require "webmock/minitest"

class WebhookDeliveryServiceTest < ActiveSupport::TestCase
  setup do
    @tenant, @superagent, @user = create_tenant_superagent_user
    Superagent.scope_thread_to_superagent(subdomain: @tenant.subdomain, handle: @superagent.handle)

    @note = create_note(
      tenant: @tenant,
      superagent: @superagent,
      created_by: @user,
    )

    @event = Event.where(event_type: "note.created", subject: @note).last

    # Create automation rule and run for the delivery
    @automation_rule = AutomationRule.create!(
      tenant: @tenant,
      superagent: @superagent,
      name: "Test Automation",
      trigger_type: "event",
      trigger_config: { "event_type" => "note.created" },
      actions: [{ "type" => "webhook", "url" => "https://example.com/webhook" }],
      created_by: @user,
    )

    @automation_run = AutomationRuleRun.create!(
      tenant: @tenant,
      superagent: @superagent,
      automation_rule: @automation_rule,
      triggered_by_event: @event,
      trigger_source: "event",
      status: "running",
    )

    @delivery = WebhookDelivery.create!(
      tenant: @tenant,
      automation_rule_run: @automation_run,
      event: @event,
      url: "https://example.com/webhook",
      secret: @automation_rule.webhook_secret,
      request_body: '{"test":"data"}',
      status: "pending",
    )
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

  test "deliver! sends correct headers including automation run id" do
    captured_headers = {}
    stub_request(:post, "https://example.com/webhook")
      .to_return(status: 200)
      .with { |req| captured_headers = req.headers; true }

    WebhookDeliveryService.deliver!(@delivery)

    assert_equal "application/json", captured_headers["Content-Type"]
    assert_equal "note.created", captured_headers["X-Harmonic-Event"]
    assert_equal @delivery.id, captured_headers["X-Harmonic-Delivery"]
    assert_equal @automation_run.id, captured_headers["X-Harmonic-Automation-Run"]
    assert captured_headers["X-Harmonic-Signature"].present?
    assert captured_headers["X-Harmonic-Timestamp"].present?
  end

  test "deliver! uses automation trigger type when no event is present" do
    # Create a manual trigger automation without an event
    manual_rule = AutomationRule.create!(
      tenant: @tenant,
      superagent: @superagent,
      name: "Manual Automation",
      trigger_type: "manual",
      trigger_config: { "inputs" => { "message" => { "type" => "string" } } },
      actions: [{ "type" => "webhook", "url" => "https://example.com/manual" }],
      created_by: @user,
    )

    manual_run = AutomationRuleRun.create!(
      tenant: @tenant,
      superagent: @superagent,
      automation_rule: manual_rule,
      trigger_source: "manual",
      status: "running",
    )

    delivery = WebhookDelivery.create!(
      tenant: @tenant,
      automation_rule_run: manual_run,
      event: nil,  # No event for manual triggers
      url: "https://example.com/manual",
      secret: manual_rule.webhook_secret,
      request_body: '{"message":"hello"}',
      status: "pending",
    )

    captured_headers = {}
    stub_request(:post, "https://example.com/manual")
      .to_return(status: 200)
      .with { |req| captured_headers = req.headers; true }

    WebhookDeliveryService.deliver!(delivery)

    assert_equal "automation.manual", captured_headers["X-Harmonic-Event"]
    assert_equal manual_run.id, captured_headers["X-Harmonic-Automation-Run"]
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

  # === deliver_request tests (shared HTTP delivery method) ===

  test "deliver_request sends POST request with HMAC signature" do
    stub_request(:post, "https://example.com/hook")
      .to_return(status: 200, body: '{"ok":true}')

    result = WebhookDeliveryService.deliver_request(
      url: "https://example.com/hook",
      body: '{"test":"data"}',
      secret: "test_secret"
    )

    assert result[:success]
    assert_equal 200, result[:status_code]
    assert_equal '{"ok":true}', result[:body]

    assert_requested(:post, "https://example.com/hook") do |req|
      req.headers["X-Harmonic-Signature"].present? &&
        req.headers["X-Harmonic-Timestamp"].present? &&
        req.headers["Content-Type"] == "application/json"
    end
  end

  test "deliver_request supports custom HTTP methods" do
    stub_request(:put, "https://example.com/hook")
      .to_return(status: 200, body: "")

    result = WebhookDeliveryService.deliver_request(
      url: "https://example.com/hook",
      body: '{"update":true}',
      secret: "test_secret",
      method: "PUT"
    )

    assert result[:success]
    assert_requested(:put, "https://example.com/hook")
  end

  test "deliver_request includes custom headers" do
    stub_request(:post, "https://example.com/hook")
      .to_return(status: 200, body: "")

    WebhookDeliveryService.deliver_request(
      url: "https://example.com/hook",
      body: "{}",
      secret: "test_secret",
      headers: { "Authorization" => "Bearer token123", "X-Custom" => "value" }
    )

    assert_requested(:post, "https://example.com/hook") do |req|
      req.headers["Authorization"] == "Bearer token123" &&
        req.headers["X-Custom"] == "value"
    end
  end

  test "deliver_request returns failure for HTTP errors" do
    stub_request(:post, "https://example.com/hook")
      .to_return(status: 500, body: "Server Error")

    result = WebhookDeliveryService.deliver_request(
      url: "https://example.com/hook",
      body: "{}",
      secret: "test_secret"
    )

    assert_not result[:success]
    assert_equal 500, result[:status_code]
    assert_includes result[:error], "500"
  end

  test "deliver_request returns failure for network errors" do
    stub_request(:post, "https://example.com/hook")
      .to_timeout

    result = WebhookDeliveryService.deliver_request(
      url: "https://example.com/hook",
      body: "{}",
      secret: "test_secret"
    )

    assert_not result[:success]
    assert_nil result[:status_code]
    assert result[:error].present?
  end

  test "deliver_request returns failure for invalid URL" do
    result = WebhookDeliveryService.deliver_request(
      url: "not-a-valid-url",
      body: "{}",
      secret: "test_secret"
    )

    assert_not result[:success]
    assert_includes result[:error].downcase, "invalid"
  end

  test "deliver_request generates verifiable signature" do
    captured_signature = nil
    captured_timestamp = nil
    captured_body = nil

    stub_request(:post, "https://example.com/hook")
      .to_return(status: 200, body: "")
      .with { |req|
        captured_signature = req.headers["X-Harmonic-Signature"]
        captured_timestamp = req.headers["X-Harmonic-Timestamp"]
        captured_body = req.body
        true
      }

    secret = "my_secret_key"
    WebhookDeliveryService.deliver_request(
      url: "https://example.com/hook",
      body: '{"event":"test"}',
      secret: secret
    )

    # Verify the signature can be validated
    assert WebhookDeliveryService.verify_signature(
      captured_body,
      captured_timestamp,
      captured_signature,
      secret
    )
  end
end
