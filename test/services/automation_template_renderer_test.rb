# typed: false

require "test_helper"

class AutomationTemplateRendererTest < ActiveSupport::TestCase
  def setup
    @tenant = @global_tenant
    @superagent = @global_superagent
    @user = @global_user
    Superagent.scope_thread_to_superagent(
      subdomain: @tenant.subdomain,
      handle: @superagent.handle
    )
  end

  # === Basic Template Rendering ===

  test "renders simple variable" do
    context = { "name" => "Alice" }
    result = AutomationTemplateRenderer.render("Hello, {{name}}!", context)

    assert_equal "Hello, Alice!", result
  end

  test "renders nested variables" do
    context = { "user" => { "name" => "Bob", "email" => "bob@example.com" } }
    result = AutomationTemplateRenderer.render("Name: {{user.name}}, Email: {{user.email}}", context)

    assert_equal "Name: Bob, Email: bob@example.com", result
  end

  test "renders empty string for missing variable" do
    context = { "name" => "Alice" }
    result = AutomationTemplateRenderer.render("Hello, {{unknown}}!", context)

    assert_equal "Hello, !", result
  end

  test "renders empty string for missing nested variable" do
    context = { "user" => { "name" => "Alice" } }
    result = AutomationTemplateRenderer.render("Email: {{user.email}}", context)

    assert_equal "Email: ", result
  end

  test "escapes HTML in output" do
    context = { "text" => "<script>alert('xss')</script>" }
    result = AutomationTemplateRenderer.render("Text: {{text}}", context)

    assert_equal "Text: &lt;script&gt;alert(&#39;xss&#39;)&lt;/script&gt;", result
  end

  # === Context Building from Events ===

  test "context_from_event builds event context with actor" do
    note = create_note
    event = Event.create!(
      tenant: @tenant,
      superagent: @superagent,
      event_type: "note.created",
      actor: @user,
      subject: note
    )

    context = AutomationTemplateRenderer.context_from_event(event)

    assert_equal "note.created", context["event"]["type"]
    assert_equal @user.id, context["event"]["actor"]["id"]
    assert_equal @user.display_name, context["event"]["actor"]["name"]
    assert_equal @user.tenant_user.handle, context["event"]["actor"]["handle"]
  end

  test "context_from_event builds subject context" do
    note = create_note
    event = Event.create!(
      tenant: @tenant,
      superagent: @superagent,
      event_type: "note.created",
      actor: @user,
      subject: note
    )

    context = AutomationTemplateRenderer.context_from_event(event)

    assert_equal note.id, context["subject"]["id"]
    assert_equal "note", context["subject"]["type"]
    assert_equal note.path, context["subject"]["path"]
  end

  test "context_from_event builds studio context" do
    note = create_note
    event = Event.create!(
      tenant: @tenant,
      superagent: @superagent,
      event_type: "note.created",
      actor: @user,
      subject: note
    )

    context = AutomationTemplateRenderer.context_from_event(event)

    assert_equal @superagent.id, context["studio"]["id"]
    assert_equal @superagent.handle, context["studio"]["handle"]
    assert_equal @superagent.name, context["studio"]["name"]
  end

  test "context_from_event handles nil actor" do
    note = create_note
    event = Event.create!(
      tenant: @tenant,
      superagent: @superagent,
      event_type: "note.created",
      actor: nil,
      subject: note
    )

    context = AutomationTemplateRenderer.context_from_event(event)

    assert_nil context["event"]["actor"]
  end

  # === Full Template Rendering with Event Context ===

  test "renders template with event actor name" do
    note = create_note
    event = Event.create!(
      tenant: @tenant,
      superagent: @superagent,
      event_type: "note.created",
      actor: @user,
      subject: note
    )

    template = "You were mentioned by {{event.actor.name}} in {{subject.path}}."
    context = AutomationTemplateRenderer.context_from_event(event)
    result = AutomationTemplateRenderer.render(template, context)

    assert_includes result, @user.display_name
    assert_includes result, note.path
  end

  test "renders template with studio info" do
    note = create_note
    event = Event.create!(
      tenant: @tenant,
      superagent: @superagent,
      event_type: "note.created",
      actor: @user,
      subject: note
    )

    template = "Activity in {{studio.name}} ({{studio.handle}})"
    context = AutomationTemplateRenderer.context_from_event(event)
    result = AutomationTemplateRenderer.render(template, context)

    assert_includes result, @superagent.name
    assert_includes result, @superagent.handle
  end

  # === Context Building from Trigger Data (webhooks) ===

  test "context_from_trigger_data exposes payload hash" do
    trigger_data = {
      "webhook_path" => "abc123",
      "payload" => { "event" => "user.created", "data" => { "user_id" => 42 } },
      "received_at" => "2024-01-15T10:30:00Z",
      "source_ip" => "192.168.1.100",
    }

    context = AutomationTemplateRenderer.context_from_trigger_data(trigger_data)

    assert_equal "user.created", context["payload"]["event"]
    assert_equal 42, context["payload"]["data"]["user_id"]
  end

  test "context_from_trigger_data exposes webhook metadata" do
    trigger_data = {
      "webhook_path" => "abc123",
      "payload" => {},
      "received_at" => "2024-01-15T10:30:00Z",
      "source_ip" => "192.168.1.100",
    }

    context = AutomationTemplateRenderer.context_from_trigger_data(trigger_data)

    assert_equal "abc123", context["webhook"]["path"]
    assert_equal "2024-01-15T10:30:00Z", context["webhook"]["received_at"]
    assert_equal "192.168.1.100", context["webhook"]["source_ip"]
  end

  test "context_from_trigger_data wraps string payload in raw key" do
    trigger_data = {
      "webhook_path" => "abc123",
      "payload" => "plain text payload",
      "received_at" => "2024-01-15T10:30:00Z",
      "source_ip" => "127.0.0.1",
    }

    context = AutomationTemplateRenderer.context_from_trigger_data(trigger_data)

    assert_equal "plain text payload", context["payload"]["raw"]
  end

  test "context_from_trigger_data handles nil payload" do
    trigger_data = {
      "webhook_path" => "abc123",
      "payload" => nil,
      "received_at" => "2024-01-15T10:30:00Z",
      "source_ip" => "127.0.0.1",
    }

    context = AutomationTemplateRenderer.context_from_trigger_data(trigger_data)

    assert_nil context["payload"]
    assert_equal "abc123", context["webhook"]["path"]
  end

  # === Full Template Rendering with Webhook Context ===

  test "renders template with webhook payload data" do
    trigger_data = {
      "webhook_path" => "deploy-hook",
      "payload" => { "environment" => "production", "version" => "1.2.3" },
      "received_at" => "2024-01-15T10:30:00Z",
      "source_ip" => "10.0.0.1",
    }

    template = "Deploy {{payload.version}} to {{payload.environment}}"
    context = AutomationTemplateRenderer.context_from_trigger_data(trigger_data)
    result = AutomationTemplateRenderer.render(template, context)

    assert_equal "Deploy 1.2.3 to production", result
  end

  test "renders template with webhook metadata" do
    trigger_data = {
      "webhook_path" => "github-webhook",
      "payload" => { "action" => "opened" },
      "received_at" => "2024-01-15T10:30:00Z",
      "source_ip" => "140.82.112.1",
    }

    template = "Webhook {{webhook.path}} received from {{webhook.source_ip}}"
    context = AutomationTemplateRenderer.context_from_trigger_data(trigger_data)
    result = AutomationTemplateRenderer.render(template, context)

    assert_equal "Webhook github-webhook received from 140.82.112.1", result
  end

  test "renders template with nested webhook payload" do
    trigger_data = {
      "webhook_path" => "stripe-webhook",
      "payload" => {
        "type" => "payment.succeeded",
        "data" => {
          "object" => {
            "amount" => 2000,
            "currency" => "usd",
          },
        },
      },
      "received_at" => "2024-01-15T10:30:00Z",
      "source_ip" => "54.187.174.169",
    }

    template = "Payment of {{payload.data.object.amount}} {{payload.data.object.currency}} succeeded"
    context = AutomationTemplateRenderer.context_from_trigger_data(trigger_data)
    result = AutomationTemplateRenderer.render(template, context)

    assert_equal "Payment of 2000 usd succeeded", result
  end
end
