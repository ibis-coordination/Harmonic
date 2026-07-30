require "test_helper"

# End-to-end joints of the account-deletion chain: what a deleted user's old
# session can still do (nothing), and what other members see afterward
# ("Deleted User", never the old identity).
class AccountDeletionTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = @global_tenant
    @collective = @global_collective
    @viewer = @global_user
    @departing = create_user(
      email: "departing-#{SecureRandom.hex(4)}@example.com",
      name: "Departing Person",
    )
    @tenant.add_user!(@departing)
    @collective.add_user!(@departing)
  end

  def delete_departing_user!
    ddm = DataDeletionManager.new(user: @departing)
    ddm.delete_user!(user: @departing, confirmation_token: ddm.confirmation_token)
  end

  test "a deleted user's live session is rejected on its next request" do
    sign_in_as(@departing, tenant: @tenant)
    get "/settings"
    assert_response :success

    delete_departing_user!

    get "/settings"
    assert_response :redirect, "the pre-deletion session must not survive deletion"
  end

  test "a deleted user's content renders as Deleted User with no trace of the old identity" do
    note = create_note(
      tenant: @tenant, collective: @collective, created_by: @departing,
      title: "Left Behind", text: "Content that outlives its author's account.",
    )
    tenant_user = T.must(TenantUser.for_user_across_tenants(@departing).first)
    old_handle = tenant_user.handle
    old_display_name = tenant_user.display_name

    delete_departing_user!

    sign_in_as(@viewer, tenant: @tenant)
    get "/collectives/#{@collective.handle}/n/#{note.truncated_id}"
    assert_response :success
    assert_includes response.body, "Deleted User",
                    "the scrubbed author must render as Deleted User"
    assert_not_includes response.body, old_handle,
                        "the old handle must not appear anywhere on the page"
    assert_not_includes response.body, old_display_name,
                        "the old display name must not appear anywhere on the page"
    assert_includes response.body, "Left Behind", "the content itself must survive"
  end
end
