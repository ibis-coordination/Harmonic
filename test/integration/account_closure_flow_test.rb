require "test_helper"

class AccountClosureFlowTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = @global_tenant
    @collective = @global_collective
    @user = create_user(email: "closing-#{SecureRandom.hex(4)}@example.com", name: "Closing Casey")
    @tenant.add_user!(@user)
    @collective.add_user!(@user)
  end

  test "a closing user's session is confined to the closure screen" do
    sign_in_as(@user, tenant: @tenant)
    get "/settings"
    assert_response :success

    AccountClosureService.close!(user: @user)
    # logged_in_at is stored in whole seconds; a same-second re-login would be
    # (correctly) treated as pre-revocation. Real logins can't be sub-second.
    @user.update!(sessions_revoked_at: 2.seconds.ago)
    sign_in_as(@user, tenant: @tenant) # sessions were revoked at close; log back in

    get "/settings"
    assert_redirected_to "/account/closure"

    get "/account/closure"
    assert_response :success
    assert_includes response.body, "scheduled for permanent deletion"
    scrub_date = (T.must(@user.reload.close_requested_at) + AccountClosureService::GRACE_PERIOD).to_date
    assert_includes response.body, scrub_date.to_fs(:long)
  end

  test "restoring from the closure screen returns normal access" do
    AccountClosureService.close!(user: @user)
    # See the same-second note in the confinement test.
    @user.update!(sessions_revoked_at: 2.seconds.ago)
    sign_in_as(@user, tenant: @tenant)

    post "/account/closure/restore"
    assert_redirected_to "/"
    assert_not @user.reload.closing?

    get "/settings"
    assert_response :success
  end

  test "a user who is not closing is bounced off the closure screen" do
    sign_in_as(@user, tenant: @tenant)

    get "/account/closure"
    assert_redirected_to "/"

    post "/account/closure/restore"
    assert_redirected_to "/"
  end
end
