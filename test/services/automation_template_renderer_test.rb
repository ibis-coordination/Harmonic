# typed: false

require "test_helper"

class AutomationTemplateRendererTest < ActiveSupport::TestCase
  def setup
    @tenant = @global_tenant
    @collective = @global_collective
    @user = @global_user
    Collective.scope_thread_to_collective(
      subdomain: @tenant.subdomain,
      handle: @collective.handle
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

  test "serializes hash values as JSON" do
    context = { "data" => { "a" => 1, "b" => "hello" } }
    result = AutomationTemplateRenderer.render("Data: {{data}}", context)

    # Should output valid JSON, not Ruby hash format
    assert_equal 'Data: {&quot;a&quot;:1,&quot;b&quot;:&quot;hello&quot;}', result
    # The unescaped version should be valid JSON
    assert_nothing_raised { JSON.parse(CGI.unescapeHTML(result.gsub("Data: ", ""))) }
  end

  test "serializes array values as JSON" do
    context = { "items" => [1, 2, "three"] }
    result = AutomationTemplateRenderer.render("Items: {{items}}", context)

    assert_equal 'Items: [1,2,&quot;three&quot;]', result
  end

  test "serializes nested hash in payload as JSON" do
    # Simulates webhook payload with nested data
    context = { "payload" => { "event" => "test", "data" => { "id" => 123, "name" => "Test" } } }
    result = AutomationTemplateRenderer.render("Payload data: {{payload.data}}", context)

    assert_equal 'Payload data: {&quot;id&quot;:123,&quot;name&quot;:&quot;Test&quot;}', result
  end

  test "renders scalar types normally" do
    context = {
      "string" => "hello",
      "number" => 42,
      "float" => 3.14,
      "bool" => true,
    }

    assert_equal "hello", AutomationTemplateRenderer.render("{{string}}", context)
    assert_equal "42", AutomationTemplateRenderer.render("{{number}}", context)
    assert_equal "3.14", AutomationTemplateRenderer.render("{{float}}", context)
    assert_equal "true", AutomationTemplateRenderer.render("{{bool}}", context)
  end

  # === Context Building from Events ===

  test "context_from_event builds event context with actor" do
    note = create_note
    event = Event.create!(
      tenant: @tenant,
      collective: @collective,
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
      collective: @collective,
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
      collective: @collective,
      event_type: "note.created",
      actor: @user,
      subject: note
    )

    context = AutomationTemplateRenderer.context_from_event(event)

    assert_equal @collective.id, context["studio"]["id"]
    assert_equal @collective.handle, context["studio"]["handle"]
    assert_equal @collective.name, context["studio"]["name"]
  end

  test "context_from_event handles nil actor" do
    note = create_note
    event = Event.create!(
      tenant: @tenant,
      collective: @collective,
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
      collective: @collective,
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
      collective: @collective,
      event_type: "note.created",
      actor: @user,
      subject: note
    )

    template = "Activity in {{studio.name}} ({{studio.handle}})"
    context = AutomationTemplateRenderer.context_from_event(event)
    result = AutomationTemplateRenderer.render(template, context)

    assert_includes result, @collective.name
    assert_includes result, @collective.handle
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

  # === Edge Cases for User-Defined Payloads ===

  test "handles deeply nested payload (4+ levels)" do
    trigger_data = {
      "webhook_path" => "deep-webhook",
      "payload" => {
        "level1" => {
          "level2" => {
            "level3" => {
              "level4" => {
                "value" => "deep value",
              },
            },
          },
        },
      },
      "received_at" => "2024-01-15T10:30:00Z",
      "source_ip" => "127.0.0.1",
    }

    template = "Value: {{payload.level1.level2.level3.level4.value}}"
    context = AutomationTemplateRenderer.context_from_trigger_data(trigger_data)
    result = AutomationTemplateRenderer.render(template, context)

    assert_equal "Value: deep value", result
  end

  test "handles missing intermediate key in nested path" do
    trigger_data = {
      "webhook_path" => "test",
      "payload" => { "exists" => "value" },
      "received_at" => "2024-01-15T10:30:00Z",
      "source_ip" => "127.0.0.1",
    }

    template = "Missing: {{payload.does_not.exist.at_all}}"
    context = AutomationTemplateRenderer.context_from_trigger_data(trigger_data)
    result = AutomationTemplateRenderer.render(template, context)

    assert_equal "Missing: ", result
  end

  test "handles payload with special characters in keys" do
    trigger_data = {
      "webhook_path" => "special-keys",
      "payload" => {
        "key-with-dash" => "dashed",
        "key_with_underscore" => "underscored",
        "key.with.dots" => "dotted",
      },
      "received_at" => "2024-01-15T10:30:00Z",
      "source_ip" => "127.0.0.1",
    }

    context = AutomationTemplateRenderer.context_from_trigger_data(trigger_data)

    # Keys with dashes and underscores work
    result = AutomationTemplateRenderer.render("{{payload.key-with-dash}}", context)
    assert_equal "dashed", result

    result = AutomationTemplateRenderer.render("{{payload.key_with_underscore}}", context)
    assert_equal "underscored", result

    # Keys with dots are ambiguous (interpreted as nested access)
    # This behavior is expected - users should avoid dots in key names
    result = AutomationTemplateRenderer.render("{{payload.key.with.dots}}", context)
    assert_equal "", result # Missing because it tries to access payload["key"]["with"]["dots"]
  end

  test "handles payload with numeric values" do
    trigger_data = {
      "webhook_path" => "numeric",
      "payload" => {
        "integer" => 42,
        "float" => 3.14,
        "zero" => 0,
        "negative" => -100,
      },
      "received_at" => "2024-01-15T10:30:00Z",
      "source_ip" => "127.0.0.1",
    }

    template = "Int: {{payload.integer}}, Float: {{payload.float}}, Zero: {{payload.zero}}, Neg: {{payload.negative}}"
    context = AutomationTemplateRenderer.context_from_trigger_data(trigger_data)
    result = AutomationTemplateRenderer.render(template, context)

    assert_equal "Int: 42, Float: 3.14, Zero: 0, Neg: -100", result
  end

  test "handles payload with boolean values" do
    trigger_data = {
      "webhook_path" => "boolean",
      "payload" => {
        "enabled" => true,
        "disabled" => false,
      },
      "received_at" => "2024-01-15T10:30:00Z",
      "source_ip" => "127.0.0.1",
    }

    template = "Enabled: {{payload.enabled}}, Disabled: {{payload.disabled}}"
    context = AutomationTemplateRenderer.context_from_trigger_data(trigger_data)
    result = AutomationTemplateRenderer.render(template, context)

    assert_equal "Enabled: true, Disabled: false", result
  end

  test "handles payload with array values (renders array as string)" do
    trigger_data = {
      "webhook_path" => "array",
      "payload" => {
        "tags" => ["ruby", "rails", "automation"],
        "nested" => { "items" => [1, 2, 3] },
      },
      "received_at" => "2024-01-15T10:30:00Z",
      "source_ip" => "127.0.0.1",
    }

    template = "Tags: {{payload.tags}}"
    context = AutomationTemplateRenderer.context_from_trigger_data(trigger_data)
    result = AutomationTemplateRenderer.render(template, context)

    # Arrays are converted to string representation
    assert_includes result, "ruby"
    assert_includes result, "rails"
  end

  test "escapes HTML in user-provided payload" do
    trigger_data = {
      "webhook_path" => "xss-attempt",
      "payload" => {
        "malicious" => "<script>alert('xss')</script>",
        "nested" => { "also_bad" => "<img onerror='hack()' src='x'>" },
      },
      "received_at" => "2024-01-15T10:30:00Z",
      "source_ip" => "127.0.0.1",
    }

    context = AutomationTemplateRenderer.context_from_trigger_data(trigger_data)

    result = AutomationTemplateRenderer.render("{{payload.malicious}}", context)
    assert_not_includes result, "<script>"
    assert_includes result, "&lt;script&gt;"

    result = AutomationTemplateRenderer.render("{{payload.nested.also_bad}}", context)
    assert_not_includes result, "<img"
    assert_includes result, "&lt;img"
  end

  test "handles payload with empty string values" do
    trigger_data = {
      "webhook_path" => "empty",
      "payload" => {
        "empty" => "",
        "whitespace" => "   ",
      },
      "received_at" => "2024-01-15T10:30:00Z",
      "source_ip" => "127.0.0.1",
    }

    template = "Empty: '{{payload.empty}}', Whitespace: '{{payload.whitespace}}'"
    context = AutomationTemplateRenderer.context_from_trigger_data(trigger_data)
    result = AutomationTemplateRenderer.render(template, context)

    assert_equal "Empty: '', Whitespace: '   '", result
  end

  test "handles payload with null values" do
    trigger_data = {
      "webhook_path" => "nulls",
      "payload" => {
        "null_value" => nil,
        "nested" => { "also_null" => nil },
      },
      "received_at" => "2024-01-15T10:30:00Z",
      "source_ip" => "127.0.0.1",
    }

    template = "Null: '{{payload.null_value}}', Nested: '{{payload.nested.also_null}}'"
    context = AutomationTemplateRenderer.context_from_trigger_data(trigger_data)
    result = AutomationTemplateRenderer.render(template, context)

    assert_equal "Null: '', Nested: ''", result
  end

  test "handles template injection attempt in payload" do
    trigger_data = {
      "webhook_path" => "injection",
      "payload" => {
        "user_input" => "{{webhook.source_ip}}",  # Trying to inject template syntax
        "nested_attempt" => "{{payload.secret}}",
      },
      "received_at" => "2024-01-15T10:30:00Z",
      "source_ip" => "attacker-ip",
    }

    template = "User said: {{payload.user_input}}"
    context = AutomationTemplateRenderer.context_from_trigger_data(trigger_data)
    result = AutomationTemplateRenderer.render(template, context)

    # The template syntax in the payload should be rendered as literal text, not executed
    # HTML escaping converts {{ to escaped form
    assert_not_includes result, "attacker-ip"
    assert_includes result, "webhook.source_ip"
  end

  test "handles very long payload values" do
    long_value = "x" * 10_000
    trigger_data = {
      "webhook_path" => "long",
      "payload" => { "long_text" => long_value },
      "received_at" => "2024-01-15T10:30:00Z",
      "source_ip" => "127.0.0.1",
    }

    template = "Text: {{payload.long_text}}"
    context = AutomationTemplateRenderer.context_from_trigger_data(trigger_data)
    result = AutomationTemplateRenderer.render(template, context)

    assert_equal "Text: #{long_value}", result
    assert_equal 10_006, result.length # "Text: " + 10000 x's
  end

  test "handles unicode in payload" do
    trigger_data = {
      "webhook_path" => "unicode",
      "payload" => {
        "emoji" => "🎉 Celebration! 🚀",
        "chinese" => "你好世界",
        "arabic" => "مرحبا",
        "mixed" => "Hello 世界 🌍",
      },
      "received_at" => "2024-01-15T10:30:00Z",
      "source_ip" => "127.0.0.1",
    }

    template = "{{payload.emoji}} - {{payload.chinese}} - {{payload.mixed}}"
    context = AutomationTemplateRenderer.context_from_trigger_data(trigger_data)
    result = AutomationTemplateRenderer.render(template, context)

    assert_includes result, "🎉"
    assert_includes result, "你好世界"
    assert_includes result, "🌍"
  end

  # === Context Building from Manual Trigger Inputs ===

  test "context_from_trigger_data exposes manual inputs" do
    trigger_data = {
      "test" => true,
      "inputs" => {
        "message" => "hello world",
        "count" => 42,
      },
    }

    context = AutomationTemplateRenderer.context_from_trigger_data(trigger_data)

    assert_equal "hello world", context["inputs"]["message"]
    assert_equal 42, context["inputs"]["count"]
  end

  test "renders template with manual trigger inputs" do
    trigger_data = {
      "test" => true,
      "inputs" => {
        "message" => "hello world",
        "priority" => "high",
      },
    }

    template = "Message: {{inputs.message}}, Priority: {{inputs.priority}}"
    context = AutomationTemplateRenderer.context_from_trigger_data(trigger_data)
    result = AutomationTemplateRenderer.render(template, context)

    assert_equal "Message: hello world, Priority: high", result
  end

  test "handles missing inputs in manual trigger" do
    trigger_data = {
      "test" => true,
      "inputs" => {},
    }

    template = "Message: {{inputs.message}}"
    context = AutomationTemplateRenderer.context_from_trigger_data(trigger_data)
    result = AutomationTemplateRenderer.render(template, context)

    assert_equal "Message: ", result
  end
end
