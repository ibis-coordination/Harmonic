require "test_helper"

# Note: Honor System routes are only loaded when AUTH_MODE=honor_system at boot time.
# These tests verify the controller behavior but may need to be run in a separate
# test environment with AUTH_MODE=honor_system if routes are not available.
class HonorSystemSessionsControllerTest < ActionDispatch::IntegrationTest
  def setup
    @tenant = @global_tenant
    @user = @global_user
    @superagent = @global_superagent
    host! "#{@tenant.subdomain}.#{ENV['HOSTNAME']}"

    # Store original AUTH_MODE to restore after tests
    @original_auth_mode = ENV['AUTH_MODE']
  end

  def teardown
    # Restore original AUTH_MODE
    ENV['AUTH_MODE'] = @original_auth_mode
  end

  # Skip tests if honor system routes aren't loaded
  def honor_system_routes_available?
    ENV['AUTH_MODE'] == 'honor_system'
  end

  # === Honor System Controller Unit Tests ===
  # These test the controller logic directly without relying on routes

  test "check_honor_system_auth_enabled raises when AUTH_MODE is oauth" do
    ENV['AUTH_MODE'] = 'oauth'
    controller = HonorSystemSessionsController.new

    assert_raises RuntimeError, "Honor System auth is not enabled" do
      controller.send(:check_honor_system_auth_enabled)
    end
  end

  test "check_honor_system_auth_enabled passes when AUTH_MODE is honor_system" do
    ENV['AUTH_MODE'] = 'honor_system'
    controller = HonorSystemSessionsController.new

    # Should not raise
    assert_nothing_raised do
      controller.send(:check_honor_system_auth_enabled)
    end
  end

  # === Integration tests (only run if routes are available) ===

  test "login page renders when honor system is enabled and routes available" do
    skip "Honor system routes not loaded" unless honor_system_routes_available?

    get "/login"
    assert_response :success
  end

  test "login with valid email creates session when routes available" do
    skip "Honor system routes not loaded" unless honor_system_routes_available?

    post "/login", params: { email: @user.email }
    assert_response :redirect
    assert_equal root_url, response.location
  end

  test "login creates new user if email not found when routes available" do
    skip "Honor system routes not loaded" unless honor_system_routes_available?

    new_email = "newuser_#{SecureRandom.hex(4)}@example.com"

    assert_difference 'User.count', 1 do
      post "/login", params: { email: new_email, name: "New User" }
    end

    assert_response :redirect
    new_user = User.find_by(email: new_email)
    assert_not_nil new_user
    assert_equal "New User", new_user.name
    assert_equal "person", new_user.user_type
  end

  # === Single Tenant Mode Tests ===

  test "login works without subdomain in single-tenant mode" do
    skip "Honor system routes not loaded" unless honor_system_routes_available?

    ENV['SINGLE_TENANT_MODE'] = 'true'

    # Create tenant matching PRIMARY_SUBDOMAIN
    tenant = Tenant.find_by(subdomain: ENV['PRIMARY_SUBDOMAIN']) ||
             Tenant.create!(subdomain: ENV['PRIMARY_SUBDOMAIN'], name: "Primary Tenant")
    user = User.create!(email: "#{SecureRandom.hex(8)}@example.com", name: "Test User", user_type: "person")
    tenant.add_user!(user)
    tenant.create_main_superagent!(created_by: user) unless tenant.main_superagent

    # Use localhost without subdomain
    host! ENV['HOSTNAME']

    post "/login", params: { email: user.email }

    assert_response :redirect
  ensure
    ENV.delete('SINGLE_TENANT_MODE')
  end

  test "login creates session correctly in single-tenant mode" do
    skip "Honor system routes not loaded" unless honor_system_routes_available?

    ENV['SINGLE_TENANT_MODE'] = 'true'

    tenant = Tenant.find_by(subdomain: ENV['PRIMARY_SUBDOMAIN']) ||
             Tenant.create!(subdomain: ENV['PRIMARY_SUBDOMAIN'], name: "Primary Tenant")
    user = User.create!(email: "#{SecureRandom.hex(8)}@example.com", name: "Test User", user_type: "person")
    tenant.add_user!(user)
    tenant.create_main_superagent!(created_by: user) unless tenant.main_superagent

    host! ENV['HOSTNAME']

    post "/login", params: { email: user.email }

    # Verify we can access protected resource
    get "/"
    assert_response :success
  ensure
    ENV.delete('SINGLE_TENANT_MODE')
  end
end
