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
    @other_admin_user = create_user(name: "Other Tenant Admin")
  end

  # ============================================================================
  # SECTION 1: Non-Admin Users Cannot Access Any Admin Pages
  # ============================================================================

  # --- Basic Admin Pages ---

  test "non-admin user cannot access /admin dashboard" do
    @primary_tenant.add_user!(@non_admin_user)

    host! "#{@primary_tenant.subdomain}.#{ENV['HOSTNAME']}"
    sign_in_as(@non_admin_user, tenant: @primary_tenant)

    get "/legacy-admin"
    assert_response :forbidden
    assert_match(/Admin Access Required|admin/i, response.body)
  end

  test "non-admin user cannot access /admin/actions" do
    @primary_tenant.add_user!(@non_admin_user)

    host! "#{@primary_tenant.subdomain}.#{ENV['HOSTNAME']}"
    sign_in_as(@non_admin_user, tenant: @primary_tenant)

    get "/legacy-admin/actions"
    assert_response :forbidden
  end

  test "non-admin user cannot access /admin/settings" do
    @primary_tenant.add_user!(@non_admin_user)

    host! "#{@primary_tenant.subdomain}.#{ENV['HOSTNAME']}"
    sign_in_as(@non_admin_user, tenant: @primary_tenant)

    get "/legacy-admin/settings"
    assert_response :forbidden
  end

  test "non-admin user cannot POST to /admin/settings" do
    @primary_tenant.add_user!(@non_admin_user)

    host! "#{@primary_tenant.subdomain}.#{ENV['HOSTNAME']}"
    sign_in_as(@non_admin_user, tenant: @primary_tenant)

    post "/legacy-admin/settings", params: { name: "Hacked Tenant" }
    assert_response :forbidden
  end

  test "non-admin user cannot access /admin/settings/actions" do
    @primary_tenant.add_user!(@non_admin_user)

    host! "#{@primary_tenant.subdomain}.#{ENV['HOSTNAME']}"
    sign_in_as(@non_admin_user, tenant: @primary_tenant)

    get "/legacy-admin/settings/actions"
    assert_response :forbidden
  end

  test "non-admin user cannot access /admin/settings/actions/update_tenant_settings (GET)" do
    @primary_tenant.add_user!(@non_admin_user)

    host! "#{@primary_tenant.subdomain}.#{ENV['HOSTNAME']}"
    sign_in_as(@non_admin_user, tenant: @primary_tenant)

    get "/legacy-admin/settings/actions/update_tenant_settings"
    assert_response :forbidden
  end

  test "non-admin user cannot POST /admin/settings/actions/update_tenant_settings" do
    @primary_tenant.add_user!(@non_admin_user)

    host! "#{@primary_tenant.subdomain}.#{ENV['HOSTNAME']}"
    sign_in_as(@non_admin_user, tenant: @primary_tenant)

    post "/legacy-admin/settings/actions/update_tenant_settings", params: { name: "Hacked" }
    assert_response :forbidden
  end

  # --- Tenant Management Pages (Primary-Only, but still blocked for non-admins) ---

  test "non-admin user cannot access /admin/tenants" do
    @primary_tenant.add_user!(@non_admin_user)

    host! "#{@primary_tenant.subdomain}.#{ENV['HOSTNAME']}"
    sign_in_as(@non_admin_user, tenant: @primary_tenant)

    get "/legacy-admin/tenants"
    assert_response :forbidden
  end

  test "non-admin user cannot access /admin/tenants/new" do
    @primary_tenant.add_user!(@non_admin_user)

    host! "#{@primary_tenant.subdomain}.#{ENV['HOSTNAME']}"
    sign_in_as(@non_admin_user, tenant: @primary_tenant)

    get "/legacy-admin/tenants/new"
    assert_response :forbidden
  end

  test "non-admin user cannot POST to /admin/tenants (create tenant)" do
    @primary_tenant.add_user!(@non_admin_user)

    host! "#{@primary_tenant.subdomain}.#{ENV['HOSTNAME']}"
    sign_in_as(@non_admin_user, tenant: @primary_tenant)

    assert_no_difference "Tenant.count" do
      post "/legacy-admin/tenants", params: { subdomain: "new-tenant", name: "New Tenant" }
    end
    assert_response :forbidden
  end

  test "non-admin user cannot access /admin/tenants/:subdomain (show tenant)" do
    @primary_tenant.add_user!(@non_admin_user)

    host! "#{@primary_tenant.subdomain}.#{ENV['HOSTNAME']}"
    sign_in_as(@non_admin_user, tenant: @primary_tenant)

    get "/legacy-admin/tenants/#{@other_tenant.subdomain}"
    assert_response :forbidden
  end

  test "non-admin user cannot access /admin/tenants/:subdomain/complete" do
    @primary_tenant.add_user!(@non_admin_user)

    host! "#{@primary_tenant.subdomain}.#{ENV['HOSTNAME']}"
    sign_in_as(@non_admin_user, tenant: @primary_tenant)

    get "/legacy-admin/tenants/#{@other_tenant.subdomain}/complete"
    assert_response :forbidden
  end

  test "non-admin user cannot access /admin/tenants/new/actions" do
    @primary_tenant.add_user!(@non_admin_user)

    host! "#{@primary_tenant.subdomain}.#{ENV['HOSTNAME']}"
    sign_in_as(@non_admin_user, tenant: @primary_tenant)

    get "/legacy-admin/tenants/new/actions"
    assert_response :forbidden
  end

  test "non-admin user cannot access /admin/tenants/new/actions/create_tenant (GET)" do
    @primary_tenant.add_user!(@non_admin_user)

    host! "#{@primary_tenant.subdomain}.#{ENV['HOSTNAME']}"
    sign_in_as(@non_admin_user, tenant: @primary_tenant)

    get "/legacy-admin/tenants/new/actions/create_tenant"
    assert_response :forbidden
  end

  test "non-admin user cannot POST /admin/tenants/new/actions/create_tenant" do
    @primary_tenant.add_user!(@non_admin_user)

    host! "#{@primary_tenant.subdomain}.#{ENV['HOSTNAME']}"
    sign_in_as(@non_admin_user, tenant: @primary_tenant)

    assert_no_difference "Tenant.count" do
      post "/legacy-admin/tenants/new/actions/create_tenant", params: { subdomain: "hacked", name: "Hacked" }
    end
    assert_response :forbidden
  end

  # --- Sidekiq Pages (Primary-Only, but still blocked for non-admins) ---

  test "non-admin user cannot access /admin/sidekiq" do
    @primary_tenant.add_user!(@non_admin_user)

    host! "#{@primary_tenant.subdomain}.#{ENV['HOSTNAME']}"
    sign_in_as(@non_admin_user, tenant: @primary_tenant)

    get "/legacy-admin/sidekiq"
    assert_response :forbidden
  end

  test "non-admin user cannot access /admin/sidekiq/queues/:name" do
    @primary_tenant.add_user!(@non_admin_user)

    host! "#{@primary_tenant.subdomain}.#{ENV['HOSTNAME']}"
    sign_in_as(@non_admin_user, tenant: @primary_tenant)

    get "/legacy-admin/sidekiq/queues/default"
    assert_response :forbidden
  end

  test "non-admin user cannot access /admin/sidekiq/jobs/:jid" do
    @primary_tenant.add_user!(@non_admin_user)

    host! "#{@primary_tenant.subdomain}.#{ENV['HOSTNAME']}"
    sign_in_as(@non_admin_user, tenant: @primary_tenant)

    get "/legacy-admin/sidekiq/jobs/fake-jid-123"
    assert_response :forbidden
  end

  test "non-admin user cannot POST /admin/sidekiq/jobs/:jid/retry" do
    @primary_tenant.add_user!(@non_admin_user)

    host! "#{@primary_tenant.subdomain}.#{ENV['HOSTNAME']}"
    sign_in_as(@non_admin_user, tenant: @primary_tenant)

    post "/legacy-admin/sidekiq/jobs/fake-jid-123/retry"
    assert_response :forbidden
  end

  test "non-admin user cannot access /admin/sidekiq/jobs/:jid/actions" do
    @primary_tenant.add_user!(@non_admin_user)

    host! "#{@primary_tenant.subdomain}.#{ENV['HOSTNAME']}"
    sign_in_as(@non_admin_user, tenant: @primary_tenant)

    get "/legacy-admin/sidekiq/jobs/fake-jid-123/actions"
    assert_response :forbidden
  end

  test "non-admin user cannot access /admin/sidekiq/jobs/:jid/actions/retry_sidekiq_job (GET)" do
    @primary_tenant.add_user!(@non_admin_user)

    host! "#{@primary_tenant.subdomain}.#{ENV['HOSTNAME']}"
    sign_in_as(@non_admin_user, tenant: @primary_tenant)

    get "/legacy-admin/sidekiq/jobs/fake-jid-123/actions/retry_sidekiq_job"
    assert_response :forbidden
  end

  test "non-admin user cannot POST /admin/sidekiq/jobs/:jid/actions/retry_sidekiq_job" do
    @primary_tenant.add_user!(@non_admin_user)

    host! "#{@primary_tenant.subdomain}.#{ENV['HOSTNAME']}"
    sign_in_as(@non_admin_user, tenant: @primary_tenant)

    post "/legacy-admin/sidekiq/jobs/fake-jid-123/actions/retry_sidekiq_job"
    assert_response :forbidden
  end

  # --- Security Dashboard (Primary-Only, but still blocked for non-admins) ---

  test "non-admin user cannot access /admin/security" do
    @primary_tenant.add_user!(@non_admin_user)

    host! "#{@primary_tenant.subdomain}.#{ENV['HOSTNAME']}"
    sign_in_as(@non_admin_user, tenant: @primary_tenant)

    get "/legacy-admin/security"
    assert_response :forbidden
  end

  test "non-admin user cannot access /admin/security/events/:line_number" do
    @primary_tenant.add_user!(@non_admin_user)

    host! "#{@primary_tenant.subdomain}.#{ENV['HOSTNAME']}"
    sign_in_as(@non_admin_user, tenant: @primary_tenant)

    get "/legacy-admin/security/events/1"
    assert_response :forbidden
  end

  # ============================================================================
  # SECTION 2: Admin of Non-Primary Tenant CAN Access General Admin Pages
  # ============================================================================

  test "admin of non-primary tenant can access /admin dashboard" do
    @other_tenant.add_user!(@other_admin_user)
    tenant_user = @other_tenant.tenant_users.find_by(user: @other_admin_user)
    tenant_user.add_role!("admin")

    host! "#{@other_tenant.subdomain}.#{ENV['HOSTNAME']}"
    sign_in_as(@other_admin_user, tenant: @other_tenant)

    get "/legacy-admin"
    assert_response :success
  end

  test "admin of non-primary tenant can access /admin/settings" do
    @other_tenant.add_user!(@other_admin_user)
    tenant_user = @other_tenant.tenant_users.find_by(user: @other_admin_user)
    tenant_user.add_role!("admin")

    host! "#{@other_tenant.subdomain}.#{ENV['HOSTNAME']}"
    sign_in_as(@other_admin_user, tenant: @other_tenant)

    get "/legacy-admin/settings"
    assert_response :success
  end

  test "admin of non-primary tenant can POST to /admin/settings" do
    @other_tenant.add_user!(@other_admin_user)
    tenant_user = @other_tenant.tenant_users.find_by(user: @other_admin_user)
    tenant_user.add_role!("admin")

    host! "#{@other_tenant.subdomain}.#{ENV['HOSTNAME']}"
    sign_in_as(@other_admin_user, tenant: @other_tenant)

    post "/legacy-admin/settings", params: { name: "Updated Tenant Name" }
    assert_response :redirect
    @other_tenant.reload
    assert_equal "Updated Tenant Name", @other_tenant.name
  end

  # ============================================================================
  # SECTION 3: Admin of Non-Primary Tenant CANNOT Access Primary-Only Pages
  # ============================================================================

  # --- Tenant Management ---

  test "admin of non-primary tenant cannot access /admin/tenants" do
    @other_tenant.add_user!(@other_admin_user)
    tenant_user = @other_tenant.tenant_users.find_by(user: @other_admin_user)
    tenant_user.add_role!("admin")

    host! "#{@other_tenant.subdomain}.#{ENV['HOSTNAME']}"
    sign_in_as(@other_admin_user, tenant: @other_tenant)

    get "/legacy-admin/tenants"
    assert_response :forbidden
  end

  test "admin of non-primary tenant cannot access /admin/tenants/new" do
    @other_tenant.add_user!(@other_admin_user)
    tenant_user = @other_tenant.tenant_users.find_by(user: @other_admin_user)
    tenant_user.add_role!("admin")

    host! "#{@other_tenant.subdomain}.#{ENV['HOSTNAME']}"
    sign_in_as(@other_admin_user, tenant: @other_tenant)

    get "/legacy-admin/tenants/new"
    assert_response :forbidden
  end

  test "admin of non-primary tenant cannot POST to /admin/tenants (create tenant)" do
    @other_tenant.add_user!(@other_admin_user)
    tenant_user = @other_tenant.tenant_users.find_by(user: @other_admin_user)
    tenant_user.add_role!("admin")

    host! "#{@other_tenant.subdomain}.#{ENV['HOSTNAME']}"
    sign_in_as(@other_admin_user, tenant: @other_tenant)

    assert_no_difference "Tenant.count" do
      post "/legacy-admin/tenants", params: { subdomain: "new-tenant", name: "New Tenant" }
    end
    assert_response :forbidden
  end

  test "admin of non-primary tenant cannot access /admin/tenants/:subdomain (show tenant)" do
    @other_tenant.add_user!(@other_admin_user)
    tenant_user = @other_tenant.tenant_users.find_by(user: @other_admin_user)
    tenant_user.add_role!("admin")

    host! "#{@other_tenant.subdomain}.#{ENV['HOSTNAME']}"
    sign_in_as(@other_admin_user, tenant: @other_tenant)

    get "/legacy-admin/tenants/#{@primary_tenant.subdomain}"
    assert_response :forbidden
  end

  test "admin of non-primary tenant cannot access /admin/tenants/:subdomain/complete" do
    @other_tenant.add_user!(@other_admin_user)
    tenant_user = @other_tenant.tenant_users.find_by(user: @other_admin_user)
    tenant_user.add_role!("admin")

    host! "#{@other_tenant.subdomain}.#{ENV['HOSTNAME']}"
    sign_in_as(@other_admin_user, tenant: @other_tenant)

    get "/legacy-admin/tenants/#{@other_tenant.subdomain}/complete"
    assert_response :forbidden
  end

  test "admin of non-primary tenant cannot access /admin/tenants/new/actions" do
    @other_tenant.add_user!(@other_admin_user)
    tenant_user = @other_tenant.tenant_users.find_by(user: @other_admin_user)
    tenant_user.add_role!("admin")

    host! "#{@other_tenant.subdomain}.#{ENV['HOSTNAME']}"
    sign_in_as(@other_admin_user, tenant: @other_tenant)

    get "/legacy-admin/tenants/new/actions"
    assert_response :forbidden
  end

  test "admin of non-primary tenant cannot access /admin/tenants/new/actions/create_tenant (GET)" do
    @other_tenant.add_user!(@other_admin_user)
    tenant_user = @other_tenant.tenant_users.find_by(user: @other_admin_user)
    tenant_user.add_role!("admin")

    host! "#{@other_tenant.subdomain}.#{ENV['HOSTNAME']}"
    sign_in_as(@other_admin_user, tenant: @other_tenant)

    get "/legacy-admin/tenants/new/actions/create_tenant"
    assert_response :forbidden
  end

  test "admin of non-primary tenant cannot POST /admin/tenants/new/actions/create_tenant" do
    @other_tenant.add_user!(@other_admin_user)
    tenant_user = @other_tenant.tenant_users.find_by(user: @other_admin_user)
    tenant_user.add_role!("admin")

    host! "#{@other_tenant.subdomain}.#{ENV['HOSTNAME']}"
    sign_in_as(@other_admin_user, tenant: @other_tenant)

    assert_no_difference "Tenant.count" do
      post "/legacy-admin/tenants/new/actions/create_tenant", params: { subdomain: "hacked", name: "Hacked" }
    end
    assert_response :forbidden
  end

  # --- Sidekiq ---

  test "admin of non-primary tenant cannot access /admin/sidekiq" do
    @other_tenant.add_user!(@other_admin_user)
    tenant_user = @other_tenant.tenant_users.find_by(user: @other_admin_user)
    tenant_user.add_role!("admin")

    host! "#{@other_tenant.subdomain}.#{ENV['HOSTNAME']}"
    sign_in_as(@other_admin_user, tenant: @other_tenant)

    get "/legacy-admin/sidekiq"
    assert_response :forbidden
  end

  test "admin of non-primary tenant cannot access /admin/sidekiq/queues/:name" do
    @other_tenant.add_user!(@other_admin_user)
    tenant_user = @other_tenant.tenant_users.find_by(user: @other_admin_user)
    tenant_user.add_role!("admin")

    host! "#{@other_tenant.subdomain}.#{ENV['HOSTNAME']}"
    sign_in_as(@other_admin_user, tenant: @other_tenant)

    get "/legacy-admin/sidekiq/queues/default"
    assert_response :forbidden
  end

  test "admin of non-primary tenant cannot access /admin/sidekiq/jobs/:jid" do
    @other_tenant.add_user!(@other_admin_user)
    tenant_user = @other_tenant.tenant_users.find_by(user: @other_admin_user)
    tenant_user.add_role!("admin")

    host! "#{@other_tenant.subdomain}.#{ENV['HOSTNAME']}"
    sign_in_as(@other_admin_user, tenant: @other_tenant)

    get "/legacy-admin/sidekiq/jobs/fake-jid-123"
    assert_response :forbidden
  end

  test "admin of non-primary tenant cannot POST /admin/sidekiq/jobs/:jid/retry" do
    @other_tenant.add_user!(@other_admin_user)
    tenant_user = @other_tenant.tenant_users.find_by(user: @other_admin_user)
    tenant_user.add_role!("admin")

    host! "#{@other_tenant.subdomain}.#{ENV['HOSTNAME']}"
    sign_in_as(@other_admin_user, tenant: @other_tenant)

    post "/legacy-admin/sidekiq/jobs/fake-jid-123/retry"
    assert_response :forbidden
  end

  test "admin of non-primary tenant cannot access /admin/sidekiq/jobs/:jid/actions" do
    @other_tenant.add_user!(@other_admin_user)
    tenant_user = @other_tenant.tenant_users.find_by(user: @other_admin_user)
    tenant_user.add_role!("admin")

    host! "#{@other_tenant.subdomain}.#{ENV['HOSTNAME']}"
    sign_in_as(@other_admin_user, tenant: @other_tenant)

    get "/legacy-admin/sidekiq/jobs/fake-jid-123/actions"
    assert_response :forbidden
  end

  test "admin of non-primary tenant cannot access /admin/sidekiq/jobs/:jid/actions/retry_sidekiq_job (GET)" do
    @other_tenant.add_user!(@other_admin_user)
    tenant_user = @other_tenant.tenant_users.find_by(user: @other_admin_user)
    tenant_user.add_role!("admin")

    host! "#{@other_tenant.subdomain}.#{ENV['HOSTNAME']}"
    sign_in_as(@other_admin_user, tenant: @other_tenant)

    get "/legacy-admin/sidekiq/jobs/fake-jid-123/actions/retry_sidekiq_job"
    assert_response :forbidden
  end

  test "admin of non-primary tenant cannot POST /admin/sidekiq/jobs/:jid/actions/retry_sidekiq_job" do
    @other_tenant.add_user!(@other_admin_user)
    tenant_user = @other_tenant.tenant_users.find_by(user: @other_admin_user)
    tenant_user.add_role!("admin")

    host! "#{@other_tenant.subdomain}.#{ENV['HOSTNAME']}"
    sign_in_as(@other_admin_user, tenant: @other_tenant)

    post "/legacy-admin/sidekiq/jobs/fake-jid-123/actions/retry_sidekiq_job"
    assert_response :forbidden
  end

  # --- Security Dashboard ---

  test "admin of non-primary tenant cannot access /admin/security" do
    @other_tenant.add_user!(@other_admin_user)
    tenant_user = @other_tenant.tenant_users.find_by(user: @other_admin_user)
    tenant_user.add_role!("admin")

    host! "#{@other_tenant.subdomain}.#{ENV['HOSTNAME']}"
    sign_in_as(@other_admin_user, tenant: @other_tenant)

    get "/legacy-admin/security"
    assert_response :forbidden
  end

  test "admin of non-primary tenant cannot access /admin/security/events/:line_number" do
    @other_tenant.add_user!(@other_admin_user)
    tenant_user = @other_tenant.tenant_users.find_by(user: @other_admin_user)
    tenant_user.add_role!("admin")

    host! "#{@other_tenant.subdomain}.#{ENV['HOSTNAME']}"
    sign_in_as(@other_admin_user, tenant: @other_tenant)

    get "/legacy-admin/security/events/1"
    assert_response :forbidden
  end

  # ============================================================================
  # SECTION 4: Admin of Primary Tenant CAN Access All Pages
  # ============================================================================

  test "admin of primary tenant can access /admin dashboard" do
    @primary_tenant.add_user!(@admin_user)
    tenant_user = @primary_tenant.tenant_users.find_by(user: @admin_user)
    tenant_user.add_role!("admin")

    host! "#{@primary_tenant.subdomain}.#{ENV['HOSTNAME']}"
    sign_in_as(@admin_user, tenant: @primary_tenant)

    get "/legacy-admin"
    assert_response :success
  end

  test "admin of primary tenant can access /admin/settings" do
    @primary_tenant.add_user!(@admin_user)
    tenant_user = @primary_tenant.tenant_users.find_by(user: @admin_user)
    tenant_user.add_role!("admin")

    host! "#{@primary_tenant.subdomain}.#{ENV['HOSTNAME']}"
    sign_in_as(@admin_user, tenant: @primary_tenant)

    get "/legacy-admin/settings"
    assert_response :success
  end

  test "admin of primary tenant can access /admin/tenants" do
    @primary_tenant.add_user!(@admin_user)
    tenant_user = @primary_tenant.tenant_users.find_by(user: @admin_user)
    tenant_user.add_role!("admin")

    host! "#{@primary_tenant.subdomain}.#{ENV['HOSTNAME']}"
    sign_in_as(@admin_user, tenant: @primary_tenant)

    get "/legacy-admin/tenants"
    assert_response :success
  end

  test "admin of primary tenant can access /admin/tenants/new" do
    @primary_tenant.add_user!(@admin_user)
    tenant_user = @primary_tenant.tenant_users.find_by(user: @admin_user)
    tenant_user.add_role!("admin")

    host! "#{@primary_tenant.subdomain}.#{ENV['HOSTNAME']}"
    sign_in_as(@admin_user, tenant: @primary_tenant)

    get "/legacy-admin/tenants/new"
    assert_response :success
  end

  test "admin of primary tenant can create a tenant" do
    @primary_tenant.add_user!(@admin_user)
    tenant_user = @primary_tenant.tenant_users.find_by(user: @admin_user)
    tenant_user.add_role!("admin")

    host! "#{@primary_tenant.subdomain}.#{ENV['HOSTNAME']}"
    sign_in_as(@admin_user, tenant: @primary_tenant)

    new_subdomain = "new-tenant-#{SecureRandom.hex(4)}"
    assert_difference "Tenant.count", 1 do
      post "/legacy-admin/tenants", params: { subdomain: new_subdomain, name: "New Tenant" }
    end
    assert_response :redirect
  end

  test "admin of primary tenant can access /admin/tenants/:subdomain (show tenant)" do
    @primary_tenant.add_user!(@admin_user)
    tenant_user = @primary_tenant.tenant_users.find_by(user: @admin_user)
    tenant_user.add_role!("admin")

    host! "#{@primary_tenant.subdomain}.#{ENV['HOSTNAME']}"
    sign_in_as(@admin_user, tenant: @primary_tenant)

    get "/legacy-admin/tenants/#{@other_tenant.subdomain}"
    assert_response :success
  end

  test "admin of primary tenant can access /admin/sidekiq" do
    @primary_tenant.add_user!(@admin_user)
    tenant_user = @primary_tenant.tenant_users.find_by(user: @admin_user)
    tenant_user.add_role!("admin")

    host! "#{@primary_tenant.subdomain}.#{ENV['HOSTNAME']}"
    sign_in_as(@admin_user, tenant: @primary_tenant)

    get "/legacy-admin/sidekiq"
    assert_response :success
  end

  test "admin of primary tenant can access /admin/sidekiq/queues/:name" do
    @primary_tenant.add_user!(@admin_user)
    tenant_user = @primary_tenant.tenant_users.find_by(user: @admin_user)
    tenant_user.add_role!("admin")

    host! "#{@primary_tenant.subdomain}.#{ENV['HOSTNAME']}"
    sign_in_as(@admin_user, tenant: @primary_tenant)

    get "/legacy-admin/sidekiq/queues/default"
    assert_response :success
  end

  test "admin of primary tenant can access /admin/security" do
    @primary_tenant.add_user!(@admin_user)
    tenant_user = @primary_tenant.tenant_users.find_by(user: @admin_user)
    tenant_user.add_role!("admin")

    host! "#{@primary_tenant.subdomain}.#{ENV['HOSTNAME']}"
    sign_in_as(@admin_user, tenant: @primary_tenant)

    get "/legacy-admin/security"
    assert_response :success
  end

  test "admin of primary tenant can access /admin/security as markdown" do
    @primary_tenant.add_user!(@admin_user)
    tenant_user = @primary_tenant.tenant_users.find_by(user: @admin_user)
    tenant_user.add_role!("admin")

    host! "#{@primary_tenant.subdomain}.#{ENV['HOSTNAME']}"
    sign_in_as(@admin_user, tenant: @primary_tenant)

    get "/legacy-admin/security", headers: { "Accept" => "text/markdown" }
    assert_response :success
    assert_match(/Security Dashboard/, response.body)
  end

  test "admin of primary tenant can access /admin/security with filters" do
    @primary_tenant.add_user!(@admin_user)
    tenant_user = @primary_tenant.tenant_users.find_by(user: @admin_user)
    tenant_user.add_role!("admin")

    host! "#{@primary_tenant.subdomain}.#{ENV['HOSTNAME']}"
    sign_in_as(@admin_user, tenant: @primary_tenant)

    # Test with various filter combinations
    get "/legacy-admin/security?event_type=login_failure&time_range=7d"
    assert_response :success

    get "/legacy-admin/security?ip=127.0.0.1"
    assert_response :success

    get "/legacy-admin/security?email=test@example.com&sort_by=timestamp&sort_dir=asc"
    assert_response :success
  end

  test "admin of primary tenant can access /admin/security with pagination" do
    @primary_tenant.add_user!(@admin_user)
    tenant_user = @primary_tenant.tenant_users.find_by(user: @admin_user)
    tenant_user.add_role!("admin")

    host! "#{@primary_tenant.subdomain}.#{ENV['HOSTNAME']}"
    sign_in_as(@admin_user, tenant: @primary_tenant)

    # Test with page parameter
    get "/legacy-admin/security?page=1"
    assert_response :success

    get "/legacy-admin/security?page=2"
    assert_response :success

    # Test pagination with filters
    get "/legacy-admin/security?event_type=login_failure&page=1"
    assert_response :success
  end

  test "admin of primary tenant can access /admin/security/events/:line_number" do
    @primary_tenant.add_user!(@admin_user)
    tenant_user = @primary_tenant.tenant_users.find_by(user: @admin_user)
    tenant_user.add_role!("admin")

    # Count existing lines before creating event
    log_file = Rails.root.join("log/security_audit.log")
    line_count_before = File.exist?(log_file) ? File.foreach(log_file).count : 0

    # Create a security event
    SecurityAuditLog.log_login_success(user: @admin_user, ip: "127.0.0.1", user_agent: "Test")
    line_number = line_count_before + 1

    host! "#{@primary_tenant.subdomain}.#{ENV['HOSTNAME']}"
    sign_in_as(@admin_user, tenant: @primary_tenant)

    get "/legacy-admin/security/events/#{line_number}"
    assert_response :success
  end

  test "admin of primary tenant can access /admin/security/events/:line_number as markdown" do
    @primary_tenant.add_user!(@admin_user)
    tenant_user = @primary_tenant.tenant_users.find_by(user: @admin_user)
    tenant_user.add_role!("admin")

    # Count existing lines before creating event
    log_file = Rails.root.join("log/security_audit.log")
    line_count_before = File.exist?(log_file) ? File.foreach(log_file).count : 0

    # Create a security event
    SecurityAuditLog.log_login_success(user: @admin_user, ip: "127.0.0.1", user_agent: "Test")
    line_number = line_count_before + 1

    host! "#{@primary_tenant.subdomain}.#{ENV['HOSTNAME']}"
    sign_in_as(@admin_user, tenant: @primary_tenant)

    get "/legacy-admin/security/events/#{line_number}", headers: { "Accept" => "text/markdown" }
    assert_response :success
    assert_match(/Security Event/, response.body)
  end

  test "admin of primary tenant gets 404 for invalid security event line number" do
    @primary_tenant.add_user!(@admin_user)
    tenant_user = @primary_tenant.tenant_users.find_by(user: @admin_user)
    tenant_user.add_role!("admin")

    host! "#{@primary_tenant.subdomain}.#{ENV['HOSTNAME']}"
    sign_in_as(@admin_user, tenant: @primary_tenant)

    get "/legacy-admin/security/events/999999999"
    assert_response :not_found
  end

  # ============================================================================
  # SECTION 5: AiAgent Admin Access Restrictions
  # ============================================================================

  # Helper to create API token for ai_agent and make authenticated request
  def ai_agent_api_request(method, path, ai_agent:, tenant:, params: {})
    tenant.enable_api!
    api_token = ApiToken.create!(
      user: ai_agent,
      tenant: tenant,
      name: "Test Token #{SecureRandom.hex(4)}",
      scopes: %w[read:all create:all update:all delete:all],
    )
    host! "#{tenant.subdomain}.#{ENV['HOSTNAME']}"
    send(method, path, params: params, headers: {
      "Authorization" => "Bearer #{api_token.plaintext_token}",
      "Accept" => "text/markdown",
    })
  end

  test "ai_agent without admin role cannot access admin pages" do
    # Create parent user as admin
    @primary_tenant.add_user!(@admin_user)
    tenant_user = @primary_tenant.tenant_users.find_by(user: @admin_user)
    tenant_user.add_role!("admin")

    # Create ai_agent without admin role
    ai_agent = create_ai_agent(parent: @admin_user, name: "Non-Admin AiAgent")
    @primary_tenant.add_user!(ai_agent)

    ai_agent_api_request(:get, "/legacy-admin", ai_agent: ai_agent, tenant: @primary_tenant)
    assert_response :forbidden
  end

  test "ai_agent with admin role but non-admin parent cannot access admin pages" do
    # Create parent user without admin role
    @primary_tenant.add_user!(@non_admin_user)

    # Create ai_agent with admin role
    ai_agent = create_ai_agent(parent: @non_admin_user, name: "AiAgent With Admin Role")
    @primary_tenant.add_user!(ai_agent)
    ai_agent_tenant_user = @primary_tenant.tenant_users.find_by(user: ai_agent)
    ai_agent_tenant_user.add_role!("admin")

    ai_agent_api_request(:get, "/legacy-admin", ai_agent: ai_agent, tenant: @primary_tenant)
    assert_response :forbidden
    assert_match(/AI agent admin access requires both AI agent and parent to be admins/, response.body)
  end

  test "ai_agent with admin role and admin parent can access admin pages (read)" do
    # Create parent user as admin
    @primary_tenant.add_user!(@admin_user)
    parent_tenant_user = @primary_tenant.tenant_users.find_by(user: @admin_user)
    parent_tenant_user.add_role!("admin")

    # Create ai_agent with admin role
    ai_agent = create_ai_agent(parent: @admin_user, name: "Admin AiAgent")
    @primary_tenant.add_user!(ai_agent)
    ai_agent_tenant_user = @primary_tenant.tenant_users.find_by(user: ai_agent)
    ai_agent_tenant_user.add_role!("admin")

    ai_agent_api_request(:get, "/legacy-admin", ai_agent: ai_agent, tenant: @primary_tenant)
    assert_response :success
  end

  test "ai_agent cannot perform admin write operations in production" do
    # Create parent user as admin
    @primary_tenant.add_user!(@admin_user)
    parent_tenant_user = @primary_tenant.tenant_users.find_by(user: @admin_user)
    parent_tenant_user.add_role!("admin")

    # Create ai_agent with admin role
    ai_agent = create_ai_agent(parent: @admin_user, name: "Admin AiAgent")
    @primary_tenant.add_user!(ai_agent)
    ai_agent_tenant_user = @primary_tenant.tenant_users.find_by(user: ai_agent)
    ai_agent_tenant_user.add_role!("admin")

    # Simulate production environment
    Thread.current[:simulate_production] = true
    begin
      ai_agent_api_request(:post, "/legacy-admin/settings", ai_agent: ai_agent, tenant: @primary_tenant, params: { name: "Changed By AiAgent" })
      assert_response :forbidden
      assert_match(/AI agents cannot perform admin write operations in production/, response.body)

      # Verify the tenant name was NOT changed
      @primary_tenant.reload
      refute_equal "Changed By AiAgent", @primary_tenant.name
    ensure
      Thread.current[:simulate_production] = false
    end
  end

  test "ai_agent can still read admin pages in production" do
    # Create parent user as admin
    @primary_tenant.add_user!(@admin_user)
    parent_tenant_user = @primary_tenant.tenant_users.find_by(user: @admin_user)
    parent_tenant_user.add_role!("admin")

    # Create ai_agent with admin role
    ai_agent = create_ai_agent(parent: @admin_user, name: "Admin AiAgent")
    @primary_tenant.add_user!(ai_agent)
    ai_agent_tenant_user = @primary_tenant.tenant_users.find_by(user: ai_agent)
    ai_agent_tenant_user.add_role!("admin")

    # Simulate production environment
    Thread.current[:simulate_production] = true
    begin
      ai_agent_api_request(:get, "/legacy-admin", ai_agent: ai_agent, tenant: @primary_tenant)
      assert_response :success

      ai_agent_api_request(:get, "/legacy-admin/settings", ai_agent: ai_agent, tenant: @primary_tenant)
      assert_response :success
    ensure
      Thread.current[:simulate_production] = false
    end
  end

  # ============================================================================
  # SECTION 6: Unauthenticated User Access
  # ============================================================================

  test "unauthenticated user cannot access /admin" do
    host! "#{@primary_tenant.subdomain}.#{ENV['HOSTNAME']}"

    get "/legacy-admin"
    # Should redirect to login or return unauthorized
    assert_response :redirect
  end

  test "unauthenticated user cannot access /admin/settings" do
    host! "#{@primary_tenant.subdomain}.#{ENV['HOSTNAME']}"

    get "/legacy-admin/settings"
    assert_response :redirect
  end

  test "unauthenticated user cannot POST to /admin/settings" do
    host! "#{@primary_tenant.subdomain}.#{ENV['HOSTNAME']}"

    post "/legacy-admin/settings", params: { name: "Hacked" }
    assert_response :redirect
  end

  test "unauthenticated user cannot access /admin/tenants" do
    host! "#{@primary_tenant.subdomain}.#{ENV['HOSTNAME']}"

    get "/legacy-admin/tenants"
    assert_response :redirect
  end

  test "unauthenticated user cannot access /admin/sidekiq" do
    host! "#{@primary_tenant.subdomain}.#{ENV['HOSTNAME']}"

    get "/legacy-admin/sidekiq"
    assert_response :redirect
  end

  test "unauthenticated user cannot access /admin/security" do
    host! "#{@primary_tenant.subdomain}.#{ENV['HOSTNAME']}"

    get "/legacy-admin/security"
    assert_response :redirect
  end

  test "unauthenticated user cannot access /admin/security/events/:line_number" do
    host! "#{@primary_tenant.subdomain}.#{ENV['HOSTNAME']}"

    get "/legacy-admin/security/events/1"
    assert_response :redirect
  end

  test "unauthenticated user cannot POST to create tenant" do
    host! "#{@primary_tenant.subdomain}.#{ENV['HOSTNAME']}"

    assert_no_difference "Tenant.count" do
      post "/legacy-admin/tenants", params: { subdomain: "hacked", name: "Hacked" }
    end
    assert_response :redirect
  end

  # ============================================================================
  # SECTION 7: Cross-Tenant Access Prevention
  # ============================================================================

  test "admin of one tenant cannot access admin of another tenant" do
    # Make admin_user an admin of other_tenant
    @other_tenant.add_user!(@admin_user)
    tenant_user = @other_tenant.tenant_users.find_by(user: @admin_user)
    tenant_user.add_role!("admin")

    # Add admin_user to primary_tenant but NOT as admin
    @primary_tenant.add_user!(@admin_user)

    # Sign in to primary_tenant (where user is NOT an admin)
    host! "#{@primary_tenant.subdomain}.#{ENV['HOSTNAME']}"
    sign_in_as(@admin_user, tenant: @primary_tenant)

    # Should be forbidden because user is not admin of THIS tenant
    get "/legacy-admin"
    assert_response :forbidden
  end

  test "admin of primary tenant viewing other tenant cannot modify it directly" do
    # Make user admin of primary tenant only
    @primary_tenant.add_user!(@admin_user)
    tenant_user = @primary_tenant.tenant_users.find_by(user: @admin_user)
    tenant_user.add_role!("admin")

    host! "#{@primary_tenant.subdomain}.#{ENV['HOSTNAME']}"
    sign_in_as(@admin_user, tenant: @primary_tenant)

    # Admin can view other tenant's info
    get "/legacy-admin/tenants/#{@other_tenant.subdomain}"
    assert_response :success

    # But the settings change would only affect the current tenant (primary)
    # not the tenant being viewed - this is by design
    original_other_name = @other_tenant.name
    post "/legacy-admin/settings", params: { name: "Changed Name" }

    @other_tenant.reload
    assert_equal original_other_name, @other_tenant.name, "Other tenant's name should not change"
  end

  # ============================================================================
  # SECTION 8: Data Isolation Verification
  # ============================================================================

  test "admin dashboard only shows current tenant admin users" do
    # Test on non-primary tenant to avoid the "Person Users" cross-tenant section
    # which is only shown on the primary tenant by design
    @other_tenant.add_user!(@other_admin_user)
    tenant_user = @other_tenant.tenant_users.find_by(user: @other_admin_user)
    tenant_user.add_role!("admin")

    # Create another user who is admin of primary tenant but not of other_tenant
    primary_only_admin = create_user(name: "Primary Only Admin")
    @primary_tenant.add_user!(primary_only_admin)
    primary_tenant_user = @primary_tenant.tenant_users.find_by(user: primary_only_admin)
    primary_tenant_user.add_role!("admin")

    host! "#{@other_tenant.subdomain}.#{ENV['HOSTNAME']}"
    sign_in_as(@other_admin_user, tenant: @other_tenant)

    get "/legacy-admin"
    assert_response :success

    # Verify the response contains other_tenant info and its admin
    assert_match @other_tenant.subdomain, response.body
    assert_match @other_admin_user.name, response.body

    # Verify the response does NOT contain primary tenant's admin users
    refute_match primary_only_admin.name, response.body, "Primary tenant's admin should not appear"
  end

  test "admin settings only affects current tenant" do
    @primary_tenant.add_user!(@admin_user)
    tenant_user = @primary_tenant.tenant_users.find_by(user: @admin_user)
    tenant_user.add_role!("admin")

    original_other_name = @other_tenant.name
    original_primary_name = @primary_tenant.name

    host! "#{@primary_tenant.subdomain}.#{ENV['HOSTNAME']}"
    sign_in_as(@admin_user, tenant: @primary_tenant)

    post "/legacy-admin/settings", params: { name: "Updated Primary Name" }
    assert_response :redirect

    @primary_tenant.reload
    @other_tenant.reload

    assert_equal "Updated Primary Name", @primary_tenant.name
    assert_equal original_other_name, @other_tenant.name, "Other tenant should not be affected"
  end

  # ============================================================================
  # SECTION 9: User Suspension
  # ============================================================================

  test "admin can access user list page" do
    @primary_tenant.add_user!(@admin_user)
    tenant_user = @primary_tenant.tenant_users.find_by(user: @admin_user)
    tenant_user.add_role!("admin")

    host! "#{@primary_tenant.subdomain}.#{ENV['HOSTNAME']}"
    sign_in_as(@admin_user, tenant: @primary_tenant)

    get "/legacy-admin/users"
    assert_response :success
    assert_match(/Users/, response.body)
  end

  test "admin can access user detail page" do
    @primary_tenant.add_user!(@admin_user)
    @primary_tenant.add_user!(@non_admin_user)
    admin_tenant_user = @primary_tenant.tenant_users.find_by(user: @admin_user)
    admin_tenant_user.add_role!("admin")
    non_admin_tenant_user = @primary_tenant.tenant_users.find_by(user: @non_admin_user)

    host! "#{@primary_tenant.subdomain}.#{ENV['HOSTNAME']}"
    sign_in_as(@admin_user, tenant: @primary_tenant)

    get "/legacy-admin/users/#{non_admin_tenant_user.handle}"
    assert_response :success
    assert_match(@non_admin_user.name, response.body)
  end

  test "admin can suspend a user" do
    @primary_tenant.add_user!(@admin_user)
    @primary_tenant.add_user!(@non_admin_user)
    admin_tenant_user = @primary_tenant.tenant_users.find_by(user: @admin_user)
    admin_tenant_user.add_role!("admin")
    non_admin_tenant_user = @primary_tenant.tenant_users.find_by(user: @non_admin_user)

    host! "#{@primary_tenant.subdomain}.#{ENV['HOSTNAME']}"
    sign_in_as(@admin_user, tenant: @primary_tenant)

    assert_not @non_admin_user.suspended?

    post "/legacy-admin/users/#{non_admin_tenant_user.handle}/actions/suspend_user", params: { reason: "Policy violation" }
    assert_response :redirect  # HTML format redirects on success

    @non_admin_user.reload
    assert @non_admin_user.suspended?
    assert_equal "Policy violation", @non_admin_user.suspended_reason
    assert_equal @admin_user.id, @non_admin_user.suspended_by_id
  end

  test "admin can unsuspend a user" do
    @primary_tenant.add_user!(@admin_user)
    @primary_tenant.add_user!(@non_admin_user)
    admin_tenant_user = @primary_tenant.tenant_users.find_by(user: @admin_user)
    admin_tenant_user.add_role!("admin")
    non_admin_tenant_user = @primary_tenant.tenant_users.find_by(user: @non_admin_user)

    # Suspend the user first
    @non_admin_user.suspend!(by: @admin_user, reason: "Policy violation")
    assert @non_admin_user.suspended?

    host! "#{@primary_tenant.subdomain}.#{ENV['HOSTNAME']}"
    sign_in_as(@admin_user, tenant: @primary_tenant)

    post "/legacy-admin/users/#{non_admin_tenant_user.handle}/actions/unsuspend_user"
    assert_response :redirect  # HTML format redirects on success

    @non_admin_user.reload
    assert_not @non_admin_user.suspended?
    assert_nil @non_admin_user.suspended_reason
    assert_nil @non_admin_user.suspended_by_id
  end

  test "admin cannot suspend themselves" do
    @primary_tenant.add_user!(@admin_user)
    admin_tenant_user = @primary_tenant.tenant_users.find_by(user: @admin_user)
    admin_tenant_user.add_role!("admin")

    host! "#{@primary_tenant.subdomain}.#{ENV['HOSTNAME']}"
    sign_in_as(@admin_user, tenant: @primary_tenant)

    post "/legacy-admin/users/#{admin_tenant_user.handle}/actions/suspend_user", params: { reason: "Test" }
    # HTML format returns a redirect with flash message
    assert_response :redirect
    follow_redirect!
    assert_match(/cannot suspend your own account/i, flash[:alert])

    @admin_user.reload
    assert_not @admin_user.suspended?
  end

  test "non-admin cannot suspend a user" do
    @primary_tenant.add_user!(@admin_user)
    @primary_tenant.add_user!(@non_admin_user)
    admin_tenant_user = @primary_tenant.tenant_users.find_by(user: @admin_user)
    admin_tenant_user.add_role!("admin")
    non_admin_tenant_user = @primary_tenant.tenant_users.find_by(user: @non_admin_user)

    host! "#{@primary_tenant.subdomain}.#{ENV['HOSTNAME']}"
    sign_in_as(@non_admin_user, tenant: @primary_tenant)

    post "/legacy-admin/users/#{admin_tenant_user.handle}/actions/suspend_user", params: { reason: "Test" }
    assert_response :forbidden

    @admin_user.reload
    assert_not @admin_user.suspended?
  end

  test "non-admin cannot access user list page" do
    @primary_tenant.add_user!(@non_admin_user)

    host! "#{@primary_tenant.subdomain}.#{ENV['HOSTNAME']}"
    sign_in_as(@non_admin_user, tenant: @primary_tenant)

    get "/legacy-admin/users"
    assert_response :forbidden
  end

  test "user list shows suspended badge for suspended users" do
    @primary_tenant.add_user!(@admin_user)
    @primary_tenant.add_user!(@non_admin_user)
    admin_tenant_user = @primary_tenant.tenant_users.find_by(user: @admin_user)
    admin_tenant_user.add_role!("admin")

    # Suspend the non-admin user
    @non_admin_user.suspend!(by: @admin_user, reason: "Test")

    host! "#{@primary_tenant.subdomain}.#{ENV['HOSTNAME']}"
    sign_in_as(@admin_user, tenant: @primary_tenant)

    get "/legacy-admin/users"
    assert_response :success
    assert_match(/SUSPENDED/, response.body)
  end

  test "user detail page shows suspension info for suspended users" do
    @primary_tenant.add_user!(@admin_user)
    @primary_tenant.add_user!(@non_admin_user)
    admin_tenant_user = @primary_tenant.tenant_users.find_by(user: @admin_user)
    admin_tenant_user.add_role!("admin")
    non_admin_tenant_user = @primary_tenant.tenant_users.find_by(user: @non_admin_user)

    # Suspend the non-admin user
    @non_admin_user.suspend!(by: @admin_user, reason: "Policy violation")

    host! "#{@primary_tenant.subdomain}.#{ENV['HOSTNAME']}"
    sign_in_as(@admin_user, tenant: @primary_tenant)

    get "/legacy-admin/users/#{non_admin_tenant_user.handle}"
    assert_response :success
    assert_match(/Policy violation/, response.body)
    assert_match(/unsuspend/i, response.body)
  end

  test "suspension is logged to security audit log" do
    @primary_tenant.add_user!(@admin_user)
    @primary_tenant.add_user!(@non_admin_user)
    admin_tenant_user = @primary_tenant.tenant_users.find_by(user: @admin_user)
    admin_tenant_user.add_role!("admin")
    non_admin_tenant_user = @primary_tenant.tenant_users.find_by(user: @non_admin_user)

    host! "#{@primary_tenant.subdomain}.#{ENV['HOSTNAME']}"
    sign_in_as(@admin_user, tenant: @primary_tenant)

    post "/legacy-admin/users/#{non_admin_tenant_user.handle}/actions/suspend_user", params: { reason: "Policy violation" }
    assert_response :redirect  # HTML format redirects on success

    # Check that the suspension was logged
    log_file = Rails.root.join("log/security_audit.log")
    if File.exist?(log_file)
      entries = File.readlines(log_file).map { |line| JSON.parse(line) rescue nil }.compact
      matching_entry = entries.find do |e|
        e["event"] == "user_suspended" &&
          e["email"] == @non_admin_user.email &&
          e["reason"] == "Policy violation"
      end
      assert matching_entry, "Expected to find user_suspended event in security log"
    end
  end
end
