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

  # === settings entry point (request flow) ===

  test "settings page links to the account deletion page" do
    sign_in_as(@user, tenant: @tenant)

    get "/settings"
    assert_response :success
    assert_includes response.body, "/account/deletion/new"
  end

  test "the deletion confirm page requires reverification" do
    sign_in_as(@user, tenant: @tenant)

    get "/account/deletion/new"
    assert_redirected_to "/reverify"
  end

  test "the confirm page shows only the global option for a single-subdomain account" do
    sign_in_with_reverification(@user, tenant: @tenant, path: "/account/deletion/new")

    get "/account/deletion/new"
    assert_response :success
    assert_includes response.body, "Deleted User"
    assert_includes response.body, "Delete unwanted content first",
                    "the delete-content-first guidance must be on the confirm page"
    assert_not_includes response.body, 'value="subdomain"',
                        "a single-subdomain account gets no scope choice"
  end

  test "the confirm page offers both scopes for a multi-subdomain account" do
    tenant_b = create_tenant
    tenant_b.add_user!(@user)
    sign_in_with_reverification(@user, tenant: @tenant, path: "/account/deletion/new")

    get "/account/deletion/new"
    assert_response :success
    assert_includes response.body, 'value="subdomain"'
    assert_includes response.body, 'value="everywhere"'
  end

  test "submitting a global deletion request schedules deletion and signs the user out" do
    sign_in_with_reverification(@user, tenant: @tenant, path: "/account/deletion/new")

    post "/account/deletion", params: { scope: "everywhere" }
    assert_redirected_to "/login"
    assert @user.reload.pending_deletion?

    get "/settings"
    assert_redirected_to "/login"
  end

  test "submitting a subdomain deletion request confines this subdomain only" do
    tenant_b = create_tenant
    tenant_b.add_user!(@user)
    sign_in_with_reverification(@user, tenant: @tenant, path: "/account/deletion/new")

    post "/account/deletion", params: { scope: "subdomain" }
    assert_redirected_to "/account/deletion"
    assert_not @user.reload.pending_deletion?
    assert TenantUser.tenant_scoped_only(@tenant.id).find_by(user_id: @user.id).pending_deletion?

    get "/account/deletion"
    assert_response :success
  end

  test "a sole-admin block surfaces the error on the confirm page" do
    T.must(@collective.collective_members.find_by(user_id: @user.id)).add_role!("admin")
    other = create_user(email: "entry-blk-#{SecureRandom.hex(4)}@example.com", name: "Entry Blk")
    @tenant.add_user!(other)
    @collective.add_user!(other)
    sign_in_with_reverification(@user, tenant: @tenant, path: "/account/deletion/new")

    post "/account/deletion", params: { scope: "everywhere" }
    assert_redirected_to "/account/deletion/new"
    assert_match(/sole admin/, flash[:alert])
    assert_not @user.reload.pending_deletion?
  end

  test "API-token requests cannot reach the deletion request endpoints" do
    host! "#{@tenant.subdomain}.#{ENV.fetch("HOSTNAME", nil)}"
    token = ApiToken.create!(tenant: @tenant, user: @user, scopes: ApiToken.valid_scopes)
    headers = { "Authorization" => "Bearer #{token.plaintext_token}" }

    get "/account/deletion/new", headers: headers
    assert_response :forbidden

    post "/account/deletion", params: { scope: "everywhere" }, headers: headers
    assert_response :forbidden
    assert_not @user.reload.pending_deletion?
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
