require "test_helper"

class TenantTest < ActiveSupport::TestCase
  def create_tenant(subdomain: "test", name: "Test Tenant")
    Tenant.create!(subdomain: subdomain, name: name)
  end

  def create_user(email: "#{SecureRandom.hex(8)}@example.com", name: "Test Person", user_type: "person")
    User.create!(email: email, name: name, user_type: user_type)
  end

  test "Tenant.create works" do
    tenant = create_tenant
    assert tenant.persisted?
    assert_equal "Test Tenant", tenant.name
    assert_equal "test", tenant.subdomain
  end

  test "Tenant.default_studio_settings are applied" do
    tenant = create_tenant
    default_settings = tenant.default_studio_settings

    assert_equal "daily", default_settings["tempo"]
    assert_equal "improv", default_settings["synchronization_mode"]
    assert_equal false, default_settings["all_members_can_invite"]
    assert_equal false, default_settings["any_member_can_represent"]
    assert_equal true, default_settings["allow_file_uploads"]
    assert_equal 100.megabytes, default_settings["file_upload_limit"]
  end

  test "Tenant.add_user! adds a user to the tenant" do
    tenant = create_tenant
    user = create_user

    tenant.add_user!(user)
    assert tenant.tenant_users.exists?(user_id: user.id)
  end

  test "Tenant.create_main_studio! creates a main studio" do
    tenant = create_tenant
    user = create_user

    tenant.create_main_studio!(created_by: user)
    main_studio = tenant.main_studio

    assert main_studio.present?
    assert_equal tenant, main_studio.tenant
    assert_equal user, main_studio.created_by
  end

  test "Tenant.api_enabled? returns false by default" do
    tenant = create_tenant
    assert_not tenant.api_enabled?
  end

  test "Tenant.enable_api! enables the API" do
    tenant = create_tenant
    tenant.enable_api!
    assert tenant.api_enabled?
  end

  test "Tenant.require_login? returns true by default" do
    tenant = create_tenant
    assert tenant.require_login?
  end

  test "Tenant.require_login? returns false when disabled" do
    tenant = create_tenant
    tenant.settings["require_login"] = false
    assert_not tenant.require_login?
  end

  test "Tenant.auth_providers returns default providers" do
    tenant = create_tenant
    assert_equal ["github"], tenant.auth_providers
  end

  test "Tenant.add_auth_provider! adds a new provider" do
    tenant = create_tenant
    tenant.add_auth_provider!("google")
    assert_includes tenant.auth_providers, "google"
  end

  test "Tenant.is_admin? returns true for admin users" do
    tenant = create_tenant
    user = create_user
    tenant_user = tenant.tenant_users.create!(user: user)
    tenant_user.add_role!("admin")

    assert tenant.is_admin?(user)
  end

  test "Tenant.is_admin? returns false for non-admin users" do
    tenant = create_tenant
    user = create_user
    tenant.tenant_users.create!(user: user)

    assert_not tenant.is_admin?(user)
  end

  test "Tenant.team returns active users" do
    tenant = create_tenant
    user1 = create_user(name: "User 1")
    user2 = create_user(name: "User 2")
    tenant.add_user!(user1)
    tenant.add_user!(user2)

    team = tenant.team
    assert_equal 2, team.size
    assert_includes team, user1
    assert_includes team, user2
  end

  test "Tenant.url generates the correct URL" do
    tenant = create_tenant(subdomain: "example")
    expected_url = "https://example.#{ENV['HOSTNAME']}"
    assert_equal expected_url, tenant.url
  end

  # === Settings Tests ===

  test "Tenant.timezone returns UTC by default" do
    tenant = create_tenant
    assert_equal "UTC", tenant.timezone.name
  end

  test "Tenant.allow_file_uploads? returns false by default" do
    tenant = create_tenant
    assert_not tenant.allow_file_uploads?
  end

  test "Tenant.allow_main_studio_items? returns false by default" do
    tenant = create_tenant
    assert_not tenant.allow_main_studio_items?
  end

  test "Tenant.valid_auth_provider? validates provider" do
    tenant = create_tenant
    assert tenant.valid_auth_provider?("github")
    assert_not tenant.valid_auth_provider?("invalid")
  end

  # === Thread Scope Tests ===

  test "Tenant.scope_thread_to_tenant sets thread variables" do
    tenant = create_tenant(subdomain: "scope-test-#{SecureRandom.hex(4)}")
    Tenant.scope_thread_to_tenant(subdomain: tenant.subdomain)

    assert_equal tenant.subdomain, Tenant.current_subdomain
    assert_equal tenant.id, Tenant.current_id
  end

  test "Tenant.clear_thread_scope clears thread variables" do
    tenant = create_tenant(subdomain: "clear-test-#{SecureRandom.hex(4)}")
    Tenant.scope_thread_to_tenant(subdomain: tenant.subdomain)
    Tenant.clear_thread_scope

    assert_nil Tenant.current_id
  end

  test "Tenant.scope_thread_to_tenant raises for invalid subdomain" do
    assert_raises RuntimeError, "Invalid subdomain" do
      Tenant.scope_thread_to_tenant(subdomain: "nonexistent-#{SecureRandom.hex(8)}")
    end
  end

  # === Membership Role Tests ===

  test "TenantUser roles can be added" do
    tenant = create_tenant
    user = create_user
    tenant_user = tenant.tenant_users.create!(user: user)
    tenant_user.add_role!("admin")

    assert tenant_user.has_role?("admin")
  end

  test "TenantUser roles can be removed" do
    tenant = create_tenant
    user = create_user
    tenant_user = tenant.tenant_users.create!(user: user)
    tenant_user.add_role!("admin")
    tenant_user.remove_role!("admin")

    assert_not tenant_user.has_role?("admin")
  end

  # === Archive Tests ===

  test "TenantUser can be archived" do
    tenant = create_tenant
    user = create_user
    tenant_user = tenant.tenant_users.create!(user: user)

    assert_not tenant_user.archived?
    tenant_user.archive!
    assert tenant_user.archived?
    assert_not_nil tenant_user.archived_at
  end

  test "TenantUser can be unarchived" do
    tenant = create_tenant
    user = create_user
    tenant_user = tenant.tenant_users.create!(user: user)
    tenant_user.archive!
    tenant_user.unarchive!

    assert_not tenant_user.archived?
    assert_nil tenant_user.archived_at
  end

  test "Archived users are excluded from team" do
    tenant = create_tenant
    user1 = create_user(name: "Active User")
    user2 = create_user(name: "Archived User")
    tenant.add_user!(user1)
    tu2 = tenant.add_user!(user2)
    tu2.archive!

    team = tenant.team
    assert_equal 1, team.size
    assert_includes team, user1
    assert_not_includes team, user2
  end

  # === Description Test ===

  test "Tenant.description returns settings description" do
    tenant = create_tenant
    tenant.settings["description"] = "A test tenant"
    tenant.save!

    assert_equal "A test tenant", tenant.description
  end
end