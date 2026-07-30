require "test_helper"

class AccountDeletionFlowTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = @global_tenant
    @collective = @global_collective
    @user = create_user(email: "departing-#{SecureRandom.hex(4)}@example.com", name: "Departing Casey")
    @tenant.add_user!(@user)
    @collective.add_user!(@user)
  end

  test "a pending-deletion session is confined to the deletion screen" do
    sign_in_as(@user, tenant: @tenant)
    get "/settings"
    assert_response :success

    AccountDeletionService.request_deletion!(user: @user)
    # logged_in_at is stored in whole seconds; a same-second re-login would be
    # (correctly) treated as pre-revocation. Real logins can't be sub-second.
    @user.update!(sessions_revoked_at: 2.seconds.ago)
    sign_in_as(@user, tenant: @tenant) # sessions were revoked at close; log back in

    get "/settings"
    assert_redirected_to "/account/deletion"

    get "/account/deletion"
    assert_response :success
    assert_includes response.body, "permanently deleted on"
    scrub_date = (T.must(@user.reload.deletion_requested_at) + AccountDeletionService::GRACE_PERIOD).to_date
    assert_includes response.body, scrub_date.to_fs(:long)
  end

  test "restoring from the deletion screen returns normal access" do
    AccountDeletionService.request_deletion!(user: @user)
    # See the same-second note in the confinement test.
    @user.update!(sessions_revoked_at: 2.seconds.ago)
    sign_in_as(@user, tenant: @tenant)

    post "/account/deletion/restore"
    assert_redirected_to "/"
    assert_not @user.reload.pending_deletion?

    get "/settings"
    assert_response :success
  end

  test "a user with no deletion pending is bounced off the deletion screen" do
    sign_in_as(@user, tenant: @tenant)

    get "/account/deletion"
    assert_redirected_to "/"

    post "/account/deletion/restore"
    assert_redirected_to "/"
  end

  # === per-subdomain deletion ===

  test "a per-subdomain pending deletion confines the session on that subdomain only" do
    tenant_b = create_tenant
    tenant_b.add_user!(@user)
    tenant_b.create_main_collective!(created_by: @user)

    sign_in_as(@user, tenant: @tenant)
    AccountDeletionService.request_tenant_deletion!(user: @user, tenant: @tenant)

    get "/settings"
    assert_redirected_to "/account/deletion"

    get "/account/deletion"
    assert_response :success
    assert_includes response.body, "on this subdomain"
    scrub_date = (T.must(TenantUser.tenant_scoped_only(@tenant.id)
      .find_by(user_id: @user.id).deletion_requested_at) + AccountDeletionService::GRACE_PERIOD).to_date
    assert_includes response.body, scrub_date.to_fs(:long)

    # The same account is unaffected on the other subdomain. (reset! simulates
    # a fresh browser session — the test cookie jar can't carry a login across
    # hosts the way the real shared-domain session cookie does.)
    reset!
    sign_in_as(@user, tenant: tenant_b)
    get "/settings"
    assert_response :success
  end

  test "restoring a per-subdomain deletion from the deletion screen" do
    tenant_b = create_tenant
    tenant_b.add_user!(@user)
    sign_in_as(@user, tenant: @tenant)
    AccountDeletionService.request_tenant_deletion!(user: @user, tenant: @tenant)

    post "/account/deletion/restore"
    assert_redirected_to "/"
    assert_nil TenantUser.tenant_scoped_only(@tenant.id).find_by(user_id: @user.id).deletion_requested_at

    get "/settings"
    assert_response :success
  end
end
