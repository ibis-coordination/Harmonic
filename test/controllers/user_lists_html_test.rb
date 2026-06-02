require "test_helper"

# Tests for the HTML routes of UserListsController:
#   GET /lists/new           (new list form)
#   GET /lists/:list_id/edit (edit list form, includes Danger zone for non-primary)
#   GET /lists/:list_id      (HTML show — Edit visible to owner, no Delete here)
#   GET /u/:handle/lists     (HTML index)
#
# These complement the markdown tests in user_lists_show_test.rb. Where the
# markdown tests verify the agent-facing data shape, these verify the
# browser-facing UI affordances (Edit button visibility, Danger zone
# visibility, no Delete on show, etc.).
class UserListsHtmlTest < ActionDispatch::IntegrationTest
  def setup
    @tenant = @global_tenant
    @collective = @tenant.main_collective
    @user = @global_user
    @collective.add_user!(@user) unless @collective.user_is_member?(@user)

    @other = create_user(email: "o-#{SecureRandom.hex(4)}@example.com", name: "O #{SecureRandom.hex(4)}")
    @tenant.add_user!(@other)
    @collective.add_user!(@other)

    host! "#{@tenant.subdomain}.#{ENV.fetch("HOSTNAME", nil)}"
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: nil)
  end

  # ============================================================
  # GET /lists/new
  # ============================================================

  test "new: signed-in user gets the form" do
    sign_in_as(@user, tenant: @tenant)
    get "/lists/new"
    assert_response :success
    assert_select "form input[name=name]"
    assert_select "form select[name=visibility]"
    assert_select "form select[name=add_policy]"
    assert_select "form button[type=submit]", text: /Create list/
  end

  test "new: form wires list-form Stimulus controller for live visibility/policy constraint" do
    sign_in_as(@user, tenant: @tenant)
    get "/lists/new"
    assert_response :success
    assert_select "form[data-controller='list-form']"
    assert_select "select[data-list-form-target='visibility']"
    assert_select "select[data-list-form-target='addPolicy']"
  end

  # ============================================================
  # GET /lists/:list_id/edit
  # ============================================================

  test "edit: owner gets the form" do
    list = UserList.create!(creator: @user, owner: @user, name: "Mine")
    sign_in_as(@user, tenant: @tenant)
    get "/lists/#{list.truncated_id}/edit"
    assert_response :success
    assert_select "form input[name=name][value=?]", "Mine"
    assert_select "form button[type=submit]", text: /Save changes/
  end

  test "edit: non-owner gets 403" do
    list = UserList.create!(creator: @user, owner: @user, name: "Mine")
    sign_in_as(@other, tenant: @tenant)
    get "/lists/#{list.truncated_id}/edit"
    assert_response :forbidden
  end

  test "edit: 404 for an unknown list id" do
    sign_in_as(@user, tenant: @tenant)
    get "/lists/deadbeef/edit"
    assert_response :not_found
  end

  test "edit: 404 for a private list the user can't see (existence-hidden)" do
    list = UserList.create!(creator: @other, owner: @other, name: "Hidden", visibility: "private")
    sign_in_as(@user, tenant: @tenant)
    get "/lists/#{list.truncated_id}/edit"
    assert_response :not_found
  end

  test "edit: Danger zone with Delete button appears for a non-primary list" do
    list = UserList.create!(creator: @user, owner: @user, name: "Custom")
    sign_in_as(@user, tenant: @tenant)
    get "/lists/#{list.truncated_id}/edit"
    assert_response :success
    assert_select "form[action=?]", "/lists/#{list.truncated_id}/actions/delete_user_list"
    assert_select "button.pulse-action-btn-danger", text: /Delete/
  end

  test "edit: Danger zone is hidden for the primary list (cannot be deleted)" do
    primary = @user.primary_user_list_in!(@tenant)
    sign_in_as(@user, tenant: @tenant)
    get "/lists/#{primary.truncated_id}/edit"
    assert_response :success
    assert_select "form[action=?]", "/lists/#{primary.truncated_id}/actions/delete_user_list", count: 0
    assert_select "button.pulse-action-btn-danger", count: 0
  end

  # ============================================================
  # GET /lists/:list_id (HTML show)
  # ============================================================

  test "show HTML: owner sees Edit but NOT Delete (Delete lives on edit page)" do
    list = UserList.create!(creator: @user, owner: @user, name: "Custom")
    sign_in_as(@user, tenant: @tenant)
    get "/lists/#{list.truncated_id}"
    assert_response :success
    assert_select "a[href=?]", "/lists/#{list.truncated_id}/edit", text: /Edit/
    # Delete button must not be rendered on the show page (moved to edit).
    assert_select "form[action=?]", "/lists/#{list.truncated_id}/actions/delete_user_list", count: 0
  end

  test "show HTML: non-owner sees neither Edit nor Delete" do
    list = UserList.create!(creator: @user, owner: @user, name: "Custom")
    sign_in_as(@other, tenant: @tenant)
    get "/lists/#{list.truncated_id}"
    assert_response :success
    assert_select "a[href=?]", "/lists/#{list.truncated_id}/edit", count: 0
    assert_select "form[action=?]", "/lists/#{list.truncated_id}/actions/delete_user_list", count: 0
  end

  test "show HTML: 404 for private list to non-owner" do
    list = UserList.create!(creator: @user, owner: @user, name: "Hidden", visibility: "private")
    sign_in_as(@other, tenant: @tenant)
    get "/lists/#{list.truncated_id}"
    assert_response :not_found
  end

  # ============================================================
  # GET /u/:handle/lists (HTML index)
  # ============================================================

  test "index HTML: owner sees a New list button" do
    sign_in_as(@user, tenant: @tenant)
    get "/u/#{@user.handle}/lists"
    assert_response :success
    assert_select "a[href='/lists/new']", text: /New list/
  end

  test "index HTML: non-owner does NOT see a New list button" do
    sign_in_as(@other, tenant: @tenant)
    get "/u/#{@user.handle}/lists"
    assert_response :success
    assert_select "a[href='/lists/new']", count: 0
  end

  # ============================================================
  # Profile HTML: toggle button + Lists accordion
  # ============================================================

  test "profile HTML: viewing another user shows the Tune-in toggle in OFF state" do
    sign_in_as(@user, tenant: @tenant)
    get "/u/#{@other.handle}"
    assert_response :success
    assert_select "button[data-controller='ajax-toggle']" do
      # Currently off — POSTs to tune_in, alt points to tune_out.
      assert_select "[data-ajax-toggle-url-value=?]", "/u/#{@other.handle}/actions/tune_in"
      assert_select "[data-ajax-toggle-alt-url-value=?]", "/u/#{@other.handle}/actions/tune_out"
    end
  end

  test "profile HTML: toggle reflects ON state when target is on viewer's primary" do
    list = @user.primary_user_list_in!(@tenant)
    list.user_list_members.create!(added_by: @user, user: @other)
    sign_in_as(@user, tenant: @tenant)
    get "/u/#{@other.handle}"
    assert_response :success
    assert_select "button[data-controller='ajax-toggle']" do
      assert_select "[data-ajax-toggle-url-value=?]", "/u/#{@other.handle}/actions/tune_out"
      assert_select "[data-ajax-toggle-alt-url-value=?]", "/u/#{@other.handle}/actions/tune_in"
    end
  end

  test "profile HTML: NO toggle on your own profile" do
    sign_in_as(@user, tenant: @tenant)
    get "/u/#{@user.handle}"
    assert_response :success
    assert_select "button[data-controller='ajax-toggle']", count: 0
  end

  test "profile HTML: Lists accordion renders for owner even when empty" do
    sign_in_as(@user, tenant: @tenant)
    get "/u/#{@user.handle}"
    assert_response :success
    assert_select "details summary", text: /Lists/
    assert_select "a[href='/lists/new']", text: /New list/
  end

  test "profile HTML: Lists accordion is hidden when viewing another user with no visible lists" do
    sign_in_as(@user, tenant: @tenant)
    get "/u/#{@other.handle}"
    assert_response :success
    assert_select "details summary", text: /^Lists/, count: 0
  end
end
