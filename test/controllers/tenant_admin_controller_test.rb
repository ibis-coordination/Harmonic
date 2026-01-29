require "test_helper"

class TenantAdminControllerTest < ActionDispatch::IntegrationTest
  def setup
    super
    # Create primary tenant
    @primary_tenant = create_tenant(subdomain: ENV["PRIMARY_SUBDOMAIN"] || "app", name: "Primary Tenant")
    @primary_user = create_user(email: "primary@example.com", name: "Primary User")
    @primary_tenant.add_user!(@primary_user)
    @primary_tenant.create_main_superagent!(created_by: @primary_user)
    @primary_superagent = @primary_tenant.main_superagent
    @primary_superagent.add_user!(@primary_user)

    # Create secondary tenant with admin user
    @secondary_tenant = create_tenant(subdomain: "secondary", name: "Secondary Tenant")
    @secondary_admin = create_user(email: "secondary_admin@example.com", name: "Secondary Admin")
    @secondary_tenant.add_user!(@secondary_admin)
    @secondary_tenant.create_main_superagent!(created_by: @secondary_admin)
    @secondary_superagent = @secondary_tenant.main_superagent
    @secondary_superagent.add_user!(@secondary_admin)
    # Make them a tenant admin
    @secondary_tenant_user = @secondary_tenant.tenant_users.find_by(user: @secondary_admin)
    @secondary_tenant_user.add_role!('admin')

    # Create tenant admin user on primary tenant
    @tenant_admin_user = create_user(email: "tenant_admin@example.com", name: "Tenant Admin User")
    @primary_tenant.add_user!(@tenant_admin_user)
    @primary_superagent.add_user!(@tenant_admin_user)
    # Make them a tenant admin
    @primary_tenant_user = @primary_tenant.tenant_users.find_by(user: @tenant_admin_user)
    @primary_tenant_user.add_role!('admin')

    # Create a regular non-admin user on primary tenant
    @non_admin_user = create_user(email: "non_admin@example.com", name: "Non Admin User")
    @primary_tenant.add_user!(@non_admin_user)
    @primary_superagent.add_user!(@non_admin_user)
    @non_admin_tenant_user = @primary_tenant.tenant_users.find_by(user: @non_admin_user)
  end

  # ==========================================
  # Dashboard Tests
  # ==========================================

  test "tenant admin can access dashboard on primary tenant" do
    sign_in_as(@tenant_admin_user, tenant: @primary_tenant)

    get "/tenant-admin"

    assert_response :success
    assert_select "h1", /Tenant Admin/
  end

  test "tenant admin can access dashboard on secondary tenant" do
    sign_in_as(@secondary_admin, tenant: @secondary_tenant)

    get "/tenant-admin"

    assert_response :success
    assert_select "h1", /Tenant Admin/
  end

  test "non-admin cannot access tenant admin dashboard" do
    sign_in_as(@non_admin_user, tenant: @primary_tenant)

    get "/tenant-admin"

    assert_response :forbidden
    assert_select "h1", /Access Denied/
  end

  # ==========================================
  # Settings Tests
  # ==========================================

  test "tenant admin can view settings" do
    sign_in_as(@tenant_admin_user, tenant: @primary_tenant)

    get "/tenant-admin/settings"

    assert_response :success
    assert_select "h1", /Tenant Settings/
  end

  test "tenant admin can update settings" do
    sign_in_as(@tenant_admin_user, tenant: @primary_tenant)

    post "/tenant-admin/settings", params: { name: "Updated Tenant Name" }

    assert_response :redirect
    @primary_tenant.reload
    assert_equal "Updated Tenant Name", @primary_tenant.name
  end

  # ==========================================
  # Users Tests
  # ==========================================

  test "tenant admin can view users list" do
    sign_in_as(@tenant_admin_user, tenant: @primary_tenant)

    get "/tenant-admin/users"

    assert_response :success
    assert_select "h1", /Users/
  end

  test "tenant admin can search users by email" do
    sign_in_as(@tenant_admin_user, tenant: @primary_tenant)

    get "/tenant-admin/users", params: { q: @non_admin_user.email }

    assert_response :success
  end

  test "tenant admin can view user details by handle" do
    sign_in_as(@tenant_admin_user, tenant: @primary_tenant)

    get "/tenant-admin/users/#{@non_admin_tenant_user.handle}"

    assert_response :success
    assert_select "h1", /#{@non_admin_user.display_name || @non_admin_user.name}/
  end

  # ==========================================
  # User Suspension Tests (Tenant admins should NOT have suspend/unsuspend)
  # ==========================================

  test "tenant admin cannot access suspend user route (only app admins can suspend)" do
    sign_in_as(@tenant_admin_user, tenant: @primary_tenant)

    # The route should not exist for tenant admins - only app admins can suspend users
    assert_raises(ActionController::RoutingError) do
      post "/tenant-admin/users/#{@non_admin_tenant_user.handle}/actions/suspend_user", params: { reason: "Test suspension" }
    end
  end

  test "tenant admin cannot access unsuspend user route (only app admins can unsuspend)" do
    # First suspend the user via direct model update
    @non_admin_user.update!(suspended_at: Time.current, suspended_reason: "Test")

    sign_in_as(@tenant_admin_user, tenant: @primary_tenant)

    # The route should not exist for tenant admins - only app admins can unsuspend users
    assert_raises(ActionController::RoutingError) do
      post "/tenant-admin/users/#{@non_admin_tenant_user.handle}/actions/unsuspend_user"
    end
  end

  test "tenant admin cannot access describe suspend user route" do
    sign_in_as(@tenant_admin_user, tenant: @primary_tenant)

    assert_raises(ActionController::RoutingError) do
      get "/tenant-admin/users/#{@non_admin_tenant_user.handle}/actions/suspend_user"
    end
  end

  test "tenant admin cannot access describe unsuspend user route" do
    @non_admin_user.update!(suspended_at: Time.current, suspended_reason: "Test")

    sign_in_as(@tenant_admin_user, tenant: @primary_tenant)

    assert_raises(ActionController::RoutingError) do
      get "/tenant-admin/users/#{@non_admin_tenant_user.handle}/actions/unsuspend_user"
    end
  end

  # ==========================================
  # Markdown Format Tests
  # ==========================================

  test "tenant admin dashboard responds to markdown format" do
    sign_in_as(@tenant_admin_user, tenant: @primary_tenant)

    get "/tenant-admin", headers: { "Accept" => "text/markdown" }

    assert_response :success
    assert_match(/# Tenant Admin/, response.body)
  end

  test "settings responds to markdown format" do
    sign_in_as(@tenant_admin_user, tenant: @primary_tenant)

    get "/tenant-admin/settings", headers: { "Accept" => "text/markdown" }

    assert_response :success
    assert_match(/# Tenant Settings/, response.body)
  end

  test "users list responds to markdown format" do
    sign_in_as(@tenant_admin_user, tenant: @primary_tenant)

    get "/tenant-admin/users", headers: { "Accept" => "text/markdown" }

    assert_response :success
    assert_match(/# Users/, response.body)
  end

  test "user show responds to markdown format" do
    sign_in_as(@tenant_admin_user, tenant: @primary_tenant)

    get "/tenant-admin/users/#{@non_admin_tenant_user.handle}", headers: { "Accept" => "text/markdown" }

    assert_response :success
    assert_match(/Back to All Users/, response.body)
  end
end
