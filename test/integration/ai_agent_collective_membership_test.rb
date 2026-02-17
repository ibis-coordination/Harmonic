require "test_helper"

class AiAgentStudioMembershipTest < ActionDispatch::IntegrationTest
  def setup
    @tenant = @global_tenant
    @tenant.enable_api!
    @collective = @global_collective
    @collective.enable_api!  # Enable API at studio level for ai_agent functionality
    @parent = @global_user
    # Ensure parent has admin role on studio to have invite permission
    @parent.collective_members.find_by(collective: @collective)&.add_role!('admin')
    @ai_agent = create_ai_agent(parent: @parent, name: "AiAgent User")
    @tenant.add_user!(@ai_agent)
    # Note: @ai_agent is NOT added to @studio initially
    host! "#{@tenant.subdomain}.#{ENV['HOSTNAME']}"
  end

  # ====================
  # Adding AiAgent to Studio
  # ====================

  test "parent can add their ai_agent to a studio where they have invite permission" do
    # Ensure parent is an admin (has invite permission)
    sign_in_as(@parent, tenant: @tenant)

    # Verify ai_agent is not in studio initially
    assert_nil CollectiveMember.find_by(collective: @collective, user: @ai_agent)

    post "/u/#{@ai_agent.handle}/add_to_studio", params: { collective_id: @collective.id }

    assert_response :redirect
    follow_redirect!

    # Verify ai_agent is now in studio
    assert_not_nil CollectiveMember.find_by(collective: @collective, user: @ai_agent)
  end

  test "parent cannot add their ai_agent to a studio where they lack invite permission" do
    # Create a studio where parent has no membership
    other_admin = create_user(name: "Other Admin")
    @tenant.add_user!(other_admin)
    other_collective = create_collective(tenant: @tenant, created_by: other_admin, handle: "other-studio-#{SecureRandom.hex(4)}")

    sign_in_as(@parent, tenant: @tenant)

    post "/u/#{@ai_agent.handle}/add_to_studio", params: { collective_id: other_collective.id }

    assert_response :forbidden
    assert_nil CollectiveMember.find_by(collective: other_collective, user: @ai_agent)
  end

  test "user cannot add another user's ai_agent to a studio" do
    # Create another parent with their own ai_agent
    other_parent = create_user(name: "Other Parent")
    @tenant.add_user!(other_parent)
    other_ai_agent = create_ai_agent(parent: other_parent, name: "Other AiAgent")
    @tenant.add_user!(other_ai_agent)

    # @parent tries to add other_ai_agent to @studio
    sign_in_as(@parent, tenant: @tenant)

    post "/u/#{other_ai_agent.handle}/add_to_studio", params: { collective_id: @collective.id }

    assert_response :forbidden
    assert_nil CollectiveMember.find_by(collective: @collective, user: other_ai_agent)
  end

  test "cannot add non-ai_agent user via add_to_studio endpoint" do
    regular_user = create_user(name: "Regular User")
    @tenant.add_user!(regular_user)

    sign_in_as(@parent, tenant: @tenant)

    post "/u/#{regular_user.handle}/add_to_studio", params: { collective_id: @collective.id }

    assert_response :forbidden
    # Regular user might already be in studio from other tests, so just check response
  end

  test "unauthenticated user cannot add ai_agent to studio" do
    post "/u/#{@ai_agent.handle}/add_to_studio", params: { collective_id: @collective.id }

    assert_response :redirect # Redirects to login
    assert_nil CollectiveMember.find_by(collective: @collective, user: @ai_agent)
  end

  # ====================
  # AI Agents Page Display
  # ====================

  test "ai_agents index page shows ai_agent studio memberships" do
    # Enable AI agents feature flag and add ai_agent to studio first
    @tenant.set_feature_flag!("ai_agents", true)
    @collective.add_user!(@ai_agent)

    sign_in_as(@parent, tenant: @tenant)
    get "/ai-agents"

    assert_response :success
    assert_match @collective.name, response.body
  end

  test "ai_agents settings page shows available studios to add agent to" do
    # Enable AI agents feature flag and create another studio where parent has invite permission
    @tenant.set_feature_flag!("ai_agents", true)
    another_collective = create_collective(tenant: @tenant, created_by: @parent, handle: "another-studio-#{SecureRandom.hex(4)}")

    sign_in_as(@parent, tenant: @tenant)
    get "/ai-agents/#{@ai_agent.handle}/settings"

    assert_response :success
    # Should show available studios section
    assert_match "Add to Studio", response.body
  end

  test "ai_agents index page shows archived badge for archived ai_agent" do
    # Enable AI agents feature flag and archive the ai_agent
    @tenant.set_feature_flag!("ai_agents", true)
    @ai_agent.tenant_user = @tenant.tenant_users.find_by(user: @ai_agent)
    @ai_agent.archive!

    sign_in_as(@parent, tenant: @tenant)
    get "/ai-agents"

    assert_response :success
    # Should show "Archived" status
    assert_match "Archived", response.body
  end

  # ====================
  # Studio Settings Page - AiAgent Management
  # ====================

  test "studio settings page shows ai_agents in that studio" do
    # Add ai_agent to studio first
    @collective.add_user!(@ai_agent)

    sign_in_as(@parent, tenant: @tenant)
    get "/studios/#{@collective.handle}/settings"

    assert_response :success
    assert_match @ai_agent.display_name, response.body
    assert_match "AI Agents in this Studio", response.body
  end

  test "admin can add own ai_agent to studio via settings JSON endpoint" do
    sign_in_as(@parent, tenant: @tenant)

    # Verify ai_agent is not in studio initially
    assert_nil CollectiveMember.find_by(collective: @collective, user: @ai_agent)

    post "/studios/#{@collective.handle}/settings/add_ai_agent",
         params: { ai_agent_id: @ai_agent.id },
         headers: { "Accept" => "application/json", "Content-Type" => "application/json" },
         as: :json

    assert_response :success
    json_response = JSON.parse(response.body)
    assert_equal @ai_agent.id, json_response["ai_agent_id"]
    assert_equal @ai_agent.display_name, json_response["ai_agent_name"]

    # Verify ai_agent is now in studio
    assert_not_nil CollectiveMember.find_by(collective: @collective, user: @ai_agent)
  end

  test "admin cannot add another user's ai_agent to studio via settings" do
    other_parent = create_user(name: "Other Parent")
    @tenant.add_user!(other_parent)
    other_ai_agent = create_ai_agent(parent: other_parent, name: "Other AiAgent")
    @tenant.add_user!(other_ai_agent)

    sign_in_as(@parent, tenant: @tenant)

    post "/studios/#{@collective.handle}/settings/add_ai_agent",
         params: { ai_agent_id: other_ai_agent.id },
         headers: { "Accept" => "application/json", "Content-Type" => "application/json" },
         as: :json

    assert_response :forbidden
    assert_nil CollectiveMember.find_by(collective: @collective, user: other_ai_agent)
  end

  test "admin can remove ai_agent from studio via settings JSON endpoint" do
    # First add ai_agent to studio
    @collective.add_user!(@ai_agent)
    collective_member = CollectiveMember.find_by(collective: @collective, user: @ai_agent)
    assert_not_nil collective_member
    assert_not collective_member.archived?

    sign_in_as(@parent, tenant: @tenant)

    delete "/studios/#{@collective.handle}/settings/remove_ai_agent",
           params: { ai_agent_id: @ai_agent.id },
           headers: { "Accept" => "application/json", "Content-Type" => "application/json" },
           as: :json

    assert_response :success
    json_response = JSON.parse(response.body)
    assert_equal @ai_agent.id, json_response["ai_agent_id"]
    assert_equal true, json_response["can_readd"]

    # Verify ai_agent membership is archived (not deleted)
    collective_member.reload
    assert collective_member.archived?
  end

  test "non-admin cannot add ai_agent to studio via settings" do
    # Remove admin role from parent
    @parent.collective_members.find_by(collective: @collective)&.remove_role!('admin')

    sign_in_as(@parent, tenant: @tenant)

    post "/studios/#{@collective.handle}/settings/add_ai_agent",
         params: { ai_agent_id: @ai_agent.id },
         headers: { "Accept" => "application/json", "Content-Type" => "application/json" },
         as: :json

    assert_response :forbidden
  end
end
