require "test_helper"

class UsersControllerTest < ActionDispatch::IntegrationTest
  def setup
    @tenant = @global_tenant
    @superagent = @global_superagent
    @user = @global_user
    host! "#{@tenant.subdomain}.#{ENV.fetch("HOSTNAME", nil)}"
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
    assert_includes response.body, "Has 2 ai_agents"
  end

  test "person user profile shows singular ai_agent when they have one" do
    ai_agent = create_ai_agent(parent: @user, name: "Only AiAgent")
    @tenant.add_user!(ai_agent)

    sign_in_as(@user, tenant: @tenant)
    get "/u/#{@user.handle}"
    assert_response :success
    assert_includes response.body, "Has 1 ai_agent"
    assert_not_includes response.body, "Has 1 ai_agents"
  end

  test "person user profile does not show ai_agent count when they have none" do
    sign_in_as(@user, tenant: @tenant)
    get "/u/#{@user.handle}"
    assert_response :success
    assert_not_includes response.body, "Has 0 ai_agent"
    # The profile section should not mention ai_agents when user has none
    # (Note: "AiAgents" appears in navigation menu but that's expected)
    assert_no_match(/Has \d+ ai_agent/, response.body)
  end

  test "ai_agent profile does not show ai_agent count" do
    ai_agent = create_ai_agent(parent: @user, name: "Test AiAgent")
    @tenant.add_user!(ai_agent)
    @superagent.add_user!(ai_agent)

    sign_in_as(@user, tenant: @tenant)
    get "/u/#{ai_agent.handle}"
    assert_response :success
    # AiAgent shows "ai_agent" badge and "Managed by" but not "Has N ai_agents"
    assert_includes response.body, "ai_agent"
    assert_not_includes response.body, "Has 0 ai_agent"
    assert_not_includes response.body, "Has 1 ai_agent"
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
    assert_includes response.body, "Has 2 ai_agents"
  end

  test "markdown person profile does not show ai_agent count when they have none" do
    sign_in_as(@user, tenant: @tenant)
    get "/u/#{@user.handle}", headers: { "Accept" => "text/markdown" }
    assert_response :success
    assert_not_includes response.body, "Has 0 ai_agent"
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
    # Should only show 1 ai_agent (the one in this tenant)
    assert_includes response.body, "Has 1 ai_agent"
    assert_not_includes response.body, "Has 2 ai_agents"
  end
end
