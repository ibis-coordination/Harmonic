# typed: false

require "test_helper"

class AutomationWebhookSenderTest < ActiveSupport::TestCase
  setup do
    @tenant, @superagent, @user = create_tenant_studio_user

    # Create a test event for context
    @note = Note.create!(
      tenant: @tenant,
      superagent: @superagent,
      created_by: @user,
      text: "Test note content"
    )
    @event = Event.create!(
      tenant: @tenant,
      superagent: @superagent,
      event_type: "note.created",
      actor: @user,
      subject: @note
    )
  end

  # === Basic Webhook Sending ===

  test "sends POST request to webhook URL" do
    stub_request(:post, "https://example.com/webhook")
      .to_return(status: 200, body: '{"ok": true}')

    action = {
      "type" => "webhook",
      "url" => "https://example.com/webhook",
      "body" => { "message" => "Hello" },
    }

    result = AutomationWebhookSender.call(action, @event)

    assert result[:success]
    assert_equal 200, result[:status_code]
    assert_requested(:post, "https://example.com/webhook") do |req|
      body = JSON.parse(req.body)
      body["message"] == "Hello"
    end
  end

  test "sends JSON content type header" do
    stub_request(:post, "https://example.com/webhook")
      .to_return(status: 200, body: "")

    action = {
      "type" => "webhook",
      "url" => "https://example.com/webhook",
      "body" => { "key" => "value" },
    }

    AutomationWebhookSender.call(action, @event)

    assert_requested(:post, "https://example.com/webhook") do |req|
      req.headers["Content-Type"] == "application/json"
    end
  end

  # === Template Rendering ===

  test "renders template variables in body" do
    stub_request(:post, "https://example.com/webhook")
      .to_return(status: 200, body: "")

    action = {
      "type" => "webhook",
      "url" => "https://example.com/webhook",
      "body" => {
        "event_type" => "{{event.type}}",
        "actor_name" => "{{event.actor.name}}",
        "note_text" => "{{subject.text}}",
      },
    }

    AutomationWebhookSender.call(action, @event)

    assert_requested(:post, "https://example.com/webhook") do |req|
      body = JSON.parse(req.body)
      body["event_type"] == "note.created" &&
        body["actor_name"] == @user.display_name &&
        body["note_text"] == "Test note content"
    end
  end

  test "renders nested template variables" do
    stub_request(:post, "https://example.com/webhook")
      .to_return(status: 200, body: "")

    action = {
      "type" => "webhook",
      "url" => "https://example.com/webhook",
      "body" => {
        "data" => {
          "nested" => {
            "value" => "Event: {{event.type}}",
          },
        },
      },
    }

    AutomationWebhookSender.call(action, @event)

    assert_requested(:post, "https://example.com/webhook") do |req|
      body = JSON.parse(req.body)
      body.dig("data", "nested", "value") == "Event: note.created"
    end
  end

  # === Custom Headers ===

  test "includes custom headers when specified" do
    stub_request(:post, "https://example.com/webhook")
      .to_return(status: 200, body: "")

    action = {
      "type" => "webhook",
      "url" => "https://example.com/webhook",
      "body" => { "message" => "test" },
      "headers" => {
        "X-Custom-Header" => "custom-value",
        "Authorization" => "Bearer token123",
      },
    }

    AutomationWebhookSender.call(action, @event)

    assert_requested(:post, "https://example.com/webhook") do |req|
      req.headers["X-Custom-Header"] == "custom-value" &&
        req.headers["Authorization"] == "Bearer token123"
    end
  end

  # === HTTP Methods ===

  test "uses POST by default" do
    stub_request(:post, "https://example.com/webhook")
      .to_return(status: 200, body: "")

    action = {
      "type" => "webhook",
      "url" => "https://example.com/webhook",
      "body" => {},
    }

    AutomationWebhookSender.call(action, @event)

    assert_requested(:post, "https://example.com/webhook")
  end

  test "supports custom HTTP method" do
    stub_request(:put, "https://example.com/webhook")
      .to_return(status: 200, body: "")

    action = {
      "type" => "webhook",
      "url" => "https://example.com/webhook",
      "method" => "PUT",
      "body" => { "update" => true },
    }

    AutomationWebhookSender.call(action, @event)

    assert_requested(:put, "https://example.com/webhook")
  end

  # === Error Handling ===

  test "returns failure result for HTTP error" do
    stub_request(:post, "https://example.com/webhook")
      .to_return(status: 500, body: "Internal Server Error")

    action = {
      "type" => "webhook",
      "url" => "https://example.com/webhook",
      "body" => { "message" => "test" },
    }

    result = AutomationWebhookSender.call(action, @event)

    assert_not result[:success]
    assert_equal 500, result[:status_code]
    assert_includes result[:error], "HTTP 500"
  end

  test "returns failure result for network error" do
    stub_request(:post, "https://example.com/webhook")
      .to_timeout

    action = {
      "type" => "webhook",
      "url" => "https://example.com/webhook",
      "body" => { "message" => "test" },
    }

    result = AutomationWebhookSender.call(action, @event)

    assert_not result[:success]
    assert_includes result[:error].downcase, "timeout"
  end

  test "returns failure result for invalid URL" do
    action = {
      "type" => "webhook",
      "url" => "not-a-valid-url",
      "body" => { "message" => "test" },
    }

    result = AutomationWebhookSender.call(action, @event)

    assert_not result[:success]
    assert_includes result[:error].downcase, "invalid"
  end

  test "returns failure result for missing URL" do
    action = {
      "type" => "webhook",
      "body" => { "message" => "test" },
    }

    result = AutomationWebhookSender.call(action, @event)

    assert_not result[:success]
    assert_includes result[:error].downcase, "url"
  end

  # === Timeout ===

  test "respects timeout setting" do
    stub_request(:post, "https://example.com/webhook")
      .to_return(status: 200, body: "")

    action = {
      "type" => "webhook",
      "url" => "https://example.com/webhook",
      "body" => {},
      "timeout" => 5,
    }

    # This test primarily verifies the timeout is passed through
    # without error; actually testing timeout behavior would require
    # more complex setup
    result = AutomationWebhookSender.call(action, @event)
    assert result[:success]
  end

  # === Without Event Context ===

  test "works without event context (scheduled triggers)" do
    stub_request(:post, "https://example.com/webhook")
      .to_return(status: 200, body: "")

    action = {
      "type" => "webhook",
      "url" => "https://example.com/webhook",
      "body" => { "message" => "Scheduled notification" },
    }

    result = AutomationWebhookSender.call(action, nil)

    assert result[:success]
    assert_requested(:post, "https://example.com/webhook") do |req|
      body = JSON.parse(req.body)
      body["message"] == "Scheduled notification"
    end
  end

  test "leaves template variables unrendered without event" do
    stub_request(:post, "https://example.com/webhook")
      .to_return(status: 200, body: "")

    action = {
      "type" => "webhook",
      "url" => "https://example.com/webhook",
      "body" => { "actor" => "{{event.actor.name}}" },
    }

    result = AutomationWebhookSender.call(action, nil)

    assert result[:success]
    assert_requested(:post, "https://example.com/webhook") do |req|
      body = JSON.parse(req.body)
      # Without event context, template variable remains as-is or becomes empty
      body["actor"] == "" || body["actor"] == "{{event.actor.name}}"
    end
  end
end
