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
    upgrade_collective_to_paid!(workspace, owner: @user)

    sign_in_as(@user, tenant: @tenant)
    post "/u/#{@user.handle}/settings/workspace_trio",
      params: { feature_trio: "true" },
      headers: { "HTTP_REFERER" => "http://#{@tenant.subdomain}.#{ENV['HOSTNAME']}/u/#{@user.handle}/settings" }

    workspace.reload
    assert_not_nil workspace.trio_user_id, "expected trio to be activated in workspace"
    assert AutomationRule.where(ai_agent_id: workspace.trio_user_id).exists?
  end

  # Self-hosted (non-billing) tenants have no tier model. A free-tier
  # workspace on such a tenant must still allow trio enablement — the
  # controller gate should use tier_unlocks_paid_features?, not paid_tier?.
  test "workspace owner can enable Trio on non-billing tenant without upgrading" do
    @tenant.enable_feature_flag!("trio")
    workspace = T.must(@user.private_workspace)
    workspace.set_feature_flag!("trio", false)
    # tier stays at free; no stripe_billing flag on the tenant

    sign_in_as(@user, tenant: @tenant)
    post "/u/#{@user.handle}/settings/workspace_trio",
      params: { feature_trio: "true" },
      headers: { "HTTP_REFERER" => "http://#{@tenant.subdomain}.#{ENV['HOSTNAME']}/u/#{@user.handle}/settings" }

    workspace.reload
    assert_not_nil workspace.trio_user_id, "self-hosted: trio should activate on free workspace"
  end

  test "workspace owner can disable Trio in their private workspace" do
    @tenant.enable_feature_flag!("trio")
    workspace = T.must(@user.private_workspace)
    upgrade_collective_to_paid!(workspace, owner: @user)
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

  # === Workspace Trio paid-tier gate ===

  test "workspace owner is blocked from enabling Trio on a free workspace" do
    enable_stripe_billing_flag!(@tenant)
    @tenant.enable_feature_flag!("trio")
    workspace = T.must(@user.private_workspace)
    workspace.set_feature_flag!("trio", false)

    sign_in_as(@user, tenant: @tenant)
    post "/u/#{@user.handle}/settings/workspace_trio",
      params: { feature_trio: "true" },
      headers: { "HTTP_REFERER" => "http://#{@tenant.subdomain}.#{ENV['HOSTNAME']}/u/#{@user.handle}/settings" }

    workspace.reload
    assert_nil workspace.trio_user_id, "trio should not be activated on a free workspace"
    assert flash[:error].to_s.downcase.include?("paid")
  end

  test "workspace owner can enable Trio when workspace is on the paid tier" do
    enable_stripe_billing_flag!(@tenant)
    @tenant.enable_feature_flag!("trio")
    workspace = T.must(@user.private_workspace)
    workspace.set_feature_flag!("trio", false)
    upgrade_collective_to_paid!(workspace, owner: @user)

    sign_in_as(@user, tenant: @tenant)
    post "/u/#{@user.handle}/settings/workspace_trio",
      params: { feature_trio: "true" },
      headers: { "HTTP_REFERER" => "http://#{@tenant.subdomain}.#{ENV['HOSTNAME']}/u/#{@user.handle}/settings" }

    workspace.reload
    assert_not_nil workspace.trio_user_id, "trio should activate when workspace is paid"
  end

  test "workspace owner can always disable Trio (no paid-tier requirement on disable)" do
    enable_stripe_billing_flag!(@tenant)
    @tenant.enable_feature_flag!("trio")
    workspace = T.must(@user.private_workspace)
    upgrade_collective_to_paid!(workspace, owner: @user)
    workspace.set_feature_flag!("trio", true)
    TrioActivator.activate!(workspace)

    sign_in_as(@user, tenant: @tenant)
    post "/u/#{@user.handle}/settings/workspace_trio",
      params: { feature_trio: "false" },
      headers: { "HTTP_REFERER" => "http://#{@tenant.subdomain}.#{ENV['HOSTNAME']}/u/#{@user.handle}/settings" }

    workspace.reload
    assert_nil workspace.trio_user_id
  end

  private

  def enable_stripe_billing_flag!(tenant)
    FeatureFlagService.config["stripe_billing"] ||= {}
    FeatureFlagService.config["stripe_billing"]["app_enabled"] = true
    tenant.enable_feature_flag!("stripe_billing")
  end

  public

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

  # === Tabs on /u/:handle ===

  test "profile page renders a tab nav with Activity, Lists, and (when viewing other w/ commons) Common Collectives" do
    other = create_user(email: "other-tab-viewer@example.com", name: "Other Viewer")
    @tenant.add_user!(other)
    common = Collective.create!(
      tenant: @tenant, name: "Common", handle: "common-#{SecureRandom.hex(4)}",
      collective_type: "standard", created_by: @user, updated_by: @user
    )
    common.add_user!(@user)
    common.add_user!(other)

    sign_in_as(other, tenant: @tenant)
    get "/u/#{@user.handle}"
    assert_response :success
    assert_select "nav.pulse-profile-tabs"
    assert_select "nav.pulse-profile-tabs a", text: /Activity/
    assert_select "nav.pulse-profile-tabs a", text: /Lists/
    assert_select "nav.pulse-profile-tabs a", text: /Common Collectives/
  end

  test "profile page hides Common Collectives tab when viewing own profile" do
    sign_in_as(@user, tenant: @tenant)
    get "/u/#{@user.handle}"
    assert_response :success
    assert_select "nav.pulse-profile-tabs"
    assert_select "nav.pulse-profile-tabs a", text: /Common Collectives/, count: 0
  end

  test "profile page hides Common Collectives tab when no common collectives" do
    other = create_user(email: "no-common-viewer@example.com", name: "Other Viewer")
    @tenant.add_user!(other)
    sign_in_as(other, tenant: @tenant)
    get "/u/#{@user.handle}"
    assert_response :success
    assert_select "nav.pulse-profile-tabs a", text: /Common Collectives/, count: 0
  end

  test "profile page defaults to Activity tab" do
    sign_in_as(@user, tenant: @tenant)
    get "/u/#{@user.handle}"
    assert_response :success
    assert_select "nav.pulse-profile-tabs a[aria-current=page]", text: /Activity/
  end

  test "?tab=lists makes Lists the active tab and Activity feed isn't rendered" do
    sign_in_as(@user, tenant: @tenant)
    get "/u/#{@user.handle}?tab=lists"
    assert_response :success
    assert_select "nav.pulse-profile-tabs a[aria-current=page]", text: /Lists/
    assert_select ".pulse-feed", count: 0
  end

  test "blocked-either-way profile shows no tab nav" do
    other = create_user(email: "blocked-tab-viewer@example.com", name: "Other Viewer")
    @tenant.add_user!(other)
    UserBlock.create!(blocker: other, blocked: @user, tenant: @tenant)
    sign_in_as(other, tenant: @tenant)
    get "/u/#{@user.handle}"
    assert_response :success
    assert_select "nav.pulse-profile-tabs", count: 0
  end

  test "markdown profile renders all sections inline regardless of ?tab" do
    sign_in_as(@user, tenant: @tenant)
    get "/u/#{@user.handle}?tab=lists", headers: { "Accept" => "text/markdown" }
    assert_response :success
    # Markdown view ignores ?tab and renders all sections that have content.
    assert_no_match(/pulse-profile-tabs/, response.body)
  end

  test "profile page does not render a Social Proximity section (HTML)" do
    sign_in_as(@user, tenant: @tenant)
    get "/u/#{@user.handle}"
    assert_response :success
    assert_no_match(/Social Proximity/, response.body)
  end

  test "profile page does not render a Social Proximity section (markdown)" do
    sign_in_as(@user, tenant: @tenant)
    get "/u/#{@user.handle}", headers: { "Accept" => "text/markdown" }
    assert_response :success
    assert_no_match(/Social Proximity/, response.body)
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

  # === /u/<agent>/settings redirects to /ai-agents/<handle>/settings ===
  # AI agents have a single canonical settings surface; visits to the
  # user-settings URL for an agent redirect to the canonical page.

  test "GET /u/<agent>/settings redirects to /ai-agents/<handle>/settings for AI agents" do
    @tenant.enable_feature_flag!("internal_ai_agents")
    @tenant.enable_feature_flag!("external_ai_agents")
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    ai_agent = create_ai_agent(parent: @user, name: "Redirect Test Agent")
    @tenant.add_user!(ai_agent)
    handle = ai_agent.tenant_users.find_by(tenant: @tenant).handle
    Collective.clear_thread_scope
    Tenant.clear_thread_scope

    sign_in_as(@user, tenant: @tenant)
    get "/u/#{handle}/settings"
    assert_redirected_to "/ai-agents/#{handle}/settings"
  end

  test "GET /u/<agent>/settings.md redirects to /ai-agents/<handle>/settings.md for AI agents" do
    @tenant.enable_api!
    @tenant.enable_feature_flag!("internal_ai_agents")
    @tenant.enable_feature_flag!("external_ai_agents")
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    ai_agent = create_ai_agent(parent: @user, name: "Redirect MD Test Agent")
    @tenant.add_user!(ai_agent)
    handle = ai_agent.tenant_users.find_by(tenant: @tenant).handle
    Collective.clear_thread_scope
    Tenant.clear_thread_scope

    api_token = ApiToken.create!(
      user: @user,
      tenant: @tenant,
      name: "Redirect MD Test #{SecureRandom.hex(4)}",
      scopes: ApiToken.read_scopes,
    )
    get "/u/#{handle}/settings",
      headers: {
        "Accept" => "text/markdown",
        "Authorization" => "Bearer #{api_token.plaintext_token}",
      }
    assert_response :redirect
    assert_match %r{/ai-agents/#{handle}/settings}, response.headers["Location"]
  end

  test "GET /ai-agents/<handle>/settings includes the profile image upload" do
    @tenant.enable_feature_flag!("internal_ai_agents")
    @tenant.enable_feature_flag!("external_ai_agents")
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    ai_agent = create_ai_agent(parent: @user, name: "Profile Image Test Agent")
    @tenant.add_user!(ai_agent)
    handle = ai_agent.tenant_users.find_by(tenant: @tenant).handle
    Collective.clear_thread_scope
    Tenant.clear_thread_scope

    sign_in_as(@user, tenant: @tenant)
    get "/ai-agents/#{handle}/settings"
    assert_response :success
    assert_match(/Profile Image/i, response.body,
      "agent settings should include profile image upload — the only thing previously unique to /u/<agent>/settings")
  end

  test "POST /u/<agent>/settings/profile no longer mutates agent_configuration" do
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    ai_agent = create_ai_agent(parent: @user, name: "Profile POST Test Agent")
    ai_agent.update_columns(agent_configuration: { "mode" => "external", "capabilities" => ["create_note"] })
    @tenant.add_user!(ai_agent)
    handle = ai_agent.tenant_users.find_by(tenant: @tenant).handle
    Collective.clear_thread_scope
    Tenant.clear_thread_scope

    sign_in_as(@user, tenant: @tenant)
    post "/u/#{handle}/settings/profile", params: {
      name: "Updated Name",
      mode: "internal",
      capabilities: [""],
      identity_prompt: "ignored",
    }
    assert_response :redirect
    ai_agent.reload
    assert_equal "Updated Name", ai_agent.name
    assert_equal "external", ai_agent.agent_configuration["mode"]
    assert_equal ["create_note"], ai_agent.agent_configuration["capabilities"]
    assert_nil ai_agent.agent_configuration["identity_prompt"]
  end

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
