require "test_helper"

class SystemAdminControllerTest < ActionDispatch::IntegrationTest
  def setup
    # Create the primary tenant
    @primary_tenant = Tenant.find_by(subdomain: ENV['PRIMARY_SUBDOMAIN']) ||
                      Tenant.create!(subdomain: ENV['PRIMARY_SUBDOMAIN'], name: "Primary Tenant")
    @primary_tenant.create_main_collective!(created_by: create_user(name: "System")) unless @primary_tenant.main_collective

    # Create a non-primary tenant
    @other_tenant = Tenant.create!(subdomain: "other-#{SecureRandom.hex(4)}", name: "Other Tenant")
    @other_tenant.create_main_collective!(created_by: create_user(name: "System")) unless @other_tenant.main_collective

    # Create users
    @sys_admin_user = create_user(name: "Sys Admin User")
    @sys_admin_user.update!(sys_admin: true)

    @non_sys_admin_user = create_user(name: "Non-Sys Admin User")

    @tenant_admin_user = create_user(name: "Tenant Admin User")
  end

  # ============================================================================
  # SECTION 1: Non-Primary Tenants Cannot Access System Admin
  # ============================================================================

  test "system admin routes return 404 from non-primary tenant" do
    @other_tenant.add_user!(@sys_admin_user)
    tu = @other_tenant.tenant_users.find_by(user: @sys_admin_user)
    tu.add_role!('admin')

    host! "#{@other_tenant.subdomain}.#{ENV['HOSTNAME']}"
    sign_in_as(@sys_admin_user, tenant: @other_tenant)

    get "/system-admin"
    assert_response :not_found

    get "/system-admin/sidekiq"
    assert_response :not_found
  end

  # ============================================================================
  # SECTION 2: Non-Sys-Admin Users Cannot Access System Admin
  # ============================================================================

  test "non-sys-admin user cannot access /system-admin dashboard" do
    @primary_tenant.add_user!(@non_sys_admin_user)
    tu = @primary_tenant.tenant_users.find_by(user: @non_sys_admin_user)
    tu.add_role!('admin') # Tenant admin but not sys_admin

    host! "#{@primary_tenant.subdomain}.#{ENV['HOSTNAME']}"
    sign_in_as(@non_sys_admin_user, tenant: @primary_tenant)

    get "/system-admin"
    assert_response :forbidden
    assert_match(/Access Denied|system admin/i, response.body)
  end

  test "non-sys-admin user cannot access /system-admin/sidekiq" do
    @primary_tenant.add_user!(@non_sys_admin_user)
    tu = @primary_tenant.tenant_users.find_by(user: @non_sys_admin_user)
    tu.add_role!('admin')

    host! "#{@primary_tenant.subdomain}.#{ENV['HOSTNAME']}"
    sign_in_as(@non_sys_admin_user, tenant: @primary_tenant)

    get "/system-admin/sidekiq"
    assert_response :forbidden
  end

  test "non-sys-admin user cannot access sidekiq queue page" do
    @primary_tenant.add_user!(@non_sys_admin_user)
    tu = @primary_tenant.tenant_users.find_by(user: @non_sys_admin_user)
    tu.add_role!('admin')

    host! "#{@primary_tenant.subdomain}.#{ENV['HOSTNAME']}"
    sign_in_as(@non_sys_admin_user, tenant: @primary_tenant)

    get "/system-admin/sidekiq/queues/default"
    assert_response :forbidden
  end

  # ============================================================================
  # SECTION 3: Sys-Admin Users Can Access System Admin on Primary Tenant
  # ============================================================================

  test "sys-admin user can access /system-admin dashboard" do
    @primary_tenant.add_user!(@sys_admin_user)

    host! "#{@primary_tenant.subdomain}.#{ENV['HOSTNAME']}"
    sign_in_as(@sys_admin_user, tenant: @primary_tenant)

    get "/system-admin"
    assert_response :success
    assert_match(/System Admin/i, response.body)
  end

  test "sys-admin user can access /system-admin/sidekiq" do
    @primary_tenant.add_user!(@sys_admin_user)

    host! "#{@primary_tenant.subdomain}.#{ENV['HOSTNAME']}"
    sign_in_as(@sys_admin_user, tenant: @primary_tenant)

    get "/system-admin/sidekiq"
    assert_response :success
    assert_match(/Sidekiq/i, response.body)
  end

  test "sys-admin user can access sidekiq queue page" do
    @primary_tenant.add_user!(@sys_admin_user)

    host! "#{@primary_tenant.subdomain}.#{ENV['HOSTNAME']}"
    sign_in_as(@sys_admin_user, tenant: @primary_tenant)

    get "/system-admin/sidekiq/queues/default"
    assert_response :success
    assert_match(/Queue:/i, response.body)
  end

  # ============================================================================
  # SECTION 4: Markdown API Responses
  # ============================================================================

  test "sys-admin user can access dashboard as markdown" do
    @primary_tenant.add_user!(@sys_admin_user)

    host! "#{@primary_tenant.subdomain}.#{ENV['HOSTNAME']}"
    sign_in_as(@sys_admin_user, tenant: @primary_tenant)

    get "/system-admin", headers: { "Accept" => "text/markdown" }
    assert_response :success
    assert_match(/# System Admin/, response.body)
  end

  test "dashboard loads system monitoring data" do
    @primary_tenant.add_user!(@sys_admin_user)

    host! "#{@primary_tenant.subdomain}.#{ENV['HOSTNAME']}"
    sign_in_as(@sys_admin_user, tenant: @primary_tenant)

    get "/system-admin"
    assert_response :success

    # Verify monitoring sections are present
    assert_match(/System Monitoring/, response.body)
    assert_match(/Security/, response.body)
    assert_match(/AI Agents/, response.body)
    assert_match(/Webhooks/, response.body)
    assert_match(/Events/, response.body)
    assert_match(/Resources/, response.body)
  end

  test "dashboard markdown includes monitoring data" do
    @primary_tenant.add_user!(@sys_admin_user)

    host! "#{@primary_tenant.subdomain}.#{ENV['HOSTNAME']}"
    sign_in_as(@sys_admin_user, tenant: @primary_tenant)

    get "/system-admin", headers: { "Accept" => "text/markdown" }
    assert_response :success

    # Verify monitoring sections are present in markdown
    assert_match(/System Monitoring/, response.body)
    assert_match(/Security \(Last 24 hours\)/, response.body)
    assert_match(/AI Agent Task Runs/, response.body)
    assert_match(/Webhook Deliveries/, response.body)
    assert_match(/Event Activity/, response.body)
    assert_match(/System Resources/, response.body)
  end

  test "sys-admin user can access sidekiq as markdown" do
    @primary_tenant.add_user!(@sys_admin_user)

    host! "#{@primary_tenant.subdomain}.#{ENV['HOSTNAME']}"
    sign_in_as(@sys_admin_user, tenant: @primary_tenant)

    get "/system-admin/sidekiq", headers: { "Accept" => "text/markdown" }
    assert_response :success
    assert_match(/# Sidekiq Dashboard/, response.body)
  end

  # ============================================================================
  # SECTION 5: sys_admin Role is Global (Not Tenant-Specific)
  # ============================================================================

  test "sys_admin role is stored on User model not TenantUser" do
    user = create_user(name: "New User")
    assert_not user.sys_admin?

    user.update!(sys_admin: true)
    assert user.sys_admin?

    # The role persists regardless of tenant context
    @primary_tenant.add_user!(user)
    @other_tenant.add_user!(user)

    # User should have sys_admin role in both tenants
    assert user.sys_admin?
    assert user.reload.sys_admin?
  end
end
