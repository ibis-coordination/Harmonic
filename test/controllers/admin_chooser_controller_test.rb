require "test_helper"

class AdminChooserControllerTest < ActionDispatch::IntegrationTest
  def setup
    super
    # Create primary tenant
    @primary_tenant = create_tenant(subdomain: ENV["PRIMARY_SUBDOMAIN"] || "app", name: "Primary Tenant")
    @primary_user = create_user(email: "primary@example.com", name: "Primary User")
    @primary_tenant.add_user!(@primary_user)
    @primary_tenant.create_main_collective!(created_by: @primary_user)
    @primary_collective = @primary_tenant.main_collective
    @primary_collective.add_user!(@primary_user)

    # Create a user with tenant admin only
    @tenant_admin = create_user(email: "tenant_admin@example.com", name: "Tenant Admin")
    @primary_tenant.add_user!(@tenant_admin)
    @primary_collective.add_user!(@tenant_admin)
    tenant_user = @primary_tenant.tenant_users.find_by(user: @tenant_admin)
    tenant_user.add_role!('admin')

    # Create a user with app_admin only
    @app_admin = create_user(email: "app_admin@example.com", name: "App Admin")
    @primary_tenant.add_user!(@app_admin)
    @primary_collective.add_user!(@app_admin)
    @app_admin.update!(app_admin: true)

    # Create a user with sys_admin only
    @sys_admin = create_user(email: "sys_admin@example.com", name: "Sys Admin")
    @primary_tenant.add_user!(@sys_admin)
    @primary_collective.add_user!(@sys_admin)
    @sys_admin.update!(sys_admin: true)

    # Create a user with multiple admin roles
    @multi_admin = create_user(email: "multi_admin@example.com", name: "Multi Admin")
    @primary_tenant.add_user!(@multi_admin)
    @primary_collective.add_user!(@multi_admin)
    multi_tenant_user = @primary_tenant.tenant_users.find_by(user: @multi_admin)
    multi_tenant_user.add_role!('admin')
    @multi_admin.update!(app_admin: true, sys_admin: true)

    # Create a non-admin user
    @non_admin = create_user(email: "non_admin@example.com", name: "Non Admin")
    @primary_tenant.add_user!(@non_admin)
    @primary_collective.add_user!(@non_admin)
  end

  test "user with only tenant admin is redirected to /tenant-admin" do
    sign_in_as(@tenant_admin, tenant: @primary_tenant)

    get "/admin"

    assert_response :redirect
    assert_redirected_to "/tenant-admin"
  end

  test "user with only app_admin is redirected to /app-admin" do
    sign_in_as(@app_admin, tenant: @primary_tenant)

    get "/admin"

    assert_response :redirect
    assert_redirected_to "/app-admin"
  end

  test "user with only sys_admin is redirected to /system-admin" do
    sign_in_as(@sys_admin, tenant: @primary_tenant)

    get "/admin"

    assert_response :redirect
    assert_redirected_to "/system-admin"
  end

  test "user with multiple admin roles sees chooser page" do
    sign_in_as(@multi_admin, tenant: @primary_tenant)

    get "/admin"

    assert_response :success
    assert_select "h1", /Admin Access/
    assert_select "a[href='/system-admin']"
    assert_select "a[href='/app-admin']"
    assert_select "a[href='/tenant-admin']"
  end

  test "non-admin user sees 403 page" do
    sign_in_as(@non_admin, tenant: @primary_tenant)

    get "/admin"

    assert_response :forbidden
    assert_select "h1", /Access Denied/
  end

  test "chooser page responds to markdown format" do
    sign_in_as(@multi_admin, tenant: @primary_tenant)

    get "/admin", headers: { "Accept" => "text/markdown" }

    assert_response :success
    assert_match(/# Admin Access/, response.body)
    assert_match(%r{/system-admin}, response.body)
    assert_match(%r{/app-admin}, response.body)
    assert_match(%r{/tenant-admin}, response.body)
  end
end
