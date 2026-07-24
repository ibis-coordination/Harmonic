require "test_helper"

class AiAgentBridgeSetupsControllerTest < ActionDispatch::IntegrationTest
  def setup
    @tenant = @global_tenant
    @tenant.set_feature_flag!("external_ai_agents", true)
    @user = @global_user

    @other_human = create_user(name: "Other Human")
    @tenant.add_user!(@other_human)

    @agent = create_ai_agent(parent: @user, name: "Bridge Agent #{SecureRandom.hex(2)}", agent_configuration: { "mode" => "external" })
    @tenant.add_user!(@agent)
    @agent_handle = @agent.tenant_users.find_by(tenant: @tenant).handle

    @internal_agent = create_ai_agent(parent: @user, name: "Internal Agent #{SecureRandom.hex(2)}", agent_configuration: { "mode" => "internal" })
    @tenant.add_user!(@internal_agent)
    @internal_agent_handle = @internal_agent.tenant_users.find_by(tenant: @tenant).handle

    host! "#{@tenant.subdomain}.#{ENV.fetch("HOSTNAME", nil)}"
    sign_in_as(@user)
  end

  def connect_action_path(handle = @agent_handle)
    "/ai-agents/#{handle}/bridge-setup/actions/connect_harmonic_bridge"
  end

  def show_path(public_id, handle = @agent_handle)
    "/ai-agents/#{handle}/bridge-setup/#{public_id}"
  end

  def cancel_action_path(public_id, handle = @agent_handle)
    "#{show_path(public_id, handle)}/actions/cancel_harmonic_bridge_setup"
  end

  def make_setup
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    s = HarmonicBridgeSetup.create!(tenant: @tenant, ai_agent_user: @agent, created_by_user: @user)
    Tenant.clear_thread_scope
    s
  end

  # Each agent gets its own sprite: the command names the sprite after the
  # agent (lowercased — sprite names become DNS subdomains).
  def sprite_command_re(setup)
    Regexp.new(
      "npx @ibis-coordination/harmonic-bridge setup-sprite " \
      "--from \\S+/bridge-setups/#{Regexp.escape(setup.public_id)} " \
      "--sprite-name harmonic-#{Regexp.escape(@agent_handle.downcase)} " \
      "--harness claude-code"
    )
  end

  # === POST execute_connect_harmonic_bridge ===

  test "POST execute_connect_harmonic_bridge: mints a setup and redirects to its show page" do
    assert_difference -> { HarmonicBridgeSetup.tenant_scoped_only(@tenant.id).count } => 1 do
      post connect_action_path
    end
    setup = HarmonicBridgeSetup.tenant_scoped_only(@tenant.id).order(created_at: :desc).first
    assert_redirected_to show_path(setup.public_id)
    assert_equal @agent.id, setup.ai_agent_user_id
    assert_equal @user.id, setup.created_by_user_id
  end

  test "POST execute_connect_harmonic_bridge: returns the existing pending setup instead of minting a duplicate" do
    existing = make_setup
    assert_no_difference -> { HarmonicBridgeSetup.tenant_scoped_only(@tenant.id).count } do
      post connect_action_path
    end
    assert_redirected_to show_path(existing.public_id)
  end

  test "POST execute_connect_harmonic_bridge: rejects when the agent already has an active webhook" do
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    AutomationRule.create!(
      tenant: @tenant, ai_agent: @agent, created_by: @user,
      name: "existing-webhook", trigger_type: "event",
      trigger_config: { "event_types" => ["notifications.delivered"] },
      actions: { "webhook_url" => "https://existing.example/hook" },
      enabled: true
    )
    Tenant.clear_thread_scope

    assert_no_difference -> { HarmonicBridgeSetup.tenant_scoped_only(@tenant.id).count } do
      post connect_action_path
    end
    assert_response :redirect
    assert_match(/already has a notification webhook/i, flash[:error].to_s)
  end

  test "POST execute_connect_harmonic_bridge: 404 on internal AI agents (bridge is external-only)" do
    # set_target_agent enforces external_ai_agent? in the before_action chain.
    post connect_action_path(@internal_agent_handle)
    assert_response :not_found
  end

  # === GET show ===

  test "GET show: renders the public URL + the harmonic-bridge add command" do
    setup = make_setup
    get show_path(setup.public_id)
    assert_response :ok

    assert_match(%r{bridge-setups/#{Regexp.escape(setup.public_id)}}, response.body)
    assert_match(%r{harmonic-bridge add --from \S+/bridge-setups/#{Regexp.escape(setup.public_id)}}, response.body)
  end

  test "GET show: offers the Sprites path with the setup-sprite command" do
    setup = make_setup
    get show_path(setup.public_id)
    assert_response :ok

    add_command_re = %r{harmonic-bridge add --from \S+/bridge-setups/#{Regexp.escape(setup.public_id)}}

    assert_match(sprite_command_re(setup), response.body)
    assert_match(add_command_re, response.body)
    # Sprites is one option among others, listed after the generic host path.
    assert_operator response.body.index(add_command_re), :<, response.body.index(sprite_command_re(setup))
    assert_no_match(/recommended/i, response.body)
    # Sprites setup itself is Fly's product — link to their docs, don't inline them.
    assert_match(/docs\.sprites\.dev/, response.body)
    assert_no_match(/install\.sh/, response.body)
  end

  test "GET show: markdown view also offers the Sprites path" do
    setup = make_setup
    get show_path(setup.public_id), headers: { "Accept" => "text/markdown" }
    assert_response :ok
    assert_match(sprite_command_re(setup), response.body)
    assert_match(%r{harmonic-bridge add --from \S+/bridge-setups/#{Regexp.escape(setup.public_id)}}, response.body)
  end

  test "GET show: also serves text/markdown for the fetch_page flow" do
    setup = make_setup
    get show_path(setup.public_id), headers: { "Accept" => "text/markdown" }
    assert_response :ok
    assert_match %r{text/markdown}, response.content_type
    assert_match(/Connect harmonic-bridge for/, response.body)
    assert_match(%r{harmonic-bridge add --from \S+/bridge-setups/#{Regexp.escape(setup.public_id)}}, response.body)
    # The markdown view surfaces the cancel action as a canonical action link.
    assert_match(%r{/actions/cancel_harmonic_bridge_setup}, response.body)
  end

  test "GET show: 404 on unknown public_id" do
    get show_path("not-a-real-id")
    assert_response :not_found
  end

  test "GET show: 404 when the setup belongs to a different agent (cross-agent leakage)" do
    other_agent = create_ai_agent(parent: @user, name: "Other Agent", agent_configuration: { "mode" => "external" })
    @tenant.add_user!(other_agent)
    other_handle = other_agent.tenant_users.find_by(tenant: @tenant).handle

    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    other_setup = HarmonicBridgeSetup.create!(tenant: @tenant, ai_agent_user: other_agent, created_by_user: @user)
    Tenant.clear_thread_scope

    get show_path(other_setup.public_id) # this agent's handle, other agent's id
    assert_response :not_found

    get show_path(other_setup.public_id, other_handle) # right handle for the setup
    assert_response :ok
  end

  test "GET show: renders an expired state when the setup is past its expiry" do
    setup = make_setup
    setup.update_columns(expires_at: 1.minute.ago)
    get show_path(setup.public_id)
    assert_response :ok
    assert_match(/expired/i, response.body)
    assert_no_match(/harmonic-bridge add --from \S*#{Regexp.escape(setup.public_id)}/, response.body)
    assert_no_match(/setup-sprite --from \S*#{Regexp.escape(setup.public_id)}/, response.body)
  end

  # === POST execute_cancel_harmonic_bridge_setup ===

  test "POST execute_cancel: cancels an unredeemed setup and redirects to agent settings" do
    setup = make_setup
    post cancel_action_path(setup.public_id)
    assert_redirected_to "/ai-agents/#{@agent_handle}/settings"
    assert_nil HarmonicBridgeSetup.unscoped_for_system_job.find_by(id: setup.id)
  end

  test "POST execute_cancel: reverts a redeemed-but-not-finalized setup (destroys token + rule)" do
    setup = make_setup
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    setup.redeem!
    Tenant.clear_thread_scope
    token_id = setup.api_token.id
    rule_id = setup.automation_rule.id

    post cancel_action_path(setup.public_id)
    assert_redirected_to "/ai-agents/#{@agent_handle}/settings"
    assert_nil ApiToken.unscoped_for_system_job.find_by(id: token_id)
    assert_nil AutomationRule.unscoped_for_system_job.find_by(id: rule_id)
    assert_nil HarmonicBridgeSetup.unscoped_for_system_job.find_by(id: setup.id)
  end

  test "POST execute_cancel: 404 when setup belongs to a different agent" do
    other_agent = create_ai_agent(parent: @user, name: "Other Agent", agent_configuration: { "mode" => "external" })
    @tenant.add_user!(other_agent)
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    other_setup = HarmonicBridgeSetup.create!(tenant: @tenant, ai_agent_user: other_agent, created_by_user: @user)
    Tenant.clear_thread_scope

    post cancel_action_path(other_setup.public_id) # wrong handle for the setup
    assert_response :not_found
    assert_not_nil HarmonicBridgeSetup.unscoped_for_system_job.find_by(id: other_setup.id)
  end

  # === Authorization (parent-only humans, AI agents always blocked,
  #     no anonymous access). The four gates:
  #     1. require_login (controller before_action) — anon → /login
  #     2. set_target_agent (controller before_action) — internal agent → 404
  #     3. authorize_target_agent (controller before_action) — non-parent → /
  #     4. ActionCapabilityCheck (auto-included via ApplicationController) —
  #        AI agent / capability-restricted → 403 because both action names
  #        are in AI_AGENT_ALWAYS_BLOCKED

  test "GATE 1 — POST connect: anonymous request redirects to login" do
    reset!
    host! "#{@tenant.subdomain}.#{ENV.fetch("HOSTNAME", nil)}"
    post connect_action_path
    assert_response :redirect
    assert_match %r{/login}, response.location.to_s
  end

  test "GATE 1 — POST cancel: anonymous request redirects to login" do
    setup = make_setup
    reset!
    host! "#{@tenant.subdomain}.#{ENV.fetch("HOSTNAME", nil)}"
    post cancel_action_path(setup.public_id)
    assert_response :redirect
    assert_match %r{/login}, response.location.to_s
    assert_not_nil HarmonicBridgeSetup.unscoped_for_system_job.find_by(id: setup.id)
  end

  test "GATE 3 — POST connect: non-parent human is denied by the execute-time authorization gate" do
    sign_in_as(@other_human)
    post connect_action_path
    # The execute-time gate denies first: a non-parent human cannot represent the
    # agent (HUMAN_SELF_OR_REPRESENTATIVE), so it 403s before the controller's
    # authorize_parent redirect.
    assert_response :forbidden
  end

  test "GATE 3 — POST cancel: non-parent human is denied by the execute-time authorization gate" do
    setup = make_setup
    sign_in_as(@other_human)
    post cancel_action_path(setup.public_id)
    assert_response :forbidden
    assert_not_nil HarmonicBridgeSetup.unscoped_for_system_job.find_by(id: setup.id)
  end

  test "GATE 3 — GET new: non-parent human is blocked at authorize_target_agent" do
    sign_in_as(@other_human)
    get "/ai-agents/#{@agent_handle}/bridge-setup"
    assert_response :redirect
    assert_match(/permission/i, flash[:alert].to_s)
  end

  test "GATE 3 — GET show: non-parent human is blocked at authorize_target_agent" do
    setup = make_setup
    sign_in_as(@other_human)
    get show_path(setup.public_id)
    assert_response :redirect
    assert_match(/permission/i, flash[:alert].to_s)
  end

  test "GATE 3 — GET actions_index_new: non-parent human is blocked at authorize_target_agent" do
    sign_in_as(@other_human)
    get "/ai-agents/#{@agent_handle}/bridge-setup/actions"
    assert_response :redirect
    assert_match(/permission/i, flash[:alert].to_s)
  end

  test "GATE 3 — GET describe_connect_harmonic_bridge: non-parent human is blocked" do
    sign_in_as(@other_human)
    get "/ai-agents/#{@agent_handle}/bridge-setup/actions/connect_harmonic_bridge"
    assert_response :redirect
    assert_match(/permission/i, flash[:alert].to_s)
  end

  test "GATE 4 — both bridge actions are listed in AI_AGENT_ALWAYS_BLOCKED" do
    assert_includes CapabilityCheck::AI_AGENT_ALWAYS_BLOCKED, "connect_harmonic_bridge"
    assert_includes CapabilityCheck::AI_AGENT_ALWAYS_BLOCKED, "cancel_harmonic_bridge_setup"
  end

  test "GATE 4 — CapabilityCheck denies an AI agent for both bridge actions" do
    # End-to-end check that the AI_AGENT_ALWAYS_BLOCKED list actually
    # routes through to a deny decision. If a future refactor changes the
    # restriction predicate or the deny path, this catches it.
    assert_not CapabilityCheck.allowed?(@agent, "connect_harmonic_bridge")
    assert_not CapabilityCheck.allowed?(@agent, "cancel_harmonic_bridge_setup")
  end
end
