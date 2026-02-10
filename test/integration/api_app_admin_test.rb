require "test_helper"

class ApiAppAdminTest < ActionDispatch::IntegrationTest
  def setup
    # Use a unique subdomain to avoid conflicts with fixtures or other tests
    @primary_tenant = Tenant.create!(subdomain: "admin-api-test-#{SecureRandom.hex(4)}", name: "Admin API Test Tenant")
    @admin_user = User.create!(email: "admin-#{SecureRandom.hex(4)}@example.com", name: "Admin User", user_type: "human")
    @primary_tenant.add_user!(@admin_user)
    @primary_tenant.create_main_superagent!(created_by: @admin_user)

    # Create an app_admin token with app_admin flag
    @admin_token = ApiToken.create!(
      tenant: @primary_tenant,
      user: @admin_user,
      scopes: ["read:all"],
      app_admin: true,
    )
    @admin_plaintext_token = @admin_token.plaintext_token

    # Make the user an app_admin
    @admin_user.add_global_role!("app_admin")

    @headers = {
      "Authorization" => "Bearer #{@admin_plaintext_token}",
      "Content-Type" => "application/json",
    }

    host! "#{@primary_tenant.subdomain}.#{ENV['HOSTNAME']}"
  end

  # === Authorization Tests ===

  test "app_admin token + app_admin user can access /api/app_admin/tenants" do
    get "/api/app_admin/tenants", headers: @headers
    assert_response :success
  end

  test "app_admin token without app_admin user role returns 403" do
    @admin_user.remove_global_role!("app_admin")
    get "/api/app_admin/tenants", headers: @headers
    assert_response :forbidden
  end

  test "app_admin user without app_admin token flag returns 403" do
    @admin_token.update!(app_admin: false)
    get "/api/app_admin/tenants", headers: @headers
    assert_response :forbidden
  end

  test "sys_admin token cannot access /api/app_admin/*" do
    @admin_token.update!(app_admin: false, sys_admin: true)
    get "/api/app_admin/tenants", headers: @headers
    assert_response :forbidden
  end

  test "tenant_admin token cannot access /api/app_admin/*" do
    @admin_token.update!(app_admin: false, tenant_admin: true)
    get "/api/app_admin/tenants", headers: @headers
    assert_response :forbidden
  end

  test "regular token (no admin flags) returns 403" do
    @admin_token.update!(app_admin: false)
    get "/api/app_admin/tenants", headers: @headers
    assert_response :forbidden
  end

  test "expired token returns 401" do
    @admin_token.update!(expires_at: 1.day.ago)
    get "/api/app_admin/tenants", headers: @headers
    assert_response :unauthorized
  end

  test "missing token returns 401" do
    @headers.delete("Authorization")
    get "/api/app_admin/tenants", headers: @headers
    assert_response :unauthorized
  end

  # === List Tenants ===

  test "list tenants returns all tenants" do
    # Count existing tenants (includes global_tenant from test_helper)
    initial_count = Tenant.unscoped.count

    # Create additional tenants
    tenant2 = Tenant.create!(subdomain: "acme", name: "Acme Corp")
    tenant3 = Tenant.create!(subdomain: "beta", name: "Beta Inc")

    get "/api/app_admin/tenants", headers: @headers
    assert_response :success

    json = JSON.parse(response.body)
    assert_equal initial_count + 2, json["tenants"].length
    subdomains = json["tenants"].map { |t| t["subdomain"] }
    assert_includes subdomains, @primary_tenant.subdomain
    assert_includes subdomains, "acme"
    assert_includes subdomains, "beta"
  end

  # === Create Tenant ===

  test "create tenant with valid params" do
    post "/api/app_admin/tenants", params: {
      subdomain: "newcorp",
      name: "New Corp",
    }.to_json, headers: @headers

    assert_response :created
    json = JSON.parse(response.body)
    assert_equal "newcorp", json["subdomain"]
    assert_equal "New Corp", json["name"]
    assert_nil json["suspended_at"]

    # Verify tenant was created
    tenant = Tenant.find_by(subdomain: "newcorp")
    assert_not_nil tenant
    assert_equal "New Corp", tenant.name
  end

  test "create tenant with duplicate subdomain returns error" do
    Tenant.create!(subdomain: "existing", name: "Existing Tenant")

    post "/api/app_admin/tenants", params: {
      subdomain: "existing",
      name: "Another Tenant",
    }.to_json, headers: @headers

    assert_response :unprocessable_entity
    json = JSON.parse(response.body)
    assert json["errors"].present?
  end

  # === Get Tenant ===

  test "get tenant by ID" do
    tenant = Tenant.create!(subdomain: "lookup", name: "Lookup Tenant")

    get "/api/app_admin/tenants/#{tenant.id}", headers: @headers
    assert_response :success

    json = JSON.parse(response.body)
    assert_equal tenant.id, json["id"]
    assert_equal "lookup", json["subdomain"]
    assert_equal "Lookup Tenant", json["name"]
  end

  test "get tenant by subdomain" do
    tenant = Tenant.create!(subdomain: "bysubdomain", name: "By Subdomain Tenant")

    get "/api/app_admin/tenants/bysubdomain", headers: @headers
    assert_response :success

    json = JSON.parse(response.body)
    assert_equal tenant.id, json["id"]
    assert_equal "bysubdomain", json["subdomain"]
  end

  test "get nonexistent tenant returns 404" do
    get "/api/app_admin/tenants/nonexistent", headers: @headers
    assert_response :not_found
  end

  # === Update Tenant ===

  test "update tenant name" do
    tenant = Tenant.create!(subdomain: "updateme", name: "Old Name")

    patch "/api/app_admin/tenants/#{tenant.id}", params: {
      name: "New Name",
    }.to_json, headers: @headers

    assert_response :success
    json = JSON.parse(response.body)
    assert_equal "New Name", json["name"]

    tenant.reload
    assert_equal "New Name", tenant.name
  end

  # === Delete Tenant ===

  test "delete tenant" do
    tenant = Tenant.create!(subdomain: "deleteme", name: "Delete Me")

    delete "/api/app_admin/tenants/#{tenant.id}", headers: @headers
    assert_response :no_content

    # Verify tenant was deleted
    assert_nil Tenant.find_by(id: tenant.id)
  end

  # === Suspend/Activate ===

  test "suspend sets suspended_at and suspended_reason" do
    tenant = Tenant.create!(subdomain: "suspendme", name: "Suspend Me")

    post "/api/app_admin/tenants/#{tenant.id}/suspend", params: {
      reason: "payment_failed",
    }.to_json, headers: @headers

    assert_response :success
    json = JSON.parse(response.body)
    assert_not_nil json["suspended_at"]
    assert_equal "payment_failed", json["suspended_reason"]

    tenant.reload
    assert tenant.suspended?
    assert_equal "payment_failed", tenant.suspended_reason
  end

  test "activate clears suspended_at" do
    tenant = Tenant.create!(subdomain: "activateme", name: "Activate Me")
    tenant.suspend!(reason: "test")

    post "/api/app_admin/tenants/#{tenant.id}/activate", headers: @headers

    assert_response :success
    json = JSON.parse(response.body)
    assert_nil json["suspended_at"]
    assert_nil json["suspended_reason"]

    tenant.reload
    refute tenant.suspended?
  end
end
