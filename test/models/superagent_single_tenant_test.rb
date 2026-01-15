require "test_helper"

class SuperagentSingleTenantTest < ActiveSupport::TestCase
  def setup
    @tenant = Tenant.find_by(subdomain: ENV['PRIMARY_SUBDOMAIN']) ||
              Tenant.create!(subdomain: ENV['PRIMARY_SUBDOMAIN'], name: "Primary Tenant")
    @user = User.create!(email: "#{SecureRandom.hex(8)}@example.com", name: "Test Person", user_type: "person")
    @tenant.add_user!(@user)
    @tenant.create_main_superagent!(created_by: @user) unless @tenant.main_superagent
  end

  test "Superagent.scope_thread_to_superagent handles empty subdomain in single-tenant mode" do
    ENV['SINGLE_TENANT_MODE'] = 'true'

    result = Superagent.scope_thread_to_superagent(subdomain: "", handle: nil)

    assert_equal @tenant.main_superagent.id, result.id
    assert_equal @tenant.id, Tenant.current_id
  ensure
    ENV.delete('SINGLE_TENANT_MODE')
  end

  test "Superagent.scope_thread_to_superagent raises for empty subdomain in multi-tenant mode" do
    ENV.delete('SINGLE_TENANT_MODE')

    assert_raises RuntimeError do
      Superagent.scope_thread_to_superagent(subdomain: "", handle: nil)
    end
  end
end
