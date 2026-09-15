# typed: false

require "test_helper"

class CleanupExpiredTokensJobTest < ActiveJob::TestCase
  def setup
    @tenant, @collective, @user = create_tenant_collective_user
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    Tenant.current_id = @tenant.id
  end

  def teardown
    Collective.clear_thread_scope
  end

  test "deletes tokens expired more than 30 days ago" do
    # Create a token expired 31 days ago
    old_expired_token = @user.api_tokens.create!(
      name: "Old Expired",
      scopes: ApiToken.read_scopes,
      expires_at: 31.days.ago,
    )

    # Create a token expired 29 days ago (should be kept)
    recent_expired_token = @user.api_tokens.create!(
      name: "Recent Expired",
      scopes: ApiToken.read_scopes,
      expires_at: 29.days.ago,
    )

    # Clear tenant context to simulate background job environment
    Tenant.current_id = nil
    CleanupExpiredTokensJob.perform_now

    assert_nil ApiToken.find_by(id: old_expired_token.id), "Old expired token should be deleted"
    assert ApiToken.find_by(id: recent_expired_token.id), "Recent expired token should be kept"
  end

  test "deletes tokens soft-deleted more than 30 days ago" do
    # Create and soft-delete a token 31 days ago
    old_deleted_token = @user.api_tokens.create!(
      name: "Old Deleted",
      scopes: ApiToken.read_scopes,
      expires_at: 1.year.from_now,
    )
    old_deleted_token.update_columns(deleted_at: 31.days.ago)

    # Create and soft-delete a token 29 days ago (should be kept)
    recent_deleted_token = @user.api_tokens.create!(
      name: "Recent Deleted",
      scopes: ApiToken.read_scopes,
      expires_at: 1.year.from_now,
    )
    recent_deleted_token.update_columns(deleted_at: 29.days.ago)

    # Clear tenant context to simulate background job environment
    Tenant.current_id = nil
    CleanupExpiredTokensJob.perform_now

    assert_nil ApiToken.find_by(id: old_deleted_token.id), "Old deleted token should be deleted"
    assert ApiToken.find_by(id: recent_deleted_token.id), "Recent deleted token should be kept"
  end

  test "preserves active tokens" do
    active_token = @user.api_tokens.create!(
      name: "Active Token",
      scopes: ApiToken.read_scopes,
      expires_at: 1.year.from_now,
    )

    # Clear tenant context to simulate background job environment
    Tenant.current_id = nil
    CleanupExpiredTokensJob.perform_now

    assert ApiToken.find_by(id: active_token.id), "Active token should be preserved"
  end

  test "cleans up tokens across all tenants" do
    # Create another tenant with tokens
    tenant2 = create_tenant(subdomain: "cleanup-test")
    user2 = create_user
    tenant2.add_user!(user2)
    collective2 = create_collective(tenant: tenant2, created_by: user2, handle: "cleanup-collective")
    collective2.add_user!(user2)

    Collective.scope_thread_to_collective(subdomain: tenant2.subdomain, handle: collective2.handle)
    Tenant.current_id = tenant2.id

    old_token_tenant2 = user2.api_tokens.create!(
      name: "Tenant2 Old",
      scopes: ApiToken.read_scopes,
      expires_at: 31.days.ago,
    )

    # Switch back to tenant1
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    Tenant.current_id = @tenant.id

    old_token_tenant1 = @user.api_tokens.create!(
      name: "Tenant1 Old",
      scopes: ApiToken.read_scopes,
      expires_at: 31.days.ago,
    )

    # Clear tenant context to simulate background job environment
    Tenant.current_id = nil
    CleanupExpiredTokensJob.perform_now

    assert_nil ApiToken.find_by(id: old_token_tenant1.id), "Tenant1 old token should be deleted"
    assert_nil ApiToken.find_by(id: old_token_tenant2.id), "Tenant2 old token should be deleted"
  end

  test "tokens referenced by bridge setups and usage records are deleted, references nullified" do
    agent = create_ai_agent(parent: @user, name: "Bridge Agent", agent_configuration: { "mode" => "external" })
    @tenant.add_user!(agent)

    bridged_token = agent.api_tokens.create!(
      name: "Bridged Expired",
      scopes: ApiToken.read_scopes,
      expires_at: 31.days.ago,
    )
    llm_token = agent.api_tokens.create!(
      name: "LLM Expired",
      token_type: "llm_gateway",
      scopes: ApiToken.read_scopes,
      expires_at: 31.days.ago,
    )
    bridge_setup = HarmonicBridgeSetup.create!(
      tenant: @tenant,
      ai_agent_user: agent,
      created_by_user: @user,
      api_token: bridged_token,
      llm_api_token: llm_token,
    )
    usage_record = LLMUsageRecord.create!(
      selection_id: "sel_#{SecureRandom.uuid}",
      status: "pending",
      ai_agent_id: agent.id,
      payer_stripe_customer_id: "cus_cleanup_test",
      origin_tenant_id: @tenant.id,
      api_token: llm_token,
      occurred_at: Time.current,
    )
    plain_token = @user.api_tokens.create!(
      name: "Plain Expired",
      scopes: ApiToken.read_scopes,
      expires_at: 31.days.ago,
    )

    Tenant.current_id = nil
    CleanupExpiredTokensJob.perform_now

    assert_nil ApiToken.unscoped_for_system_job.find_by(id: bridged_token.id), "bridged token should be deleted"
    assert_nil ApiToken.unscoped_for_system_job.find_by(id: llm_token.id), "llm token should be deleted"
    assert_nil ApiToken.unscoped_for_system_job.find_by(id: plain_token.id), "plain token should be deleted"
    bridge_setup.reload
    assert_nil bridge_setup.api_token_id, "bridge setup token reference should be nullified"
    assert_nil bridge_setup.llm_api_token_id, "bridge setup llm token reference should be nullified"
    assert_nil usage_record.reload.api_token_id, "usage record token reference should be nullified"
  end
end
