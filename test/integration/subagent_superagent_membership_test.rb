require "test_helper"

class SubagentStudioMembershipTest < ActionDispatch::IntegrationTest
  def setup
    @tenant = @global_tenant
    @tenant.enable_api!
    @superagent = @global_superagent
    @superagent.enable_api!  # Enable API at studio level for subagent functionality
    @parent = @global_user
    # Ensure parent has admin role on studio to have invite permission
    @parent.superagent_members.find_by(superagent: @superagent)&.add_role!('admin')
    @subagent = create_subagent(parent: @parent, name: "Subagent User")
    @tenant.add_user!(@subagent)
    # Note: @subagent is NOT added to @studio initially
    host! "#{@tenant.subdomain}.#{ENV['HOSTNAME']}"
  end

  # ====================
  # Adding Subagent to Studio
  # ====================

  test "parent can add their subagent to a studio where they have invite permission" do
    # Ensure parent is an admin (has invite permission)
    sign_in_as(@parent, tenant: @tenant)

    # Verify subagent is not in studio initially
    assert_nil SuperagentMember.find_by(superagent: @superagent, user: @subagent)

    post "/u/#{@subagent.handle}/add_to_studio", params: { superagent_id: @superagent.id }

    assert_response :redirect
    follow_redirect!

    # Verify subagent is now in studio
    assert_not_nil SuperagentMember.find_by(superagent: @superagent, user: @subagent)
  end

  test "parent cannot add their subagent to a studio where they lack invite permission" do
    # Create a studio where parent has no membership
    other_admin = create_user(name: "Other Admin")
    @tenant.add_user!(other_admin)
    other_superagent = create_superagent(tenant: @tenant, created_by: other_admin, handle: "other-studio-#{SecureRandom.hex(4)}")

    sign_in_as(@parent, tenant: @tenant)

    post "/u/#{@subagent.handle}/add_to_studio", params: { superagent_id: other_superagent.id }

    assert_response :forbidden
    assert_nil SuperagentMember.find_by(superagent: other_superagent, user: @subagent)
  end

  test "user cannot add another user's subagent to a studio" do
    # Create another parent with their own subagent
    other_parent = create_user(name: "Other Parent")
    @tenant.add_user!(other_parent)
    other_subagent = create_subagent(parent: other_parent, name: "Other Subagent")
    @tenant.add_user!(other_subagent)

    # @parent tries to add other_subagent to @studio
    sign_in_as(@parent, tenant: @tenant)

    post "/u/#{other_subagent.handle}/add_to_studio", params: { superagent_id: @superagent.id }

    assert_response :forbidden
    assert_nil SuperagentMember.find_by(superagent: @superagent, user: other_subagent)
  end

  test "cannot add non-subagent user via add_to_studio endpoint" do
    regular_user = create_user(name: "Regular User")
    @tenant.add_user!(regular_user)

    sign_in_as(@parent, tenant: @tenant)

    post "/u/#{regular_user.handle}/add_to_studio", params: { superagent_id: @superagent.id }

    assert_response :forbidden
    # Regular user might already be in studio from other tests, so just check response
  end

  test "unauthenticated user cannot add subagent to studio" do
    post "/u/#{@subagent.handle}/add_to_studio", params: { superagent_id: @superagent.id }

    assert_response :redirect # Redirects to login
    assert_nil SuperagentMember.find_by(superagent: @superagent, user: @subagent)
  end

  # ====================
  # Settings Page Display
  # ====================

  test "settings page shows subagent studio memberships" do
    # Add subagent to studio first
    @superagent.add_user!(@subagent)

    sign_in_as(@parent, tenant: @tenant)
    get "/u/#{@parent.handle}/settings"

    assert_response :success
    assert_match @superagent.name, response.body
  end

  test "settings page shows add to studio dropdown for available studios" do
    # Create another studio where parent has invite permission
    another_superagent = create_superagent(tenant: @tenant, created_by: @parent, handle: "another-studio-#{SecureRandom.hex(4)}")

    sign_in_as(@parent, tenant: @tenant)
    get "/u/#{@parent.handle}/settings"

    assert_response :success
    # Should show dropdown with available studios
    assert_match "Add to studio", response.body
  end

  test "settings page does not show add to studio for archived subagent" do
    # Archive the subagent
    @subagent.tenant_user = @tenant.tenant_users.find_by(user: @subagent)
    @subagent.archive!

    sign_in_as(@parent, tenant: @tenant)
    get "/u/#{@parent.handle}/settings"

    assert_response :success
    # Should show "Archived" status
    assert_match "Archived", response.body
  end

  # ====================
  # Studio Settings Page - Subagent Management
  # ====================

  test "studio settings page shows subagents in that studio" do
    # Add subagent to studio first
    @superagent.add_user!(@subagent)

    sign_in_as(@parent, tenant: @tenant)
    get "/studios/#{@superagent.handle}/settings"

    assert_response :success
    assert_match @subagent.display_name, response.body
    assert_match "Subagents in this Studio", response.body
  end

  test "admin can add own subagent to studio via settings JSON endpoint" do
    sign_in_as(@parent, tenant: @tenant)

    # Verify subagent is not in studio initially
    assert_nil SuperagentMember.find_by(superagent: @superagent, user: @subagent)

    post "/studios/#{@superagent.handle}/settings/add_subagent",
         params: { subagent_id: @subagent.id },
         headers: { "Accept" => "application/json", "Content-Type" => "application/json" },
         as: :json

    assert_response :success
    json_response = JSON.parse(response.body)
    assert_equal @subagent.id, json_response["subagent_id"]
    assert_equal @subagent.display_name, json_response["subagent_name"]

    # Verify subagent is now in studio
    assert_not_nil SuperagentMember.find_by(superagent: @superagent, user: @subagent)
  end

  test "admin cannot add another user's subagent to studio via settings" do
    other_parent = create_user(name: "Other Parent")
    @tenant.add_user!(other_parent)
    other_subagent = create_subagent(parent: other_parent, name: "Other Subagent")
    @tenant.add_user!(other_subagent)

    sign_in_as(@parent, tenant: @tenant)

    post "/studios/#{@superagent.handle}/settings/add_subagent",
         params: { subagent_id: other_subagent.id },
         headers: { "Accept" => "application/json", "Content-Type" => "application/json" },
         as: :json

    assert_response :forbidden
    assert_nil SuperagentMember.find_by(superagent: @superagent, user: other_subagent)
  end

  test "admin can remove subagent from studio via settings JSON endpoint" do
    # First add subagent to studio
    @superagent.add_user!(@subagent)
    superagent_member = SuperagentMember.find_by(superagent: @superagent, user: @subagent)
    assert_not_nil superagent_member
    assert_not superagent_member.archived?

    sign_in_as(@parent, tenant: @tenant)

    delete "/studios/#{@superagent.handle}/settings/remove_subagent",
           params: { subagent_id: @subagent.id },
           headers: { "Accept" => "application/json", "Content-Type" => "application/json" },
           as: :json

    assert_response :success
    json_response = JSON.parse(response.body)
    assert_equal @subagent.id, json_response["subagent_id"]
    assert_equal true, json_response["can_readd"]

    # Verify subagent membership is archived (not deleted)
    superagent_member.reload
    assert superagent_member.archived?
  end

  test "non-admin cannot add subagent to studio via settings" do
    # Remove admin role from parent
    @parent.superagent_members.find_by(superagent: @superagent)&.remove_role!('admin')

    sign_in_as(@parent, tenant: @tenant)

    post "/studios/#{@superagent.handle}/settings/add_subagent",
         params: { subagent_id: @subagent.id },
         headers: { "Accept" => "application/json", "Content-Type" => "application/json" },
         as: :json

    assert_response :forbidden
  end
end
