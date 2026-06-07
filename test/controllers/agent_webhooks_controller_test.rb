require "test_helper"

class AgentWebhooksControllerTest < ActionDispatch::IntegrationTest
  def setup
    @tenant = @global_tenant
    @tenant.set_feature_flag!("external_ai_agents", true)
    @collective = @global_collective
    @user = @global_user

    @external_agent = create_ai_agent(parent: @user, name: "External Webhook Agent", agent_configuration: { "mode" => "external" })
    @tenant.add_user!(@external_agent)

    @internal_agent = create_ai_agent(parent: @user, name: "Internal Agent", agent_configuration: { "mode" => "internal" })
    @tenant.add_user!(@internal_agent)

    host! "#{@tenant.subdomain}.#{ENV['HOSTNAME']}"
    sign_in_as(@user)
  end

  def existing_webhook_rule
    AutomationRule.unscoped.create!(
      tenant: @tenant,
      ai_agent: @external_agent,
      created_by: @user,
      name: "existing-webhook",
      trigger_type: "event",
      trigger_config: { "event_type" => "note.created", "mention_filter" => "self" },
      actions: {
        "webhook_url" => "https://parent.example.com/hook",
        "signing_secret" => "whsec_existing",
        "payload_template" => {},
      },
      enabled: true,
    )
  end

  # === Index ===

  test "index renders for external agents" do
    get "/ai-agents/#{@external_agent.handle}/webhooks"
    assert_response :success
    assert_includes response.body, "Webhooks"
  end

  test "index 404s for internal agents" do
    get "/ai-agents/#{@internal_agent.handle}/webhooks"
    assert_response :not_found
  end

  test "non-parent user gets redirected" do
    other_user = create_user(name: "Other")
    @tenant.add_user!(other_user)
    sign_in_as(other_user)

    get "/ai-agents/#{@external_agent.handle}/webhooks"
    assert_response :redirect
  end

  # === New ===

  test "new renders for external agents" do
    get "/ai-agents/#{@external_agent.handle}/webhooks/new"
    assert_response :success
    assert_includes response.body, "New webhook"
  end

  # === Create ===

  test "create with valid HTTPS URL persists rule and reveals secret once" do
    assert_difference "AutomationRule.count", 1 do
      post "/ai-agents/#{@external_agent.handle}/webhooks", params: {
        name: "My Webhook",
        webhook_url: "https://parent.example.com/hook",
        trigger: "mention_in_note",
      }
    end
    assert_response :success # renders show_secret inline
    assert_includes response.body, "whsec_"

    rule = AutomationRule.last
    assert_equal "My Webhook", rule.name
    assert_equal "https://parent.example.com/hook", rule.actions["webhook_url"]
    assert rule.actions["signing_secret"].present?
    assert_equal "self", rule.mention_filter
    assert_equal "note.created", rule.event_type
  end

  test "create with http URL is rejected" do
    assert_no_difference "AutomationRule.count" do
      post "/ai-agents/#{@external_agent.handle}/webhooks", params: {
        webhook_url: "http://parent.example.com/hook",
        trigger: "mention_in_note",
      }
    end
    assert_response :unprocessable_entity
    assert_includes response.body.downcase, "https"
  end

  test "create without webhook_url is rejected" do
    assert_no_difference "AutomationRule.count" do
      post "/ai-agents/#{@external_agent.handle}/webhooks", params: {
        trigger: "mention_in_note",
      }
    end
    assert_response :unprocessable_entity
  end

  test "create maps trigger options to event_type and mention_filter" do
    post "/ai-agents/#{@external_agent.handle}/webhooks", params: {
      webhook_url: "https://parent.example.com/hook",
      trigger: "comment_on_my_content",
    }
    rule = AutomationRule.last
    assert_equal "comment.created", rule.event_type
    assert_equal "self_or_reply", rule.mention_filter
  end

  test "create for internal agent 404s" do
    post "/ai-agents/#{@internal_agent.handle}/webhooks", params: {
      webhook_url: "https://parent.example.com/hook",
      trigger: "mention_in_note",
    }
    assert_response :not_found
  end

  # === Edit ===

  test "edit shows form and recent deliveries" do
    rule = existing_webhook_rule

    get "/ai-agents/#{@external_agent.handle}/webhooks/#{rule.truncated_id}/edit"
    assert_response :success
    assert_includes response.body, rule.name
    assert_includes response.body, "Recent deliveries"
  end

  # === Update ===

  test "update changes URL and trigger but preserves signing secret" do
    rule = existing_webhook_rule
    original_secret = rule.actions["signing_secret"]

    patch "/ai-agents/#{@external_agent.handle}/webhooks/#{rule.truncated_id}", params: {
      name: "renamed",
      webhook_url: "https://parent.example.com/different",
      trigger: "mention_in_comment",
    }
    assert_response :redirect

    rule.reload
    assert_equal "renamed", rule.name
    assert_equal "https://parent.example.com/different", rule.actions["webhook_url"]
    assert_equal original_secret, rule.actions["signing_secret"]
    assert_equal "comment.created", rule.event_type
    assert_equal "self", rule.mention_filter
  end

  # === Destroy ===

  test "destroy removes the rule" do
    rule = existing_webhook_rule

    assert_difference "AutomationRule.count", -1 do
      delete "/ai-agents/#{@external_agent.handle}/webhooks/#{rule.truncated_id}"
    end
    assert_response :redirect
  end

  # === Toggle ===

  test "toggle flips enabled flag" do
    rule = existing_webhook_rule
    assert rule.enabled?

    post "/ai-agents/#{@external_agent.handle}/webhooks/#{rule.truncated_id}/toggle"
    assert_response :redirect
    assert_not rule.reload.enabled?

    post "/ai-agents/#{@external_agent.handle}/webhooks/#{rule.truncated_id}/toggle"
    assert_response :redirect
    assert rule.reload.enabled?
  end

  # === Rotate secret ===

  test "rotate_secret generates new secret and shows once" do
    rule = existing_webhook_rule
    old_secret = rule.actions["signing_secret"]

    post "/ai-agents/#{@external_agent.handle}/webhooks/#{rule.truncated_id}/rotate_secret"
    assert_response :success
    assert_includes response.body, "whsec_"

    rule.reload
    assert_not_equal old_secret, rule.actions["signing_secret"]
  end
end
