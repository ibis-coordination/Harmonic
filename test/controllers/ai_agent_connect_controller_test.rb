# frozen_string_literal: true

require "test_helper"

class AiAgentConnectControllerTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = @global_tenant
    @collective = @global_collective
    @user = @global_user
    host! "#{@tenant.subdomain}.#{ENV.fetch("HOSTNAME", nil)}"

    @tenant.set_feature_flag!("external_ai_agents", true)

    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)

    @ai_agent = create_ai_agent(
      parent: @user,
      name: "Connect Test Agent",
      agent_configuration: { "mode" => "external" }
    )
    @tenant.add_user!(@ai_agent)
    @collective.add_user!(@ai_agent)
    @ai_agent_handle = @ai_agent.tenant_users.find_by(tenant: @tenant).handle

    Collective.clear_thread_scope
    Tenant.clear_thread_scope
  end

  def sign_in_and_reverify(user, harness: "cursor")
    sign_in_with_reverification(
      user,
      tenant: @tenant,
      path: "/ai-agents/#{@ai_agent_handle}/connect/#{harness}",
      method: :post
    )
  end

  test "human principal can mint a Cursor connect token" do
    sign_in_and_reverify(@user)
    assert_difference -> { @ai_agent.api_tokens.count } => 1 do
      post "/ai-agents/#{@ai_agent_handle}/connect/cursor"
    end
    assert_response :success
    token = @ai_agent.api_tokens.order(created_at: :desc).first
    assert_equal "Cursor", token.client_name
    assert token.mcp_only?
    assert_not token.internal?
  end

  test "human principal can mint a Claude Code connect token" do
    sign_in_and_reverify(@user, harness: "claude-code")
    post "/ai-agents/#{@ai_agent_handle}/connect/claude-code"
    assert_response :success
    token = @ai_agent.api_tokens.order(created_at: :desc).first
    assert_equal "Claude Code", token.client_name
  end

  test "unknown harness returns 422" do
    sign_in_and_reverify(@user)
    assert_no_difference -> { @ai_agent.api_tokens.count } do
      post "/ai-agents/#{@ai_agent_handle}/connect/not-a-real-harness"
    end
    assert_response :unprocessable_entity
  end

  test "non-principal human gets 404 — agent lookup is scoped to current_user's owned agents" do
    _other_tenant, _other_collective, other_user = create_tenant_collective_user
    @tenant.add_user!(other_user)
    sign_in_with_reverification(
      other_user,
      tenant: @tenant,
      path: "/ai-agents/#{@ai_agent_handle}/connect/cursor",
      method: :post
    )
    assert_no_difference -> { @ai_agent.api_tokens.count } do
      post "/ai-agents/#{@ai_agent_handle}/connect/cursor"
    end
    # Established Harmonic pattern: agent lookup scoped to current_user.ai_agents
    # so non-owners get 404, not 403 (avoids leaking existence).
    assert_response :not_found
  end

  test "an agent handle that exists only in a different tenant returns 404 (cross-tenant defense)" do
    other_tenant, other_collective, other_user = create_tenant_collective_user
    Tenant.scope_thread_to_tenant(subdomain: other_tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: other_tenant.subdomain, handle: other_collective.handle)
    foreign_agent = create_ai_agent(parent: other_user, name: "Foreign Tenant Agent")
    other_tenant.add_user!(foreign_agent)
    other_collective.add_user!(foreign_agent)
    foreign_handle = foreign_agent.tenant_users.find_by(tenant: other_tenant).handle
    Collective.clear_thread_scope
    Tenant.clear_thread_scope

    sign_in_with_reverification(
      @user,
      tenant: @tenant,
      path: "/ai-agents/#{foreign_handle}/connect/cursor",
      method: :post
    )
    assert_no_difference -> { foreign_agent.api_tokens.count } do
      post "/ai-agents/#{foreign_handle}/connect/cursor"
    end
    assert_response :not_found
  end

  test "unauthenticated request redirects to login" do
    post "/ai-agents/#{@ai_agent_handle}/connect/cursor"
    assert_response :redirect
    assert_match %r{/login}, response.location
  end

  test "signed-in but not reverified gets redirected to /reverify and no token is minted" do
    sign_in_as(@user, tenant: @tenant)
    assert_no_difference -> { @ai_agent.api_tokens.count } do
      post "/ai-agents/#{@ai_agent_handle}/connect/cursor"
    end
    assert_response :redirect
    assert_match %r{/reverify}, response.location
  end

  test "internal AI agent cannot be connected (mirrors ApiTokensController guard)" do
    internal_agent = create_ai_agent(
      parent: @user,
      name: "Internal Test Agent",
      agent_configuration: { "mode" => "internal" }
    )
    @tenant.add_user!(internal_agent)
    @collective.add_user!(internal_agent)
    internal_handle = internal_agent.tenant_users.find_by(tenant: @tenant).handle
    assert internal_agent.internal_ai_agent?

    sign_in_with_reverification(
      @user,
      tenant: @tenant,
      path: "/ai-agents/#{internal_handle}/connect/cursor",
      method: :post
    )
    assert_no_difference -> { internal_agent.api_tokens.count } do
      post "/ai-agents/#{internal_handle}/connect/cursor"
    end
    assert_response :forbidden
  end

  test "unknown agent returns 404" do
    sign_in_with_reverification(
      @user,
      tenant: @tenant,
      path: "/ai-agents/nonexistent-handle/connect/cursor",
      method: :post
    )
    post "/ai-agents/nonexistent-handle/connect/cursor"
    assert_response :not_found
  end

  test "agent's own user cannot connect itself" do
    # Only the human principal should be able to mint connect tokens; the
    # agent itself doesn't have session auth, but block defensively if it did.
    sign_in_as(@ai_agent, tenant: @tenant)
    post "/ai-agents/#{@ai_agent_handle}/connect/cursor"
    # The agent gets redirected by session-auth requirements before reaching
    # the controller; this just confirms no token is minted.
    assert_no_difference -> { @ai_agent.api_tokens.count } do
      post "/ai-agents/#{@ai_agent_handle}/connect/cursor"
    end
  end

  test "agent with pending billing setup is blocked" do
    @ai_agent.update!(pending_billing_setup: true)
    sign_in_and_reverify(@user)
    assert_no_difference -> { @ai_agent.api_tokens.count } do
      post "/ai-agents/#{@ai_agent_handle}/connect/cursor"
    end
    assert_response :redirect
    assert_match %r{/billing}, response.location
  end

  test "archived agent is blocked" do
    @ai_agent.tenant_users.find_by(tenant: @tenant).update!(archived_at: Time.current)
    sign_in_and_reverify(@user)
    assert_no_difference -> { @ai_agent.api_tokens.count } do
      post "/ai-agents/#{@ai_agent_handle}/connect/cursor"
    end
    assert_response :redirect
  end

  test "hitting the token cap returns a friendly error, not 500" do
    sign_in_and_reverify(@user)
    # Fill the @user's quota so the next mint trips the cap. (Cap is per-user;
    # the @ai_agent's tokens count toward its own quota, so we fill that one.)
    ApiToken::MAX_ACTIVE_TOKENS_PER_USER.times do |i|
      ApiToken.create!(tenant: @tenant, user: @ai_agent, name: "Filler #{i}", scopes: ["read:all"])
    end
    assert_no_difference -> { @ai_agent.api_tokens.count } do
      post "/ai-agents/#{@ai_agent_handle}/connect/cursor"
    end
    assert_not_equal 500, response.status
    assert_response :redirect
  end
end
