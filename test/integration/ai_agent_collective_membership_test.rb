require "test_helper"

class AiAgentCollectiveMembershipTest < ActionDispatch::IntegrationTest
  def setup
    @tenant = @global_tenant
    @tenant.enable_api!
    @collective = @global_collective
    @collective.enable_api!  # Enable API at collective level for ai_agent functionality
    @parent = @global_user
    # Ensure parent has admin role on collective to have invite permission
    @parent.collective_members.find_by(collective: @collective)&.add_role!('admin')
    @ai_agent = create_ai_agent(parent: @parent, name: "AiAgent User")
    @tenant.add_user!(@ai_agent)
    # Note: @ai_agent is NOT added to @collective initially
    host! "#{@tenant.subdomain}.#{ENV['HOSTNAME']}"
  end

  # ====================
  # Adding AiAgent to Collective
  # ====================

  test "parent can add their ai_agent to a collective where they have invite permission" do
    # Ensure parent is an admin (has invite permission)
    sign_in_as(@parent, tenant: @tenant)

    # Verify ai_agent is not in collective initially
    assert_nil CollectiveMember.find_by(collective: @collective, user: @ai_agent)

    post "/u/#{@ai_agent.handle}/add_to_collective", params: { collective_id: @collective.id }

    assert_response :redirect
    follow_redirect!

    # Verify ai_agent is now in collective
    assert_not_nil CollectiveMember.find_by(collective: @collective, user: @ai_agent)
  end

  test "parent cannot add their ai_agent to a collective where they lack invite permission" do
    # Create a collective where parent has no membership
    other_admin = create_user(name: "Other Admin")
    @tenant.add_user!(other_admin)
    other_collective = create_collective(tenant: @tenant, created_by: other_admin, handle: "other-collective-#{SecureRandom.hex(4)}")

    sign_in_as(@parent, tenant: @tenant)

    post "/u/#{@ai_agent.handle}/add_to_collective", params: { collective_id: other_collective.id }

    assert_response :forbidden
    assert_nil CollectiveMember.find_by(collective: other_collective, user: @ai_agent)
  end

  test "user cannot add another user's ai_agent to a collective" do
    # Create another parent with their own ai_agent
    other_parent = create_user(name: "Other Parent")
    @tenant.add_user!(other_parent)
    other_ai_agent = create_ai_agent(parent: other_parent, name: "Other AiAgent")
    @tenant.add_user!(other_ai_agent)

    # @parent tries to add other_ai_agent to @collective
    sign_in_as(@parent, tenant: @tenant)

    post "/u/#{other_ai_agent.handle}/add_to_collective", params: { collective_id: @collective.id }

    assert_response :forbidden
    assert_nil CollectiveMember.find_by(collective: @collective, user: other_ai_agent)
  end

  test "cannot add non-ai_agent user via add_to_collective endpoint" do
    regular_user = create_user(name: "Regular User")
    @tenant.add_user!(regular_user)

    sign_in_as(@parent, tenant: @tenant)

    post "/u/#{regular_user.handle}/add_to_collective", params: { collective_id: @collective.id }

    assert_response :forbidden
    # Regular user might already be in collective from other tests, so just check response
  end

  test "unauthenticated user cannot add ai_agent to collective" do
    post "/u/#{@ai_agent.handle}/add_to_collective", params: { collective_id: @collective.id }

    assert_response :redirect # Redirects to login
    assert_nil CollectiveMember.find_by(collective: @collective, user: @ai_agent)
  end

  # ====================
  # AI Agents Page Display
  # ====================

  test "ai_agents index page shows ai_agent collective memberships" do
    # Enable AI agents feature flag and add ai_agent to collective first
    @tenant.set_feature_flag!("internal_ai_agents", true)
    @tenant.set_feature_flag!("external_ai_agents", true)
    @collective.add_user!(@ai_agent)

    sign_in_as(@parent, tenant: @tenant)
    get "/ai-agents"

    assert_response :success
    assert_match @collective.name, response.body
  end

  test "ai_agents settings page shows available collectives to add agent to" do
    # Enable AI agents feature flag and create another collective where parent has invite permission
    @tenant.set_feature_flag!("internal_ai_agents", true)
    @tenant.set_feature_flag!("external_ai_agents", true)
    another_collective = create_collective(tenant: @tenant, created_by: @parent, handle: "another-collective-#{SecureRandom.hex(4)}")

    sign_in_as(@parent, tenant: @tenant)
    get "/ai-agents/#{@ai_agent.handle}/settings"

    assert_response :success
    # Should show available collectives section
    assert_match "Add to Collective", response.body
  end

  test "ai_agents index page shows archived badge for archived ai_agent" do
    # Enable AI agents feature flag and archive the ai_agent
    @tenant.set_feature_flag!("internal_ai_agents", true)
    @tenant.set_feature_flag!("external_ai_agents", true)
    @ai_agent.tenant_user = @tenant.tenant_users.find_by(user: @ai_agent)
    @ai_agent.archive!

    sign_in_as(@parent, tenant: @tenant)
    get "/ai-agents"

    assert_response :success
    # Should show "Archived" status
    assert_match "Archived", response.body
  end

  # ====================
  # Members Page - AiAgent Membership Ops
  # ====================

  test "members page shows ai_agent members" do
    # Add ai_agent to collective first
    @collective.add_user!(@ai_agent)

    sign_in_as(@parent, tenant: @tenant)
    get "/collectives/#{@collective.handle}/members"

    assert_response :success
    assert_match @ai_agent.display_name, response.body
  end

  test "parent can add own ai_agent via members JSON endpoint" do
    sign_in_as(@parent, tenant: @tenant)

    # Verify ai_agent is not in collective initially
    assert_nil CollectiveMember.find_by(collective: @collective, user: @ai_agent)

    post "/collectives/#{@collective.handle}/members/add_ai_agent",
         params: { ai_agent_id: @ai_agent.id },
         headers: { "Accept" => "application/json", "Content-Type" => "application/json" },
         as: :json

    assert_response :success
    json_response = JSON.parse(response.body)
    assert_equal @ai_agent.id, json_response["ai_agent_id"]
    assert_equal @ai_agent.display_name, json_response["ai_agent_name"]

    # Verify ai_agent is now in collective
    assert_not_nil CollectiveMember.find_by(collective: @collective, user: @ai_agent)
  end

  test "cannot add another user's ai_agent via members endpoint" do
    other_parent = create_user(name: "Other Parent")
    @tenant.add_user!(other_parent)
    other_ai_agent = create_ai_agent(parent: other_parent, name: "Other AiAgent")
    @tenant.add_user!(other_ai_agent)

    sign_in_as(@parent, tenant: @tenant)

    post "/collectives/#{@collective.handle}/members/add_ai_agent",
         params: { ai_agent_id: other_ai_agent.id },
         headers: { "Accept" => "application/json", "Content-Type" => "application/json" },
         as: :json

    assert_response :forbidden
    assert_nil CollectiveMember.find_by(collective: @collective, user: other_ai_agent)
  end

  test "parent can remove own ai_agent via the members remove_member action" do
    # First add ai_agent to collective
    @collective.add_user!(@ai_agent)
    collective_member = CollectiveMember.find_by(collective: @collective, user: @ai_agent)
    assert_not_nil collective_member
    assert_not collective_member.archived?

    sign_in_as(@parent, tenant: @tenant)

    agent_handle = @ai_agent.tenant_users.find_by(tenant_id: @tenant.id).handle
    post "/collectives/#{@collective.handle}/members/actions/remove_member",
         params: { user_handle: agent_handle }.to_json,
         headers: { "Accept" => "text/markdown", "Content-Type" => "application/json" }

    assert_response :success

    # Verify ai_agent membership is archived (not deleted)
    collective_member.reload
    assert collective_member.archived?
  end

  test "a member without invite permission cannot add their ai_agent" do
    # Remove admin role from parent; invitations stay admin-only by default
    @parent.collective_members.find_by(collective: @collective)&.remove_role!('admin')

    sign_in_as(@parent, tenant: @tenant)

    post "/collectives/#{@collective.handle}/members/add_ai_agent",
         params: { ai_agent_id: @ai_agent.id },
         headers: { "Accept" => "application/json", "Content-Type" => "application/json" },
         as: :json

    assert_response :forbidden
  end
end
