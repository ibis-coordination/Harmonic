require "test_helper"

class UsersControllerTest < ActionDispatch::IntegrationTest
  def setup
    @tenant = @global_tenant
    @collective = @global_collective
    @user = @global_user
    host! "#{@tenant.subdomain}.#{ENV.fetch("HOSTNAME", nil)}"
  end

  # === Workspace Trio Settings View ===

  test "user settings page shows Workspace AI Assistant section when tenant has trio enabled" do
    @tenant.enable_feature_flag!("trio")
    sign_in_as(@user, tenant: @tenant)

    get "/u/#{@user.handle}/settings"
    assert_response :success
    assert_includes response.body, "Workspace AI Assistant"
    assert_includes response.body, "feature_trio"
  end

  test "user settings page hides Workspace AI Assistant section when tenant has trio disabled" do
    @tenant.disable_feature_flag!("trio")
    sign_in_as(@user, tenant: @tenant)

    get "/u/#{@user.handle}/settings"
    assert_response :success
    assert_not_includes response.body, "Workspace AI Assistant"
  end

  # === Workspace Trio Toggle ===

  test "workspace owner can enable Trio in their private workspace" do
    @tenant.enable_feature_flag!("trio")
    workspace = T.must(@user.private_workspace)
    workspace.set_feature_flag!("trio", false)

    sign_in_as(@user, tenant: @tenant)
    post "/u/#{@user.handle}/settings/workspace_trio",
      params: { feature_trio: "true" },
      headers: { "HTTP_REFERER" => "http://#{@tenant.subdomain}.#{ENV['HOSTNAME']}/u/#{@user.handle}/settings" }

    workspace.reload
    assert_not_nil workspace.trio_user_id, "expected trio to be activated in workspace"
    assert AutomationRule.where(ai_agent_id: workspace.trio_user_id).exists?
  end

  test "workspace owner can disable Trio in their private workspace" do
    @tenant.enable_feature_flag!("trio")
    workspace = T.must(@user.private_workspace)
    workspace.set_feature_flag!("trio", true)
    TrioActivator.activate!(workspace)
    trio_id = T.must(workspace.reload.trio_user_id)

    sign_in_as(@user, tenant: @tenant)
    post "/u/#{@user.handle}/settings/workspace_trio",
      params: { feature_trio: "false" },
      headers: { "HTTP_REFERER" => "http://#{@tenant.subdomain}.#{ENV['HOSTNAME']}/u/#{@user.handle}/settings" }

    workspace.reload
    assert_nil workspace.trio_user_id, "expected trio to be deactivated in workspace"
    assert AutomationRule.where(ai_agent_id: trio_id).none? { |r| r.enabled? }
  end

  test "non-owner cannot toggle Trio in someone else's workspace" do
    other_user = create_user(name: "Other User")
    @tenant.add_user!(other_user)
    @tenant.enable_feature_flag!("trio")

    sign_in_as(other_user, tenant: @tenant)
    post "/u/#{@user.handle}/settings/workspace_trio",
      params: { feature_trio: "true" },
      headers: { "HTTP_REFERER" => "http://#{@tenant.subdomain}.#{ENV['HOSTNAME']}/u/#{@user.handle}/settings" }

    assert_response :forbidden
    assert_nil T.must(@user.private_workspace).reload.trio_user_id
  end

  # === Profile Updates ===

  test "update_profile ignores system_role param" do
    # `system_role: "trio"` would grant the user system-agent privileges
    # (billing exemption, workspace membership exception, reserved handle).
    # update_profile does not accept this attribute.
    sign_in_as(@user, tenant: @tenant)
    refute @user.system?

    post "/u/#{@user.handle}/settings/profile",
      params: { name: "Renamed", system_role: "trio" }

    @user.reload
    assert_nil @user.system_role
    refute @user.system?
  end

  test "update_profile cannot rename a non-trio user's handle to 'trio'" do
    sign_in_as(@user, tenant: @tenant)
    original_handle = @user.tenant_user.handle

    # TenantUser's reserved-handle validation raises ActiveRecord::RecordInvalid
    # at the update! call site. What matters for security is that the handle
    # is not persisted as "trio".
    begin
      post "/u/#{@user.handle}/settings/profile", params: { new_handle: "trio" }
    rescue ActiveRecord::RecordInvalid
      # Expected — validation rejected the change.
    end

    @user.tenant_user.reload
    assert_equal original_handle, @user.tenant_user.handle
  end

  # === Show (GET /u/:handle) Tests ===

  test "can view user profile" do
    sign_in_as(@user, tenant: @tenant)
    get "/u/#{@user.handle}"
    assert_response :success
    assert_includes response.body, @user.display_name
  end

  test "can view user profile in markdown format" do
    sign_in_as(@user, tenant: @tenant)
    get "/u/#{@user.handle}", headers: { "Accept" => "text/markdown" }
    assert_response :success
    assert_includes response.body, "# User: #{@user.display_name}"
  end

  # === AiAgent Count Tests (HTML) ===

  test "person user profile shows ai_agent count when they have ai_agents" do
    ai_agent1 = create_ai_agent(parent: @user, name: "AiAgent One")
    ai_agent2 = create_ai_agent(parent: @user, name: "AiAgent Two")
    @tenant.add_user!(ai_agent1)
    @tenant.add_user!(ai_agent2)

    sign_in_as(@user, tenant: @tenant)
    get "/u/#{@user.handle}"
    assert_response :success
    assert_includes response.body, "Has 2 AI agents"
  end

  test "person user profile shows singular ai_agent when they have one" do
    ai_agent = create_ai_agent(parent: @user, name: "Only AiAgent")
    @tenant.add_user!(ai_agent)

    sign_in_as(@user, tenant: @tenant)
    get "/u/#{@user.handle}"
    assert_response :success
    assert_includes response.body, "Has 1 AI agent"
    assert_not_includes response.body, "Has 1 AI agents"
  end

  test "person user profile does not show ai_agent count when they have none" do
    sign_in_as(@user, tenant: @tenant)
    get "/u/#{@user.handle}"
    assert_response :success
    assert_not_includes response.body, "Has 0 AI agent"
    # The profile section should not mention AI agents when user has none
    assert_no_match(/Has \d+ AI agent/, response.body)
  end

  test "ai_agent profile does not show ai_agent count" do
    ai_agent = create_ai_agent(parent: @user, name: "Test AiAgent")
    @tenant.add_user!(ai_agent)
    @collective.add_user!(ai_agent)

    sign_in_as(@user, tenant: @tenant)
    get "/u/#{ai_agent.handle}"
    assert_response :success
    # AiAgent shows "AI agent" badge and "Managed by" but not "Has N AI agents"
    assert_includes response.body, "AI agent"
    assert_not_includes response.body, "Has 0 AI agent"
    assert_not_includes response.body, "Has 1 AI agent"
  end

  # === AiAgent Count Tests (Markdown) ===

  test "markdown person profile shows ai_agent count when they have ai_agents" do
    ai_agent1 = create_ai_agent(parent: @user, name: "AiAgent One")
    ai_agent2 = create_ai_agent(parent: @user, name: "AiAgent Two")
    @tenant.add_user!(ai_agent1)
    @tenant.add_user!(ai_agent2)

    sign_in_as(@user, tenant: @tenant)
    get "/u/#{@user.handle}", headers: { "Accept" => "text/markdown" }
    assert_response :success
    assert_includes response.body, "Has 2 AI agents"
  end

  test "markdown person profile does not show ai_agent count when they have none" do
    sign_in_as(@user, tenant: @tenant)
    get "/u/#{@user.handle}", headers: { "Accept" => "text/markdown" }
    assert_response :success
    assert_not_includes response.body, "Has 0 AI agent"
  end

  # === AiAgent Count Scoping Tests ===

  test "ai_agent count only includes ai_agents in current tenant" do
    # Create two ai_agents
    ai_agent1 = create_ai_agent(parent: @user, name: "AiAgent In Tenant")
    ai_agent2 = create_ai_agent(parent: @user, name: "AiAgent Not In Tenant")

    # Only add ai_agent1 to the current tenant
    @tenant.add_user!(ai_agent1)
    # ai_agent2 is not added to the tenant

    sign_in_as(@user, tenant: @tenant)
    get "/u/#{@user.handle}"
    assert_response :success
    # Should only show 1 AI agent (the one in this tenant)
    assert_includes response.body, "Has 1 AI agent"
    assert_not_includes response.body, "Has 2 AI agents"
  end
end
