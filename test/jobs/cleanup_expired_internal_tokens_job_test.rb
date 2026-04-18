require "test_helper"

class CleanupExpiredInternalTokensJobTest < ActiveJob::TestCase
  def setup
    @tenant, @collective, @user = create_tenant_collective_user
    @context = AutomationRuleRun.create!(
      tenant: @tenant,
      collective: @collective,
      automation_rule: AutomationRule.create!(
        tenant: @tenant,
        collective: @collective,
        name: "Cleanup test rule",
        trigger_type: "manual",
        trigger_config: {},
        actions: [],
        created_by: @user,
      ),
      trigger_source: "manual",
      status: "pending",
    )
  end

  test "deletes expired internal tokens" do
    # Create an expired internal token
    expired_token = ApiToken.create_internal_token(
      user: @user,
      tenant: @tenant,
      context: @context,
      expires_in: -1.hour # Already expired
    )
    expired_token_id = expired_token.id

    CleanupExpiredInternalTokensJob.perform_now

    # Token should be deleted
    assert_nil ApiToken.unscope(where: :internal).unscope(where: :tenant_id).find_by(id: expired_token_id)
  end

  test "does not delete non-expired internal tokens" do
    # Create a non-expired internal token
    active_token = ApiToken.create_internal_token(user: @user, tenant: @tenant, context: @context)
    active_token_id = active_token.id

    CleanupExpiredInternalTokensJob.perform_now

    # Token should still exist
    assert_not_nil ApiToken.unscope(where: :internal).unscope(where: :tenant_id).find_by(id: active_token_id)
  end

  test "does not delete external tokens even if expired" do
    # Create an expired external token
    expired_external = ApiToken.create!(
      user: @user,
      tenant: @tenant,
      scopes: ApiToken.read_scopes,
      name: "Expired External Token",
      expires_at: 1.hour.ago
    )
    external_token_id = expired_external.id

    CleanupExpiredInternalTokensJob.perform_now

    # External token should still exist (handled by different job with 30-day retention)
    assert_not_nil ApiToken.unscope(where: :internal).unscope(where: :tenant_id).find_by(id: external_token_id)
  end

  test "deletes multiple expired internal tokens across tenants" do
    # Create another tenant with a user
    other_tenant = create_tenant(subdomain: "other-#{SecureRandom.hex(4)}", name: "Other Tenant")
    other_user = create_user
    other_tenant.add_user!(other_user)
    other_collective = Collective.create!(
      tenant: other_tenant,
      name: "Other Collective",
      handle: "other-#{SecureRandom.hex(4)}",
      created_by: other_user,
    )
    other_context = AutomationRuleRun.create!(
      tenant: other_tenant,
      collective: other_collective,
      automation_rule: AutomationRule.create!(
        tenant: other_tenant,
        collective: other_collective,
        name: "Other test rule",
        trigger_type: "manual",
        trigger_config: {},
        actions: [],
        created_by: other_user,
      ),
      trigger_source: "manual",
      status: "pending",
    )

    # Create expired tokens in different tenants
    expired1 = ApiToken.create_internal_token(user: @user, tenant: @tenant, context: @context, expires_in: -1.hour)
    expired2 = ApiToken.create_internal_token(user: other_user, tenant: other_tenant, context: other_context, expires_in: -1.hour)
    expired1_id = expired1.id
    expired2_id = expired2.id

    CleanupExpiredInternalTokensJob.perform_now

    # Both tokens should be deleted
    assert_nil ApiToken.unscope(where: :internal).unscope(where: :tenant_id).find_by(id: expired1_id)
    assert_nil ApiToken.unscope(where: :internal).unscope(where: :tenant_id).find_by(id: expired2_id)
  end
end
