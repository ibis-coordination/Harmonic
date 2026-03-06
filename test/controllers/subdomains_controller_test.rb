# typed: false

require "test_helper"

class SubdomainsControllerTest < ActionDispatch::IntegrationTest
  def setup
    @tenant = @global_tenant
    @user = @global_user
    host! "#{@tenant.subdomain}.#{ENV['HOSTNAME']}"
  end

  test "unauthenticated user is redirected" do
    get "/subdomains"
    assert_response :redirect
  end

  test "authenticated user can view subdomains page" do
    sign_in_as(@user, tenant: @tenant)
    get "/subdomains"
    assert_response :success
    assert_includes response.body, @tenant.subdomain
  end

  test "shows only tenants the user belongs to" do
    # Create a tenant the user is NOT a member of
    secret_tenant = create_tenant(subdomain: "secret-#{SecureRandom.hex(4)}", name: "Secret Tenant")

    sign_in_as(@user, tenant: @tenant)
    get "/subdomains"
    assert_response :success
    assert_not_includes response.body, secret_tenant.subdomain
  end

  test "shows tenants the user is a member of" do
    other_tenant = create_tenant(subdomain: "other-#{SecureRandom.hex(4)}", name: "Other Tenant")
    other_tenant.add_user!(@user)

    sign_in_as(@user, tenant: @tenant)
    get "/subdomains"
    assert_response :success
    assert_includes response.body, other_tenant.subdomain
  end

  test "marks current tenant distinctly" do
    sign_in_as(@user, tenant: @tenant)
    get "/subdomains"
    assert_response :success
    assert_includes response.body, "pulse-current-badge"
  end
end
