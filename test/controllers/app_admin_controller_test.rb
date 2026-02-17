require "test_helper"

class AppAdminControllerTest < ActionDispatch::IntegrationTest
  def setup
    super
    # Create primary tenant (matches PRIMARY_SUBDOMAIN in env)
    @primary_tenant = create_tenant(subdomain: ENV["PRIMARY_SUBDOMAIN"] || "app", name: "Primary Tenant")
    @primary_user = create_user(email: "primary@example.com", name: "Primary User")
    @primary_tenant.add_user!(@primary_user)
    @primary_tenant.create_main_collective!(created_by: @primary_user)
    @primary_collective = @primary_tenant.main_collective
    @primary_collective.add_user!(@primary_user)

    # Create secondary tenant
    @secondary_tenant = create_tenant(subdomain: "secondary", name: "Secondary Tenant")
    @secondary_user = create_user(email: "secondary@example.com", name: "Secondary User")
    @secondary_tenant.add_user!(@secondary_user)
    @secondary_tenant.create_main_collective!(created_by: @secondary_user)

    # Create app admin user on primary tenant
    @app_admin_user = create_user(email: "app_admin@example.com", name: "App Admin User")
    @app_admin_user.add_global_role!("app_admin")
    @primary_tenant.add_user!(@app_admin_user)
    @primary_collective.add_user!(@app_admin_user)

    # Create sys_admin user (without app_admin role) on primary tenant
    @sys_admin_user = create_user(email: "sys_admin@example.com", name: "Sys Admin User")
    @sys_admin_user.add_global_role!("sys_admin")
    @primary_tenant.add_user!(@sys_admin_user)
    @primary_collective.add_user!(@sys_admin_user)

    # Create a regular non-admin user on primary tenant
    @non_admin_user = create_user(email: "non_admin@example.com", name: "Non Admin User")
    @primary_tenant.add_user!(@non_admin_user)
    @primary_collective.add_user!(@non_admin_user)
  end

  # ==========================================
  # Dashboard Tests
  # ==========================================

  test "app admin can access dashboard on primary tenant" do
    sign_in_as(@app_admin_user, tenant: @primary_tenant)

    get "/app-admin"

    assert_response :success
    assert_select "h1", /App Admin/
  end

  test "non-admin cannot access app admin dashboard" do
    sign_in_as(@non_admin_user, tenant: @primary_tenant)

    get "/app-admin"

    assert_response :forbidden
    assert_select "h1", /Access Denied/
  end

  test "sys_admin without app_admin role cannot access app admin" do
    # sys_admin_user is sys_admin but not app_admin
    sign_in_as(@sys_admin_user, tenant: @primary_tenant)

    get "/app-admin"

    assert_response :forbidden
  end

  test "app admin cannot access dashboard on secondary tenant" do
    # Add app_admin to secondary tenant so they can sign in
    @secondary_tenant.add_user!(@app_admin_user)
    @secondary_tenant.main_collective.add_user!(@app_admin_user)

    sign_in_as(@app_admin_user, tenant: @secondary_tenant)

    get "/app-admin"

    assert_response :not_found
  end

  # ==========================================
  # Tenants Tests
  # ==========================================

  test "app admin can view tenants list" do
    sign_in_as(@app_admin_user, tenant: @primary_tenant)

    get "/app-admin/tenants"

    assert_response :success
  end

  test "app admin can view new tenant form" do
    sign_in_as(@app_admin_user, tenant: @primary_tenant)

    get "/app-admin/tenants/new"

    assert_response :success
    assert_select "h1", /New Tenant/
  end

  test "app admin can create a new tenant" do
    sign_in_as(@app_admin_user, tenant: @primary_tenant)

    assert_difference "Tenant.count", 1 do
      post "/app-admin/tenants", params: { tenant: { name: "Test Tenant", subdomain: "testtenant" } }
    end

    assert_response :redirect
    assert_redirected_to "/app-admin/tenants/testtenant/complete"
  end

  test "app admin can view tenant details" do
    sign_in_as(@app_admin_user, tenant: @primary_tenant)

    get "/app-admin/tenants/#{@secondary_tenant.subdomain}"

    assert_response :success
    assert_select "h1", /#{@secondary_tenant.name}/
  end

  # ==========================================
  # Users Tests
  # ==========================================

  test "app admin can view all users across tenants" do
    sign_in_as(@app_admin_user, tenant: @primary_tenant)

    get "/app-admin/users"

    assert_response :success
  end

  test "app admin can search users by email" do
    sign_in_as(@app_admin_user, tenant: @primary_tenant)

    get "/app-admin/users", params: { q: @non_admin_user.email }

    assert_response :success
  end

  test "app admin can view user details by user ID" do
    sign_in_as(@app_admin_user, tenant: @primary_tenant)

    get "/app-admin/users/#{@non_admin_user.id}"

    assert_response :success
    assert_select "h1", /#{@non_admin_user.display_name || @non_admin_user.name}/
  end

  # ==========================================
  # User Suspension Tests
  # ==========================================

  test "app admin can suspend another user" do
    sign_in_as(@app_admin_user, tenant: @primary_tenant)

    post "/app-admin/users/#{@non_admin_user.id}/actions/suspend_user", params: { reason: "Test suspension" }

    assert_response :redirect
    @non_admin_user.reload
    assert @non_admin_user.suspended?
    assert_equal "Test suspension", @non_admin_user.suspended_reason
  end

  test "app admin cannot suspend themselves" do
    sign_in_as(@app_admin_user, tenant: @primary_tenant)

    post "/app-admin/users/#{@app_admin_user.id}/actions/suspend_user", params: { reason: "Self-suspension" }

    assert_response :redirect
    @app_admin_user.reload
    assert_not @app_admin_user.suspended?
  end

  test "app admin can unsuspend a user" do
    # First suspend the user
    @non_admin_user.update!(suspended_at: Time.current, suspended_reason: "Test")

    sign_in_as(@app_admin_user, tenant: @primary_tenant)

    post "/app-admin/users/#{@non_admin_user.id}/actions/unsuspend_user"

    assert_response :redirect
    @non_admin_user.reload
    assert_not @non_admin_user.suspended?
  end

  # ==========================================
  # Security Dashboard Tests
  # ==========================================

  test "app admin can view security dashboard" do
    sign_in_as(@app_admin_user, tenant: @primary_tenant)

    get "/app-admin/security"

    assert_response :success
    assert_select "h1", /Security Dashboard/
  end

  # ==========================================
  # Markdown Format Tests
  # ==========================================

  test "app admin dashboard responds to markdown format" do
    sign_in_as(@app_admin_user, tenant: @primary_tenant)

    get "/app-admin", headers: { "Accept" => "text/markdown" }

    assert_response :success
    assert_match(/# App Admin/, response.body)
  end

  test "tenants list responds to markdown format" do
    sign_in_as(@app_admin_user, tenant: @primary_tenant)

    get "/app-admin/tenants", headers: { "Accept" => "text/markdown" }

    assert_response :success
    assert_match(/# All Tenants/, response.body)
  end

  test "users list responds to markdown format" do
    sign_in_as(@app_admin_user, tenant: @primary_tenant)

    get "/app-admin/users", headers: { "Accept" => "text/markdown" }

    assert_response :success
    assert_match(/# All Users/, response.body)
  end

  test "user show responds to markdown format" do
    sign_in_as(@app_admin_user, tenant: @primary_tenant)

    get "/app-admin/users/#{@non_admin_user.id}", headers: { "Accept" => "text/markdown" }

    assert_response :success
    assert_match(/Back to Users/, response.body)
  end
end
