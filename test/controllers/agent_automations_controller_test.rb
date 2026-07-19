require "test_helper"

class AgentAutomationsControllerTest < ActionDispatch::IntegrationTest
  def setup
    @tenant = @global_tenant
    @tenant.set_feature_flag!("internal_ai_agents", true)
    @tenant.set_feature_flag!("external_ai_agents", true)
    @tenant.set_feature_flag!("automations", true)
    @tenant.enable_api!
    @collective = @global_collective
    @collective.enable_api!
    @user = @global_user

    # Create an AI agent
    @ai_agent = create_ai_agent(parent: @user, name: "Test Agent")
    @tenant.add_user!(@ai_agent)

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
    host! "#{@tenant.subdomain}.#{ENV.fetch("HOSTNAME", nil)}"
  end

  def is_markdown?
    response.content_type.starts_with?("text/markdown")
  end

  def valid_yaml
    <<~YAML
      name: "Test Automation"
      description: "Test description"

      trigger:
        type: event
        event_type: note.created
        mention_filter: self

      task: |
        You were mentioned by {{event.actor.name}}.

      max_steps: 20
    YAML
  end

  def create_automation_rule(attrs = {})
    defaults = {
      tenant: @tenant,
      ai_agent: @ai_agent,
      created_by: @user,
      name: "Test Rule",
      trigger_type: "event",
      trigger_config: { "event_type" => "note.created" },
      actions: { "task" => "Test task" },
      yaml_source: valid_yaml,
    }
    # Use unscoped to bypass default scope during test record creation
    AutomationRule.unscoped.create!(defaults.merge(attrs))
  end

  # === Feature flag gating ===

  test "index returns not_found when automations flag is off" do
    @tenant.set_feature_flag!("automations", false)

    get "/ai-agents/#{@ai_agent.handle}/automations", headers: @headers
    assert_response :not_found
  end

  test "new redirects external agents to their settings page (notification webhook lives there)" do
    external_agent = create_ai_agent(parent: @user, name: "Webhooks Test Agent", agent_configuration: { "mode" => "external" })
    @tenant.add_user!(external_agent)

    sign_in_as(@user)
    get "/ai-agents/#{external_agent.handle}/automations/new"
    assert_response :redirect
    assert_match %r{/settings\z}, response.headers["Location"]
  end

  # === Index Tests ===

  test "parent can view ai_agent automations" do
    get "/ai-agents/#{@ai_agent.handle}/automations", headers: @headers
    assert_response :success
    assert is_markdown?
    assert_includes response.body, "Automations for #{@ai_agent.display_name}"
  end

  test "automations are listed in index" do
    rule = create_automation_rule(name: "Listed Rule")

    get "/ai-agents/#{@ai_agent.handle}/automations", headers: @headers
    assert_response :success
    assert_includes response.body, rule.truncated_id
    assert_includes response.body, "Listed Rule"
  end

  # === New Page Tests ===

  test "parent can view new automation page" do
    get "/ai-agents/#{@ai_agent.handle}/automations/new", headers: @headers
    assert_response :success
    assert is_markdown?
    assert_includes response.body, "New Automation"
  end

  test "new page loads template when specified" do
    get "/ai-agents/#{@ai_agent.handle}/automations/new?template=respond_to_mentions", headers: @headers
    assert_response :success
    assert_includes response.body, "Respond to mentions"
  end

  # === Templates Page Tests ===

  test "parent can view templates page" do
    get "/ai-agents/#{@ai_agent.handle}/automations/templates", headers: @headers
    assert_response :success
    assert is_markdown?
    assert_includes response.body, "Automation Templates"
    assert_includes response.body, "Respond to @ Mentions"
  end

  # === Create Tests ===

  test "parent can create automation for ai_agent" do
    assert_difference "AutomationRule.unscoped.count" do
      post "/ai-agents/#{@ai_agent.handle}/automations/new/actions/create_automation_rule",
           params: { yaml_source: valid_yaml }.to_json,
           headers: @headers
    end

    assert_response :success
    assert is_markdown?
    assert_includes response.body, "created successfully"

    rule = AutomationRule.unscoped.order(created_at: :desc).first
    assert_equal @ai_agent.id, rule.ai_agent_id
    assert_equal @user, rule.created_by
    assert_equal "Test Automation", rule.name
    assert_equal "event", rule.trigger_type
    assert_equal "note.created", rule.event_type
    assert_equal "self", rule.mention_filter
  end

  test "create requires yaml_source" do
    assert_no_difference "AutomationRule.unscoped.count" do
      post "/ai-agents/#{@ai_agent.handle}/automations/new/actions/create_automation_rule",
           params: {}.to_json,
           headers: @headers
    end

    assert_response :unprocessable_entity
    assert_includes response.body, "YAML configuration is required"
  end

  test "create validates yaml" do
    invalid_yaml = <<~YAML
      name: "Missing trigger"
      description: "This is invalid"
    YAML

    assert_no_difference "AutomationRule.unscoped.count" do
      post "/ai-agents/#{@ai_agent.handle}/automations/new/actions/create_automation_rule",
           params: { yaml_source: invalid_yaml }.to_json,
           headers: @headers
    end

    assert_response :unprocessable_entity
    assert_includes response.body, "trigger is required"
  end

  # === Show Page Tests ===

  test "parent can view automation" do
    rule = create_automation_rule(
      name: "My Automation",
      description: "Test description",
      trigger_config: { "event_type" => "note.created", "mention_filter" => "self" },
    )

    get "/ai-agents/#{@ai_agent.handle}/automations/#{rule.truncated_id}", headers: @headers
    assert_response :success
    assert is_markdown?
    assert_includes response.body, "My Automation"
    assert_includes response.body, "note.created"
    assert_includes response.body, "self"
  end

  # === Edit Page Tests ===

  test "parent can view edit page" do
    rule = create_automation_rule(name: "Editable Rule")

    get "/ai-agents/#{@ai_agent.handle}/automations/#{rule.truncated_id}/edit", headers: @headers
    assert_response :success
    assert is_markdown?
    assert_includes response.body, "Edit"
    assert_includes response.body, rule.yaml_source
  end

  # === Update Tests ===

  test "parent can update automation" do
    rule = create_automation_rule(name: "Original Name")

    updated_yaml = <<~YAML
      name: "Updated Name"
      description: "Updated description"

      trigger:
        type: event
        event_type: comment.created
        mention_filter: self

      task: |
        Updated task prompt.

      max_steps: 30
    YAML

    post "/ai-agents/#{@ai_agent.handle}/automations/#{rule.truncated_id}/actions/update_automation_rule",
         params: { yaml_source: updated_yaml }.to_json,
         headers: @headers

    assert_response :success
    assert_includes response.body, "updated successfully"

    rule.reload
    assert_equal "Updated Name", rule.name
    assert_equal "comment.created", rule.event_type
    assert_equal 30, rule.max_steps
  end

  # === Delete Tests ===

  test "parent can delete automation" do
    rule = create_automation_rule(name: "To Delete")

    assert_difference "AutomationRule.unscoped.count", -1 do
      post "/ai-agents/#{@ai_agent.handle}/automations/#{rule.truncated_id}/actions/delete_automation_rule",
           headers: @headers
    end

    assert_response :success
    assert_includes response.body, "deleted"
  end

  # === Toggle Tests ===

  test "parent can toggle automation enabled state" do
    rule = create_automation_rule(name: "Toggle Test", enabled: true)

    post "/ai-agents/#{@ai_agent.handle}/automations/#{rule.truncated_id}/actions/toggle_automation_rule",
         headers: @headers

    assert_response :success
    assert_includes response.body, "disabled"
    rule.reload
    assert_not rule.enabled?

    post "/ai-agents/#{@ai_agent.handle}/automations/#{rule.truncated_id}/actions/toggle_automation_rule",
         headers: @headers

    assert_response :success
    assert_includes response.body, "enabled"
    rule.reload
    assert rule.enabled?
  end

  # === Runs Page Tests ===

  test "parent can view automation run history" do
    rule = create_automation_rule(name: "Run History Test")

    # Create a run (also unscoped)
    AutomationRuleRun.unscoped.create!(
      tenant: @tenant,
      automation_rule: rule,
      trigger_source: "event",
      status: "completed",
    )

    get "/ai-agents/#{@ai_agent.handle}/automations/#{rule.truncated_id}/runs", headers: @headers
    assert_response :success
    assert is_markdown?
    assert_includes response.body, "Run History"
    assert_includes response.body, "completed"
  end

  # === Authorization Tests ===

  test "non-parent cannot view ai_agent automations" do
    other_user = create_user
    @tenant.add_user!(other_user)
    mark_activated!(other_user)

    other_token = ApiToken.create!(
      tenant: @tenant,
      user: other_user,
      scopes: ApiToken.valid_scopes,
    )

    other_headers = {
      "Authorization" => "Bearer #{other_token.plaintext_token}",
      "Accept" => "text/markdown",
      "Content-Type" => "application/json",
    }

    get "/ai-agents/#{@ai_agent.handle}/automations", headers: other_headers
    assert_response :forbidden
    assert_includes response.body, "don't have permission"
  end

  test "non-parent cannot create automation for ai_agent" do
    other_user = create_user
    @tenant.add_user!(other_user)
    mark_activated!(other_user)

    other_token = ApiToken.create!(
      tenant: @tenant,
      user: other_user,
      scopes: ApiToken.valid_scopes,
    )

    other_headers = {
      "Authorization" => "Bearer #{other_token.plaintext_token}",
      "Accept" => "text/markdown",
      "Content-Type" => "application/json",
    }

    assert_no_difference "AutomationRule.unscoped.count" do
      post "/ai-agents/#{@ai_agent.handle}/automations/new/actions/create_automation_rule",
           params: { yaml_source: valid_yaml }.to_json,
           headers: other_headers
    end

    assert_response :forbidden
  end

  test "non-parent cannot delete automation" do
    other_user = create_user
    @tenant.add_user!(other_user)
    mark_activated!(other_user)

    other_token = ApiToken.create!(
      tenant: @tenant,
      user: other_user,
      scopes: ApiToken.valid_scopes,
    )

    other_headers = {
      "Authorization" => "Bearer #{other_token.plaintext_token}",
      "Accept" => "text/markdown",
      "Content-Type" => "application/json",
    }

    rule = create_automation_rule(name: "Protected Rule")

    assert_no_difference "AutomationRule.unscoped.count" do
      post "/ai-agents/#{@ai_agent.handle}/automations/#{rule.truncated_id}/actions/delete_automation_rule",
           headers: other_headers
    end

    assert_response :forbidden
  end

  # === Principal-collective authorization (persona rules) ===
  #
  # Persona agents are collective-principaled: their parent is the
  # collective's identity user, so no human passes the parent gate. The
  # humans who answer for the collective — its active admins and automators
  # (can_manage_automations?) — manage persona rules instead. Human-parented
  # agents stay parent-only regardless of collective membership.

  def create_persona_collective(roles_for_manager: ["admin"])
    manager = create_user(email: "rule-mgr-#{SecureRandom.hex(4)}@example.com", name: "Rule Manager")
    @tenant.add_user!(manager)
    collective = create_collective(
      tenant: @tenant, created_by: manager,
      name: "Persona Rules Collective", handle: "persona-rules-#{SecureRandom.hex(4)}"
    )
    collective.add_user!(manager, roles: roles_for_manager)
    persona = PersonaSeeder.ensure_for(collective, Personas::MELODY)
    PersonaActivator.seed_default_automations!(persona, @tenant.id)
    [collective, persona, manager]
  end

  def persona_rule(persona)
    AutomationRule.tenant_scoped_only(@tenant.id).where(ai_agent_id: persona.id).first
  end

  def persona_tenant_handle(persona)
    persona.tenant_users.find_by(tenant: @tenant).handle
  end

  test "collective admin can view and toggle a persona's automation rules" do
    _collective, persona, admin = create_persona_collective
    rule = persona_rule(persona)
    handle = persona_tenant_handle(persona)

    sign_in_as(admin, tenant: @tenant)
    get "/ai-agents/#{handle}/automations"
    assert_response :success

    get "/ai-agents/#{handle}/automations/#{rule.truncated_id}"
    assert_response :success

    get "/ai-agents/#{handle}/automations/#{rule.truncated_id}/runs"
    assert_response :success

    post "/ai-agents/#{handle}/automations/#{rule.truncated_id}/actions/toggle_automation_rule"
    assert_response :redirect, "toggle should succeed: #{response.status} #{response.body.truncate(200)}"
    assert_not rule.reload.enabled?
  end

  test "collective automator can view and toggle a persona's automation rules" do
    _collective, persona, automator = create_persona_collective(roles_for_manager: ["automator"])
    rule = persona_rule(persona)
    handle = persona_tenant_handle(persona)

    sign_in_as(automator, tenant: @tenant)
    get "/ai-agents/#{handle}/automations"
    assert_response :success

    post "/ai-agents/#{handle}/automations/#{rule.truncated_id}/actions/toggle_automation_rule"
    assert_not rule.reload.enabled?
  end

  test "plain member cannot manage a persona's automation rules" do
    collective, persona, _manager = create_persona_collective
    member = create_user(email: "plain-#{SecureRandom.hex(4)}@example.com", name: "Plain Member")
    @tenant.add_user!(member)
    collective.add_user!(member)
    rule = persona_rule(persona)
    handle = persona_tenant_handle(persona)

    sign_in_as(member, tenant: @tenant)
    get "/ai-agents/#{handle}/automations", headers: { "Accept" => "text/markdown" }
    assert_response :forbidden

    post "/ai-agents/#{handle}/automations/#{rule.truncated_id}/actions/toggle_automation_rule",
         headers: { "Accept" => "text/markdown" }
    assert_response :forbidden
    assert rule.reload.enabled?
  end

  test "admin whose membership is archived cannot manage a persona's automation rules" do
    collective, persona, admin = create_persona_collective
    collective.collective_members.find_by(user: admin).archive!
    handle = persona_tenant_handle(persona)

    sign_in_as(admin, tenant: @tenant)
    get "/ai-agents/#{handle}/automations", headers: { "Accept" => "text/markdown" }
    assert_response :forbidden
  end

  test "collective admin cannot manage a human-parented member agent's rules" do
    # @ai_agent is parented by @user and a member of @global_collective;
    # an admin of that collective is not the principal.
    @collective.add_user!(@ai_agent)
    collective_admin = create_user(email: "col-adm-#{SecureRandom.hex(4)}@example.com", name: "Collective Admin")
    @tenant.add_user!(collective_admin)
    @collective.add_user!(collective_admin, roles: ["admin"])
    create_automation_rule(name: "Parent Only Rule")

    sign_in_as(collective_admin, tenant: @tenant)
    get "/ai-agents/#{@ai_agent.handle}/automations", headers: { "Accept" => "text/markdown" }
    assert_response :forbidden
  end
end
