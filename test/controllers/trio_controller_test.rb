# typed: false
require "test_helper"

class TrioControllerTest < ActionDispatch::IntegrationTest
  def setup
    @tenant = @global_tenant
    @collective = @global_collective
    @user = @global_user
    host! "#{@tenant.subdomain}.#{ENV.fetch("HOSTNAME", nil)}"
    @tenant.set_feature_flag!("trio", true)
  end

  test "unauthenticated user is redirected from trio page" do
    get "/trio"
    assert_response :redirect
  end

  test "GET /trio renders the chat UI with the trefoil logo" do
    sign_in_as(@user, tenant: @tenant)

    get "/trio"

    assert_response :success
    assert_select "[data-controller='trio-logo']", count: 1, minimum: 1
    assert_select "[data-controller~='agent-chat']", minimum: 1
  end

  test "GET /trio seeds trio for the current tenant if missing" do
    sign_in_as(@user, tenant: @tenant)
    # Pre-condition: no trio user exists in the tenant
    User.joins(:tenant_users)
      .where(tenant_users: { tenant_id: @tenant.id }, system_role: "trio")
      .destroy_all

    get "/trio"

    trio = User.joins(:tenant_users)
      .where(tenant_users: { tenant_id: @tenant.id }, system_role: "trio")
      .first
    assert trio, "Trio should have been seeded by visiting /trio"
  end

  test "GET /trio finds or creates a chat session between current_user and trio" do
    sign_in_as(@user, tenant: @tenant)

    assert_difference -> { ChatSession.tenant_scoped_only(@tenant.id).count }, 1 do
      get "/trio"
    end

    trio = User.joins(:tenant_users)
      .where(tenant_users: { tenant_id: @tenant.id }, system_role: "trio")
      .first
    user_one, user_two = [@user.id, trio.id].sort
    session = ChatSession.tenant_scoped_only(@tenant.id).find_by(
      user_one_id: user_one,
      user_two_id: user_two,
    )
    assert session, "Expected a chat session between current_user and trio"
  end

  test "GET /trio is idempotent on subsequent visits" do
    sign_in_as(@user, tenant: @tenant)
    get "/trio"
    initial_count = ChatSession.tenant_scoped_only(@tenant.id).count

    get "/trio"

    assert_equal initial_count, ChatSession.tenant_scoped_only(@tenant.id).count
  end

  test "GET /trio is forbidden when the trio feature flag is off" do
    @tenant.set_feature_flag!("trio", false)
    sign_in_as(@user, tenant: @tenant)

    get "/trio"

    assert_response :forbidden
  end
end
