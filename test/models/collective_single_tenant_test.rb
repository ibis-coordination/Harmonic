require "test_helper"

class CollectiveSingleTenantTest < ActiveSupport::TestCase
  def setup
    @tenant = Tenant.find_by(subdomain: ENV['PRIMARY_SUBDOMAIN']) ||
              Tenant.create!(subdomain: ENV['PRIMARY_SUBDOMAIN'], name: "Primary Tenant")
    @user = User.create!(email: "#{SecureRandom.hex(8)}@example.com", name: "Test Person", user_type: "human")
    @tenant.add_user!(@user)
    @tenant.create_main_collective!(created_by: @user) unless @tenant.main_collective
  end

  test "Collective.scope_thread_to_collective handles empty subdomain in single-tenant mode" do
    ENV['SINGLE_TENANT_MODE'] = 'true'

    result = Collective.scope_thread_to_collective(subdomain: "", handle: nil)

    assert_equal @tenant.main_collective.id, result.id
    assert_equal @tenant.id, Tenant.current_id
  ensure
    ENV.delete('SINGLE_TENANT_MODE')
  end

  test "Collective.scope_thread_to_collective raises for empty subdomain in multi-tenant mode" do
    ENV.delete('SINGLE_TENANT_MODE')

    assert_raises RuntimeError do
      Collective.scope_thread_to_collective(subdomain: "", handle: nil)
    end
  end
end
