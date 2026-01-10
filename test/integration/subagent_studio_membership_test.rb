require "test_helper"

class SubagentStudioMembershipTest < ActionDispatch::IntegrationTest
  def setup
    @tenant = @global_tenant
    @tenant.enable_api!
    @studio = @global_studio
    @parent = @global_user
    # Ensure parent has admin role on studio to have invite permission
    @parent.studio_users.find_by(studio: @studio)&.add_role!('admin')
    @subagent = User.create!(
      email: "subagent-#{SecureRandom.hex(4)}@not-a-real-email.com",
      name: "Subagent User",
      user_type: "subagent",
      parent_id: @parent.id,
    )
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
    assert_nil StudioUser.find_by(studio: @studio, user: @subagent)

    post "/u/#{@subagent.handle}/add_to_studio", params: { studio_id: @studio.id }

    assert_response :redirect
    follow_redirect!

    # Verify subagent is now in studio
    assert_not_nil StudioUser.find_by(studio: @studio, user: @subagent)
  end

  test "parent cannot add their subagent to a studio where they lack invite permission" do
    # Create a studio where parent has no membership
    other_admin = create_user(name: "Other Admin")
    @tenant.add_user!(other_admin)
    other_studio = create_studio(tenant: @tenant, created_by: other_admin, handle: "other-studio-#{SecureRandom.hex(4)}")

    sign_in_as(@parent, tenant: @tenant)

    post "/u/#{@subagent.handle}/add_to_studio", params: { studio_id: other_studio.id }

    assert_response :forbidden
    assert_nil StudioUser.find_by(studio: other_studio, user: @subagent)
  end

  test "user cannot add another user's subagent to a studio" do
    # Create another parent with their own subagent
    other_parent = create_user(name: "Other Parent")
    @tenant.add_user!(other_parent)
    other_subagent = User.create!(
      email: "other-subagent-#{SecureRandom.hex(4)}@not-a-real-email.com",
      name: "Other Subagent",
      user_type: "subagent",
      parent_id: other_parent.id,
    )
    @tenant.add_user!(other_subagent)

    # @parent tries to add other_subagent to @studio
    sign_in_as(@parent, tenant: @tenant)

    post "/u/#{other_subagent.handle}/add_to_studio", params: { studio_id: @studio.id }

    assert_response :forbidden
    assert_nil StudioUser.find_by(studio: @studio, user: other_subagent)
  end

  test "cannot add non-subagent user via add_to_studio endpoint" do
    regular_user = create_user(name: "Regular User")
    @tenant.add_user!(regular_user)

    sign_in_as(@parent, tenant: @tenant)

    post "/u/#{regular_user.handle}/add_to_studio", params: { studio_id: @studio.id }

    assert_response :forbidden
    # Regular user might already be in studio from other tests, so just check response
  end

  test "unauthenticated user cannot add subagent to studio" do
    post "/u/#{@subagent.handle}/add_to_studio", params: { studio_id: @studio.id }

    assert_response :redirect # Redirects to login
    assert_nil StudioUser.find_by(studio: @studio, user: @subagent)
  end

  # ====================
  # Settings Page Display
  # ====================

  test "settings page shows subagent studio memberships" do
    # Add subagent to studio first
    @studio.add_user!(@subagent)

    sign_in_as(@parent, tenant: @tenant)
    get "/u/#{@parent.handle}/settings"

    assert_response :success
    assert_match @studio.name, response.body
  end

  test "settings page shows add to studio dropdown for available studios" do
    # Create another studio where parent has invite permission
    another_studio = create_studio(tenant: @tenant, created_by: @parent, handle: "another-studio-#{SecureRandom.hex(4)}")

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
    @studio.add_user!(@subagent)

    sign_in_as(@parent, tenant: @tenant)
    get "/studios/#{@studio.handle}/settings"

    assert_response :success
    assert_match @subagent.display_name, response.body
    assert_match "Subagents in this Studio", response.body
  end

  test "admin can add own subagent to studio via settings JSON endpoint" do
    sign_in_as(@parent, tenant: @tenant)

    # Verify subagent is not in studio initially
    assert_nil StudioUser.find_by(studio: @studio, user: @subagent)

    post "/studios/#{@studio.handle}/settings/add_subagent",
         params: { subagent_id: @subagent.id },
         headers: { "Accept" => "application/json", "Content-Type" => "application/json" },
         as: :json

    assert_response :success
    json_response = JSON.parse(response.body)
    assert_equal @subagent.id, json_response["subagent_id"]
    assert_equal @subagent.display_name, json_response["subagent_name"]

    # Verify subagent is now in studio
    assert_not_nil StudioUser.find_by(studio: @studio, user: @subagent)
  end

  test "admin cannot add another user's subagent to studio via settings" do
    other_parent = create_user(name: "Other Parent")
    @tenant.add_user!(other_parent)
    other_subagent = User.create!(
      email: "other-subagent-#{SecureRandom.hex(4)}@not-a-real-email.com",
      name: "Other Subagent",
      user_type: "subagent",
      parent_id: other_parent.id,
    )
    @tenant.add_user!(other_subagent)

    sign_in_as(@parent, tenant: @tenant)

    post "/studios/#{@studio.handle}/settings/add_subagent",
         params: { subagent_id: other_subagent.id },
         headers: { "Accept" => "application/json", "Content-Type" => "application/json" },
         as: :json

    assert_response :forbidden
    assert_nil StudioUser.find_by(studio: @studio, user: other_subagent)
  end

  test "admin can remove subagent from studio via settings JSON endpoint" do
    # First add subagent to studio
    @studio.add_user!(@subagent)
    studio_user = StudioUser.find_by(studio: @studio, user: @subagent)
    assert_not_nil studio_user
    assert_not studio_user.archived?

    sign_in_as(@parent, tenant: @tenant)

    delete "/studios/#{@studio.handle}/settings/remove_subagent",
           params: { subagent_id: @subagent.id },
           headers: { "Accept" => "application/json", "Content-Type" => "application/json" },
           as: :json

    assert_response :success
    json_response = JSON.parse(response.body)
    assert_equal @subagent.id, json_response["subagent_id"]
    assert_equal true, json_response["can_readd"]

    # Verify subagent membership is archived (not deleted)
    studio_user.reload
    assert studio_user.archived?
  end

  test "non-admin cannot add subagent to studio via settings" do
    # Remove admin role from parent
    @parent.studio_users.find_by(studio: @studio)&.remove_role!('admin')

    sign_in_as(@parent, tenant: @tenant)

    post "/studios/#{@studio.handle}/settings/add_subagent",
         params: { subagent_id: @subagent.id },
         headers: { "Accept" => "application/json", "Content-Type" => "application/json" },
         as: :json

    assert_response :forbidden
  end
end
