require "test_helper"

class StudioAutomationsControllerTest < ActionDispatch::IntegrationTest
  def setup
    @tenant = @global_tenant
    @tenant.enable_api!
    @collective = @global_collective
    @collective.enable_api!
    @user = @global_user

    # Make user a studio admin
    member = @collective.collective_members.find_by(user: @user)
    member.update!(settings: { "roles" => ["admin"] })

    @api_token = ApiToken.create!(
      tenant: @tenant,
      user: @user,
      scopes: ApiToken.valid_scopes,
    )
    @plaintext_token = @api_token.plaintext_token
    @headers = {
      "Authorization" => "Bearer #{@plaintext_token}",
      "Accept" => "text/markdown",
      "Content-Type" => "application/json",
    }
    host! "#{@tenant.subdomain}.#{ENV['HOSTNAME']}"
  end

  def is_markdown?
    response.content_type.starts_with?("text/markdown")
  end

  def valid_yaml
    <<~YAML
      name: "Studio Automation Test"
      description: "Test description for studio automation"

      trigger:
        type: event
        event_type: note.created

      actions:
        - type: webhook
          url: "https://example.com/webhook"
          method: POST
          payload:
            text: "New note created: {{subject.title}}"
    YAML
  end

  def create_studio_automation_rule(attrs = {})
    defaults = {
      tenant: @tenant,
      collective: @collective,
      ai_agent_id: nil,
      created_by: @user,
      name: "Test Studio Rule",
      trigger_type: "event",
      trigger_config: { "event_type" => "note.created" },
      actions: [{ "type" => "webhook", "url" => "https://example.com" }],
      yaml_source: valid_yaml,
    }
    AutomationRule.unscoped.create!(defaults.merge(attrs))
  end

  # === Index Tests ===

  test "studio admin can view automations index" do
    get "/studios/#{@collective.handle}/settings/automations", headers: @headers
    assert_response :success
    assert is_markdown?
    assert_includes response.body, "Automations"
  end

  test "automations are listed in index" do
    rule = create_studio_automation_rule(name: "Listed Studio Rule")

    get "/studios/#{@collective.handle}/settings/automations", headers: @headers
    assert_response :success
    assert_includes response.body, rule.truncated_id
    assert_includes response.body, "Listed Studio Rule"
  end

  test "index only shows studio rules, not agent rules" do
    # Create a studio rule
    studio_rule = create_studio_automation_rule(name: "Studio Rule")

    # Create an agent rule
    ai_agent = create_ai_agent(parent: @user, name: "Test Agent")
    @tenant.add_user!(ai_agent)
    agent_rule = AutomationRule.unscoped.create!(
      tenant: @tenant,
      ai_agent: ai_agent,
      created_by: @user,
      name: "Agent Rule",
      trigger_type: "event",
      trigger_config: { "event_type" => "note.created" },
      actions: { "task" => "Test task" },
    )

    get "/studios/#{@collective.handle}/settings/automations", headers: @headers
    assert_response :success
    assert_includes response.body, "Studio Rule"
    assert_not_includes response.body, "Agent Rule"
  end

  # === New Page Tests ===

  test "studio admin can view new automation page" do
    get "/studios/#{@collective.handle}/settings/automations/new", headers: @headers
    assert_response :success
    assert is_markdown?
    assert_includes response.body, "New Automation"
  end

  # === Create Tests ===

  test "studio admin can create automation" do
    assert_difference "AutomationRule.unscoped.count" do
      post "/studios/#{@collective.handle}/settings/automations/new/actions/create_automation_rule",
        params: { yaml_source: valid_yaml }.to_json,
        headers: @headers
    end

    assert_response :success
    assert is_markdown?
    assert_includes response.body, "created successfully"

    rule = AutomationRule.unscoped.order(created_at: :desc).first
    assert_equal @collective.id, rule.collective_id
    assert_nil rule.ai_agent_id
    assert_equal @user, rule.created_by
    assert_equal "Studio Automation Test", rule.name
    assert_equal "event", rule.trigger_type
    assert_equal "note.created", rule.event_type
    assert rule.studio_rule?
  end

  test "create requires yaml_source" do
    assert_no_difference "AutomationRule.unscoped.count" do
      post "/studios/#{@collective.handle}/settings/automations/new/actions/create_automation_rule",
        params: {}.to_json,
        headers: @headers
    end

    assert_response :success
    assert_includes response.body, "YAML configuration is required"
  end

  test "create validates yaml for studio rules (requires actions or task)" do
    # Missing both task and actions - should fail validation
    invalid_yaml = <<~YAML
      name: "Missing actions"
      description: "This is invalid - no actions defined"

      trigger:
        type: event
        event_type: note.created
    YAML

    assert_no_difference "AutomationRule.unscoped.count" do
      post "/studios/#{@collective.handle}/settings/automations/new/actions/create_automation_rule",
        params: { yaml_source: invalid_yaml }.to_json,
        headers: @headers
    end

    assert_response :success
    # Should require either actions or task
    assert_includes response.body, "actions is required"
  end

  # === Show Page Tests ===

  test "studio admin can view automation" do
    rule = create_studio_automation_rule(
      name: "My Studio Automation",
      description: "Test description",
    )

    get "/studios/#{@collective.handle}/settings/automations/#{rule.truncated_id}", headers: @headers
    assert_response :success
    assert is_markdown?
    assert_includes response.body, "My Studio Automation"
    assert_includes response.body, "note.created"
  end

  # === Edit Page Tests ===

  test "studio admin can view edit page" do
    rule = create_studio_automation_rule(name: "Editable Rule")

    get "/studios/#{@collective.handle}/settings/automations/#{rule.truncated_id}/edit", headers: @headers
    assert_response :success
    assert is_markdown?
    assert_includes response.body, "Edit"
    assert_includes response.body, rule.yaml_source
  end

  # === Update Tests ===

  test "studio admin can update automation" do
    rule = create_studio_automation_rule(name: "Original Name")

    updated_yaml = <<~YAML
      name: "Updated Name"
      description: "Updated description"

      trigger:
        type: event
        event_type: comment.created

      actions:
        - type: webhook
          url: "https://updated.example.com/webhook"
          method: POST
    YAML

    post "/studios/#{@collective.handle}/settings/automations/#{rule.truncated_id}/actions/update_automation_rule",
      params: { yaml_source: updated_yaml }.to_json,
      headers: @headers

    assert_response :success
    assert_includes response.body, "updated successfully"

    rule.reload
    assert_equal "Updated Name", rule.name
    assert_equal "comment.created", rule.event_type
  end

  # === Delete Tests ===

  test "studio admin can delete automation" do
    rule = create_studio_automation_rule(name: "To Delete")

    assert_difference "AutomationRule.unscoped.count", -1 do
      post "/studios/#{@collective.handle}/settings/automations/#{rule.truncated_id}/actions/delete_automation_rule",
        headers: @headers
    end

    assert_response :success
    assert_includes response.body, "deleted"
  end

  # === Toggle Tests ===

  test "studio admin can toggle automation enabled state" do
    rule = create_studio_automation_rule(name: "Toggle Test", enabled: true)

    post "/studios/#{@collective.handle}/settings/automations/#{rule.truncated_id}/actions/toggle_automation_rule",
      headers: @headers

    assert_response :success
    assert_includes response.body, "disabled"
    rule.reload
    assert_not rule.enabled?

    post "/studios/#{@collective.handle}/settings/automations/#{rule.truncated_id}/actions/toggle_automation_rule",
      headers: @headers

    assert_response :success
    assert_includes response.body, "enabled"
    rule.reload
    assert rule.enabled?
  end

  # === Runs Page Tests ===

  test "studio admin can view automation run history" do
    rule = create_studio_automation_rule(name: "Run History Test")

    AutomationRuleRun.unscoped.create!(
      tenant: @tenant,
      collective: @collective,
      automation_rule: rule,
      trigger_source: "event",
      status: "completed",
    )

    get "/studios/#{@collective.handle}/settings/automations/#{rule.truncated_id}/runs", headers: @headers
    assert_response :success
    assert is_markdown?
    assert_includes response.body, "Run History"
    assert_includes response.body, "completed"
  end

  # === Authorization Tests ===

  test "non-admin cannot view automations" do
    # Remove admin role
    member = @collective.collective_members.find_by(user: @user)
    member.update!(settings: { "roles" => [] })

    get "/studios/#{@collective.handle}/settings/automations", headers: @headers
    assert_response :forbidden
    assert_includes response.body, "admin"
  end

  test "non-admin cannot create automation" do
    member = @collective.collective_members.find_by(user: @user)
    member.update!(settings: { "roles" => [] })

    assert_no_difference "AutomationRule.unscoped.count" do
      post "/studios/#{@collective.handle}/settings/automations/new/actions/create_automation_rule",
        params: { yaml_source: valid_yaml }.to_json,
        headers: @headers
    end

    assert_response :forbidden
  end

  test "non-admin cannot delete automation" do
    rule = create_studio_automation_rule(name: "Protected Rule")

    member = @collective.collective_members.find_by(user: @user)
    member.update!(settings: { "roles" => [] })

    assert_no_difference "AutomationRule.unscoped.count" do
      post "/studios/#{@collective.handle}/settings/automations/#{rule.truncated_id}/actions/delete_automation_rule",
        headers: @headers
    end

    assert_response :forbidden
  end

  # === Webhook Trigger Type Tests ===

  test "can create automation with webhook trigger type" do
    webhook_yaml = <<~YAML
      name: "Webhook Triggered Automation"
      description: "Triggered by external webhook"

      trigger:
        type: webhook

      actions:
        - type: internal_action
          action: create_note
          params:
            text: "Webhook received!"
    YAML

    assert_difference "AutomationRule.unscoped.count" do
      post "/studios/#{@collective.handle}/settings/automations/new/actions/create_automation_rule",
        params: { yaml_source: webhook_yaml }.to_json,
        headers: @headers
    end

    assert_response :success

    rule = AutomationRule.unscoped.order(created_at: :desc).first
    assert_equal "webhook", rule.trigger_type
    assert rule.webhook_path.present?
    assert rule.webhook_secret.present?
  end

  # === Schedule Trigger Type Tests ===

  test "can create automation with schedule trigger type" do
    schedule_yaml = <<~YAML
      name: "Scheduled Automation"
      description: "Runs on a schedule"

      trigger:
        type: schedule
        cron: "0 9 * * *"
        timezone: "America/Los_Angeles"

      actions:
        - type: webhook
          url: "https://example.com/daily"
          method: POST
    YAML

    assert_difference "AutomationRule.unscoped.count" do
      post "/studios/#{@collective.handle}/settings/automations/new/actions/create_automation_rule",
        params: { yaml_source: schedule_yaml }.to_json,
        headers: @headers
    end

    assert_response :success

    rule = AutomationRule.unscoped.order(created_at: :desc).first
    assert_equal "schedule", rule.trigger_type
    assert_equal "0 9 * * *", rule.cron_expression
    assert_equal "America/Los_Angeles", rule.timezone
  end
end
