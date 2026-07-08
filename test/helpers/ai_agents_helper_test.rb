# typed: false

require "test_helper"

class AiAgentsHelperTest < ActionView::TestCase
  include AiAgentsHelper

  test "strip_trailing_json_action removes fenced JSON block at end" do
    response = <<~RESPONSE
      I will go to the collective to create a note.

      Let me check the available actions first.

      ```json
      {"type": "navigate", "path": "/collectives/test"}
      ```
    RESPONSE

    result = strip_trailing_json_action(response)

    assert_includes result, "I will go to the collective"
    assert_includes result, "Let me check the available actions first."
    assert_not_includes result, "```json"
    assert_not_includes result, '"type"'
    assert_not_includes result, '"/collectives/test"'
  end

  test "strip_trailing_json_action removes fenced JSON with nested objects" do
    response = <<~RESPONSE
      I'll create a note with the title "Hello World".

      ```json
      {"type": "execute", "action": "create_note", "params": {"title": "Hello World", "body": "Test content"}}
      ```
    RESPONSE

    result = strip_trailing_json_action(response)

    assert_includes result, "I'll create a note"
    assert_not_includes result, "```json"
    assert_not_includes result, '"params"'
  end

  test "strip_trailing_json_action removes raw JSON at end" do
    response = <<~RESPONSE
      The task is complete. I've created the note successfully.

      {"type": "done", "message": "Created note successfully"}
    RESPONSE

    result = strip_trailing_json_action(response)

    assert_includes result, "The task is complete"
    assert_not_includes result, '"type"'
    assert_not_includes result, '"done"'
  end

  test "strip_trailing_json_action preserves content without JSON" do
    response = "This is just regular text without any JSON."

    result = strip_trailing_json_action(response)

    assert_equal "This is just regular text without any JSON.", result
  end

  test "strip_trailing_json_action handles nil input" do
    result = strip_trailing_json_action(nil)
    assert_equal "", result
  end

  test "strip_trailing_json_action handles blank input" do
    result = strip_trailing_json_action("")
    assert_equal "", result
  end

  test "strip_trailing_json_action preserves JSON in middle of response" do
    response = <<~RESPONSE
      Here's an example of JSON:
      ```json
      {"example": "value"}
      ```
      And here's my actual action:
      ```json
      {"type": "navigate", "path": "/"}
      ```
    RESPONSE

    result = strip_trailing_json_action(response)

    # Should keep the first JSON block but remove the trailing action
    assert_includes result, '{"example": "value"}'
    assert_not_includes result, '"type": "navigate"'
  end

  # === safe_internal_path? ===
  #
  # Guards the `display_path` -> `<a href>` render in show_mcp_tool_call and
  # show_run against a scheme-bearing value ever reaching the column. These
  # cases are the exploit shapes a regression would have to slip through.

  test "safe_internal_path? accepts a same-origin relative path" do
    assert safe_internal_path?("/collectives/team/n/abc123")
    assert safe_internal_path?("/workspace/foo/d/xyz?comment_id=q1")
    assert safe_internal_path?("/")
  end

  test "safe_internal_path? rejects a javascript: URI" do
    assert_not safe_internal_path?("javascript:alert(document.cookie)")
    assert_not safe_internal_path?("JavaScript:alert(1)")
  end

  test "safe_internal_path? rejects data: and other schemes" do
    assert_not safe_internal_path?("data:text/html,<script>alert(1)</script>")
    assert_not safe_internal_path?("http://evil.example/x")
    assert_not safe_internal_path?("https://evil.example/x")
  end

  test "safe_internal_path? rejects a protocol-relative host" do
    assert_not safe_internal_path?("//evil.example/x")
  end

  test "safe_internal_path? rejects blank and nil" do
    assert_not safe_internal_path?(nil)
    assert_not safe_internal_path?("")
    assert_not safe_internal_path?("   ")
  end

  test "available_llm_models returns models from litellm config" do
    models = available_llm_models

    assert_kind_of Array, models
    assert_not_empty models
    assert_includes models, "default"
  end

  test "available_llm_models returns all configured models" do
    models = available_llm_models

    # These models are defined in config/litellm_config.yaml. Gateway-servable
    # models use the Stripe gateway's provider/model names 1-to-1.
    assert_includes models, "default"
    assert_includes models, "anthropic/claude-haiku-4.5"
    assert_includes models, "llama3"
  end

  # === model_pricing_rows ===

  # Stands in for @current_tenant in these view-helper tests.
  class FakeTenant
    attr_reader :enabled_gateway_models

    def initialize(stripe_billing:, enabled_gateway_models: [])
      @stripe_billing = stripe_billing
      @enabled_gateway_models = enabled_gateway_models
    end

    def feature_enabled?(flag)
      flag == "stripe_billing" ? @stripe_billing : false
    end
  end

  # A tenant's configured offering plus a catalog that prices the offering and
  # one un-offered model, to prove the rows are the intersection in order.
  OFFERING = ["anthropic/claude-sonnet-4.6", "anthropic/claude-haiku-4.5", "openai/gpt-5.1"].freeze

  def billing_tenant(enabled: OFFERING)
    FakeTenant.new(stripe_billing: true, enabled_gateway_models: enabled)
  end

  def catalog_for(models)
    models.index_with { |_m| { input_per_million: "1.00", output_per_million: "2.00" } }
      .merge("openai/gpt-5-nano" => { input_per_million: "0.05", output_per_million: "0.40" })
  end

  test "model_pricing_rows returns offered+priced models in the offering's order" do
    @current_tenant = billing_tenant
    # Price only the first two offered models, plus an un-offered one.
    priced = OFFERING.first(2)
    catalog = priced.index_with { |_m| { input_per_million: "3.90", output_per_million: "19.50" } }
      .merge("openai/gpt-5-nano" => { input_per_million: "0.05", output_per_million: "0.40" })

    GatewayModelCatalog.stub(:prices, catalog) do
      rows = model_pricing_rows

      assert_equal priced, rows.map { |r| r[:name] }, "rows follow the offering order, intersected with prices"
      assert_not_includes rows.map { |r| r[:name] }, "openai/gpt-5-nano", "priced but not offered → excluded"
      assert_equal "3.90", rows.first[:input]
      assert_equal "19.50", rows.first[:output]
    end
  end

  test "model_pricing_rows is empty when billing is off" do
    @current_tenant = FakeTenant.new(stripe_billing: false, enabled_gateway_models: OFFERING)
    GatewayModelCatalog.stub(:prices, catalog_for(OFFERING)) do
      assert_empty model_pricing_rows
    end
  end

  test "model_pricing_rows is empty when the catalog is unavailable" do
    @current_tenant = billing_tenant
    GatewayModelCatalog.stub(:prices, {}) do
      assert_empty model_pricing_rows
    end
  end

  # === selectable_models ===

  test "selectable_models is the tenant's offering intersected with prices" do
    @current_tenant = billing_tenant
    GatewayModelCatalog.stub(:prices, catalog_for(OFFERING)) do
      # Exactly the offering (all priced here), in order — and never the
      # un-offered gpt-5-nano that the catalog also prices.
      assert_equal OFFERING, selectable_models
      assert_not_includes selectable_models, "openai/gpt-5-nano"
    end
  end

  test "selectable_models matches model_pricing_rows exactly" do
    @current_tenant = billing_tenant
    # Price only some of the offering; the two views must still agree.
    catalog = OFFERING.first(2).index_with { |_m| { input_per_million: "1.00", output_per_million: "2.00" } }
    GatewayModelCatalog.stub(:prices, catalog) do
      assert_equal(selectable_models, model_pricing_rows.map { |r| r[:name] })
    end
  end

  test "selectable_models defaults to the litellm gateway models when the tenant has no offering" do
    @current_tenant = billing_tenant(enabled: [])
    GatewayModelCatalog.stub(:prices, catalog_for(OFFERING)) do
      # Nothing configured → default to the litellm models the rate card prices
      # (not an empty select, and not the raw list with "default"/local models).
      assert_equal ["anthropic/claude-sonnet-4.6", "anthropic/claude-haiku-4.5"], selectable_models
    end
  end

  test "selectable_models falls back to the litellm list when billing is off" do
    @current_tenant = FakeTenant.new(stripe_billing: false)

    models = selectable_models
    assert_includes models, "default"
    assert_includes models, "llama3"
  end

  test "selectable_models falls back to the litellm list when the catalog is unavailable" do
    @current_tenant = billing_tenant

    GatewayModelCatalog.stub(:prices, {}) do
      assert_includes selectable_models, "default"
    end
  end

  test "offered_gateway_models is the tenant's configured set" do
    @current_tenant = billing_tenant
    assert_equal OFFERING, offered_gateway_models
  end
end
