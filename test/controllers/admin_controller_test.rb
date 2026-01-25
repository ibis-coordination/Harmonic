require "test_helper"

class AdminControllerTest < ActionDispatch::IntegrationTest
  def setup
    # Create the primary tenant
    @primary_tenant = Tenant.find_by(subdomain: ENV['PRIMARY_SUBDOMAIN']) ||
                      Tenant.create!(subdomain: ENV['PRIMARY_SUBDOMAIN'], name: "Primary Tenant")
    @primary_tenant.create_main_superagent!(created_by: create_user(name: "System")) unless @primary_tenant.main_superagent

    # Create a non-primary tenant
    @other_tenant = Tenant.create!(subdomain: "other-#{SecureRandom.hex(4)}", name: "Other Tenant")
    @other_tenant.create_main_superagent!(created_by: create_user(name: "System")) unless @other_tenant.main_superagent

    # Create users
    @admin_user = create_user(name: "Admin User")
    @non_admin_user = create_user(name: "Non-Admin User")
  end

  # === /admin/tenants/new Authorization Tests ===

  test "non-admin user cannot access /admin/tenants/new" do
    # Add user to primary tenant but don't give admin role
    @primary_tenant.add_user!(@non_admin_user)

    host! "#{@primary_tenant.subdomain}.#{ENV['HOSTNAME']}"
    sign_in_as(@non_admin_user, tenant: @primary_tenant)

    get "/admin/tenants/new"
    assert_response :forbidden
  end

  test "admin of non-primary tenant cannot access /admin/tenants/new" do
    # Add user to non-primary tenant and give admin role
    @other_tenant.add_user!(@admin_user)
    tenant_user = @other_tenant.tenant_users.find_by(user: @admin_user)
    tenant_user.add_role!("admin")

    host! "#{@other_tenant.subdomain}.#{ENV['HOSTNAME']}"
    sign_in_as(@admin_user, tenant: @other_tenant)

    get "/admin/tenants/new"
    assert_response :forbidden
  end

  test "admin of primary tenant can access /admin/tenants/new" do
    # Add user to primary tenant and give admin role
    @primary_tenant.add_user!(@admin_user)
    tenant_user = @primary_tenant.tenant_users.find_by(user: @admin_user)
    tenant_user.add_role!("admin")

    host! "#{@primary_tenant.subdomain}.#{ENV['HOSTNAME']}"
    sign_in_as(@admin_user, tenant: @primary_tenant)

    get "/admin/tenants/new"
    assert_response :success
  end

  # === /admin/tenants (POST - create_tenant) Authorization Tests ===

  test "non-admin user cannot create a tenant" do
    @primary_tenant.add_user!(@non_admin_user)

    host! "#{@primary_tenant.subdomain}.#{ENV['HOSTNAME']}"
    sign_in_as(@non_admin_user, tenant: @primary_tenant)

    assert_no_difference "Tenant.count" do
      post "/admin/tenants", params: { subdomain: "new-tenant", name: "New Tenant" }
    end
    assert_response :forbidden
  end

  test "admin of non-primary tenant cannot create a tenant" do
    @other_tenant.add_user!(@admin_user)
    tenant_user = @other_tenant.tenant_users.find_by(user: @admin_user)
    tenant_user.add_role!("admin")

    host! "#{@other_tenant.subdomain}.#{ENV['HOSTNAME']}"
    sign_in_as(@admin_user, tenant: @other_tenant)

    assert_no_difference "Tenant.count" do
      post "/admin/tenants", params: { subdomain: "new-tenant", name: "New Tenant" }
    end
    assert_response :forbidden
  end

  test "admin of primary tenant can create a tenant" do
    @primary_tenant.add_user!(@admin_user)
    tenant_user = @primary_tenant.tenant_users.find_by(user: @admin_user)
    tenant_user.add_role!("admin")

    host! "#{@primary_tenant.subdomain}.#{ENV['HOSTNAME']}"
    sign_in_as(@admin_user, tenant: @primary_tenant)

    new_subdomain = "new-tenant-#{SecureRandom.hex(4)}"
    assert_difference "Tenant.count", 1 do
      post "/admin/tenants", params: { subdomain: new_subdomain, name: "New Tenant" }
    end
    assert_response :redirect
  end
end
