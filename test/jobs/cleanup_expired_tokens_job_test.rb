# typed: false

require "test_helper"

class CleanupExpiredTokensJobTest < ActiveJob::TestCase
  def setup
    @tenant, @superagent, @user = create_tenant_superagent_user
    Superagent.scope_thread_to_superagent(subdomain: @tenant.subdomain, handle: @superagent.handle)
    Tenant.current_id = @tenant.id
  end

  def teardown
    Superagent.clear_thread_scope
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

    CleanupExpiredTokensJob.perform_now

    assert_nil ApiToken.unscoped.find_by(id: old_expired_token.id), "Old expired token should be deleted"
    assert ApiToken.unscoped.find_by(id: recent_expired_token.id), "Recent expired token should be kept"
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

    CleanupExpiredTokensJob.perform_now

    assert_nil ApiToken.unscoped.find_by(id: old_deleted_token.id), "Old deleted token should be deleted"
    assert ApiToken.unscoped.find_by(id: recent_deleted_token.id), "Recent deleted token should be kept"
  end

  test "preserves active tokens" do
    active_token = @user.api_tokens.create!(
      name: "Active Token",
      scopes: ApiToken.read_scopes,
      expires_at: 1.year.from_now,
    )

    CleanupExpiredTokensJob.perform_now

    assert ApiToken.unscoped.find_by(id: active_token.id), "Active token should be preserved"
  end

  test "cleans up tokens across all tenants" do
    # Create another tenant with tokens
    tenant2 = create_tenant(subdomain: "cleanup-test")
    user2 = create_user
    tenant2.add_user!(user2)
    superagent2 = create_superagent(tenant: tenant2, created_by: user2, handle: "cleanup-studio")
    superagent2.add_user!(user2)

    Superagent.scope_thread_to_superagent(subdomain: tenant2.subdomain, handle: superagent2.handle)
    Tenant.current_id = tenant2.id

    old_token_tenant2 = user2.api_tokens.create!(
      name: "Tenant2 Old",
      scopes: ApiToken.read_scopes,
      expires_at: 31.days.ago,
    )

    # Switch back to tenant1
    Superagent.scope_thread_to_superagent(subdomain: @tenant.subdomain, handle: @superagent.handle)
    Tenant.current_id = @tenant.id

    old_token_tenant1 = @user.api_tokens.create!(
      name: "Tenant1 Old",
      scopes: ApiToken.read_scopes,
      expires_at: 31.days.ago,
    )

    CleanupExpiredTokensJob.perform_now

    assert_nil ApiToken.unscoped.find_by(id: old_token_tenant1.id), "Tenant1 old token should be deleted"
    assert_nil ApiToken.unscoped.find_by(id: old_token_tenant2.id), "Tenant2 old token should be deleted"
  end
end
