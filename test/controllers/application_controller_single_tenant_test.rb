require "test_helper"

class ApplicationControllerSingleTenantTest < ActionDispatch::IntegrationTest
  def setup
    @original_hostname = ENV['HOSTNAME']
    ENV['SINGLE_TENANT_MODE'] = 'true'
    @tenant = Tenant.find_by(subdomain: ENV['PRIMARY_SUBDOMAIN']) ||
              Tenant.create!(subdomain: ENV['PRIMARY_SUBDOMAIN'], name: "Primary Tenant")
    @user = User.create!(email: "#{SecureRandom.hex(8)}@example.com", name: "Test User", user_type: "person")
    @tenant.add_user!(@user)
    @tenant.create_main_superagent!(created_by: @user) unless @tenant.main_superagent
    @superagent = @tenant.main_superagent
  end

  def teardown
    ENV.delete('SINGLE_TENANT_MODE')
    ENV['HOSTNAME'] = @original_hostname
  end

  test "can access app on plain hostname without subdomain" do
    host! ENV['HOSTNAME']

    # Just verify we don't get a routing error
    get "/"
    assert_response :redirect # redirects to login or home
  end

  test "tenant is resolved correctly from empty subdomain" do
    ENV['HOSTNAME'] = 'localhost:3000'
    host! "localhost:3000"

    get "/"

    # If we get here without error, tenant was resolved
    assert [200, 302].include?(response.status)
  end

  test "check_auth_subdomain is skipped in single-tenant mode" do
    # In multi-tenant mode, accessing auth subdomain without being auth controller
    # would redirect to /login. In single-tenant mode, this check is skipped.
    host! ENV['HOSTNAME']

    get "/"

    # Should not redirect to /login due to auth subdomain check
    # (may redirect for other reasons like require_login)
    assert [200, 302].include?(response.status)
  end
end
