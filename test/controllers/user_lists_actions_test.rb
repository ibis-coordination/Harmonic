require "test_helper"

# Tests for /lists action endpoints: create_user_list, update_user_list,
# delete_user_list (describe + execute).
class UserListsActionsTest < ActionDispatch::IntegrationTest
  def setup
    @tenant = @global_tenant
    @tenant.enable_api!
    @collective = @tenant.main_collective
    @collective.enable_api!
    @user = @global_user
    @collective.add_user!(@user) unless @collective.user_is_member?(@user)
    mark_activated!(@user)

    @other = create_user(email: "o-#{SecureRandom.hex(4)}@example.com", name: "O #{SecureRandom.hex(4)}")
    @tenant.add_user!(@other)
    @collective.add_user!(@other)
    mark_activated!(@other)

    @api_token   = ApiToken.create!(tenant: @tenant, user: @user,  scopes: ApiToken.valid_scopes)
    @other_token = ApiToken.create!(tenant: @tenant, user: @other, scopes: ApiToken.valid_scopes)

    @headers       = api_headers(@api_token.plaintext_token)
    @other_headers = api_headers(@other_token.plaintext_token)

    host! "#{@tenant.subdomain}.#{ENV.fetch("HOSTNAME", nil)}"

    # Thread scope so in-test UserList.create! calls work — integration
    # requests set scope via middleware on their own.
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: nil)
  end

  def api_headers(token)
    {
      "Authorization" => "Bearer #{token}",
      "Accept" => "text/markdown",
      "Content-Type" => "application/json",
    }
  end

  def is_markdown?
    response.content_type.to_s.start_with?("text/markdown")
  end

  # ============================================================
  # create_user_list
  # ============================================================

  test "describe_create_user_list returns the action description" do
    get "/lists/actions/create_user_list", headers: @headers
    assert_response :success
    assert is_markdown?
    assert_includes response.body, "create_user_list"
    assert_includes response.body, "name"
  end


  test "execute_create_user_list creates a list owned by the actor" do
    assert_difference -> { UserList.unscope(where: :collective_id).where(owner_id: @user.id, is_primary: false).count }, +1 do
      post "/lists/actions/create_user_list",
           params: { name: "Friends", description: "people I like" }.to_json,
           headers: @headers
    end
    assert_response :success
    list = UserList.unscope(where: :collective_id).where(owner_id: @user.id, is_primary: false).last
    assert_equal "Friends", list.name
    assert_equal "people I like", list.description
    assert_equal "public", list.visibility
    assert_equal @user.id, list.creator_id
    assert_equal @collective.id, list.collective_id
  end

  test "execute_create_user_list honors a private visibility param" do
    post "/lists/actions/create_user_list",
         params: { name: "Inner Circle", visibility: "private" }.to_json,
         headers: @headers
    assert_response :success
    list = UserList.unscope(where: :collective_id).where(owner_id: @user.id, name: "Inner Circle").first
    assert_equal "private", list.visibility
  end

  test "execute_create_user_list rejects blank name with 422" do
    post "/lists/actions/create_user_list",
         params: { name: "" }.to_json,
         headers: @headers
    assert_response :unprocessable_entity
  end

  test "execute_create_user_list rejects unknown visibility with 422" do
    post "/lists/actions/create_user_list",
         params: { name: "OK", visibility: "secret" }.to_json,
         headers: @headers
    assert_response :unprocessable_entity
  end

  test "execute_create_user_list honors an add_policy param" do
    post "/lists/actions/create_user_list",
         params: { name: "Open House", add_policy: "anyone_add" }.to_json,
         headers: @headers
    assert_response :success
    list = UserList.unscope(where: :collective_id).where(owner_id: @user.id, name: "Open House").first
    assert_equal "anyone_add", list.add_policy
  end

  test "describe_create_user_list documents add_policy as a parameter" do
    get "/lists/actions/create_user_list", headers: @headers
    assert_response :success
    assert_includes response.body, "add_policy"
  end

  test "execute_create_user_list cannot create a primary list" do
    # is_primary should be ignored; the created list is never primary.
    post "/lists/actions/create_user_list",
         params: { name: "Sneaky", is_primary: true }.to_json,
         headers: @headers
    assert_response :success
    list = UserList.unscope(where: :collective_id).where(owner_id: @user.id, name: "Sneaky").first
    assert_equal false, list.is_primary
  end

  # ============================================================
  # update_user_list
  # ============================================================

  test "describe_update_user_list returns the action description for the owner" do
    list = UserList.create!(creator: @user, owner: @user, name: "X")
    get "/lists/#{list.truncated_id}/actions/update_user_list", headers: @headers
    assert_response :success
    assert_includes response.body, "update_user_list"
  end

  test "describe_update_user_list 404s for a list the user cannot see (private, not owner)" do
    list = UserList.create!(creator: @other, owner: @other, name: "Hidden", visibility: "private")
    get "/lists/#{list.truncated_id}/actions/update_user_list", headers: @headers
    assert_response :not_found
  end

  test "describe_update_user_list 404s for an unknown id" do
    get "/lists/deadbeef/actions/update_user_list", headers: @headers
    assert_response :not_found
  end

  test "execute_update_user_list updates name, description, visibility for the owner" do
    list = UserList.create!(creator: @user, owner: @user, name: "Old", description: "old", visibility: "public")
    post "/lists/#{list.truncated_id}/actions/update_user_list",
         params: { name: "New", description: "new", visibility: "private" }.to_json,
         headers: @headers
    assert_response :success
    list.reload
    assert_equal "New", list.name
    assert_equal "new", list.description
    assert_equal "private", list.visibility
  end

  test "execute_update_user_list is a partial update — omitted params are left alone" do
    list = UserList.create!(creator: @user, owner: @user, name: "Keep", description: "keep desc", visibility: "public")
    post "/lists/#{list.truncated_id}/actions/update_user_list",
         params: { name: "Renamed" }.to_json,
         headers: @headers
    assert_response :success
    list.reload
    assert_equal "Renamed", list.name
    assert_equal "keep desc", list.description
    assert_equal "public", list.visibility
  end

  test "execute_update_user_list rejects updates to a primary list even for the owner" do
    primary = @user.primary_user_list_in!(@tenant)
    post "/lists/#{primary.truncated_id}/actions/update_user_list",
         params: { name: "Renamed", description: "new" }.to_json,
         headers: @headers
    assert_response :forbidden
    primary.reload
    assert_equal "tuned in", primary.name
  end

  test "execute_update_user_list rejects updates from a non-owner with 404 (existence-hiding)" do
    list = UserList.create!(creator: @other, owner: @other, name: "Theirs", visibility: "public")
    post "/lists/#{list.truncated_id}/actions/update_user_list",
         params: { name: "Hijacked" }.to_json,
         headers: @headers
    # Public visible to other collective members, but mutation is owner-only.
    # Non-owner mutation returns 403 (not 404 — the list is visible).
    assert_response :forbidden
    list.reload
    assert_equal "Theirs", list.name
  end

  test "execute_update_user_list 404s when the private list is not visible" do
    list = UserList.create!(creator: @other, owner: @other, name: "Hidden", visibility: "private")
    post "/lists/#{list.truncated_id}/actions/update_user_list",
         params: { name: "Hijacked" }.to_json,
         headers: @headers
    assert_response :not_found
  end

  test "execute_update_user_list rejects blank name with 422" do
    list = UserList.create!(creator: @user, owner: @user, name: "Original")
    post "/lists/#{list.truncated_id}/actions/update_user_list",
         params: { name: "" }.to_json,
         headers: @headers
    assert_response :unprocessable_entity
  end

  test "execute_update_user_list cannot change is_primary on a custom list" do
    list = UserList.create!(creator: @user, owner: @user, name: "Custom")
    post "/lists/#{list.truncated_id}/actions/update_user_list",
         params: { is_primary: true }.to_json,
         headers: @headers
    # Param is silently ignored: update succeeds, is_primary stays false.
    assert_response :success
    assert_equal false, list.reload.is_primary
  end

  # ============================================================
  # delete_user_list
  # ============================================================

  test "describe_delete_user_list returns the action description for the owner" do
    list = UserList.create!(creator: @user, owner: @user, name: "Goner")
    get "/lists/#{list.truncated_id}/actions/delete_user_list", headers: @headers
    assert_response :success
    assert_includes response.body, "delete_user_list"
  end

  test "describe_delete_user_list 404s on a private list the viewer cannot see" do
    list = UserList.create!(creator: @other, owner: @other, name: "Hidden", visibility: "private")
    get "/lists/#{list.truncated_id}/actions/delete_user_list", headers: @headers
    assert_response :not_found
  end

  test "execute_delete_user_list soft-deletes a custom list owned by the actor" do
    list = UserList.create!(creator: @user, owner: @user, name: "Goner")
    post "/lists/#{list.truncated_id}/actions/delete_user_list",
         params: {}.to_json,
         headers: @headers
    assert_response :success
    list.reload
    assert list.deleted?
  end

  test "execute_delete_user_list refuses to delete a primary list" do
    primary = @user.primary_user_list_in!(@tenant)
    post "/lists/#{primary.truncated_id}/actions/delete_user_list",
         params: {}.to_json,
         headers: @headers
    # The delete_user_list rule excludes primary lists, so the execute-time gate
    # denies it (403) — the same rule that hides the action from listings.
    assert_response :forbidden
    assert_not primary.reload.deleted?
  end

  test "execute_delete_user_list rejects non-owner with 403 (visible public list)" do
    list = UserList.create!(creator: @other, owner: @other, name: "Theirs", visibility: "public")
    post "/lists/#{list.truncated_id}/actions/delete_user_list",
         params: {}.to_json,
         headers: @headers
    assert_response :forbidden
    assert_not list.reload.deleted?
  end

  test "execute_delete_user_list 404s for a private list the actor cannot see" do
    list = UserList.create!(creator: @other, owner: @other, name: "Hidden", visibility: "private")
    post "/lists/#{list.truncated_id}/actions/delete_user_list",
         params: {}.to_json,
         headers: @headers
    assert_response :not_found
    assert_not list.reload.deleted?
  end

  # ============================================================
  # actions_index
  # ============================================================

  test "/lists/actions lists create_user_list" do
    get "/lists/actions", headers: @headers
    assert_response :success
    assert_includes response.body, "create_user_list"
  end

  test "/lists/:id/actions lists update + delete for the owner" do
    list = UserList.create!(creator: @user, owner: @user, name: "Mine")
    get "/lists/#{list.truncated_id}/actions", headers: @headers
    assert_response :success
    assert_includes response.body, "update_user_list"
    assert_includes response.body, "delete_user_list"
  end

  test "/lists/:id/actions hides update + delete on a list the user does not own" do
    list = UserList.create!(creator: @other, owner: @other, name: "Theirs", visibility: "public")
    get "/lists/#{list.truncated_id}/actions", headers: @headers
    assert_response :success
    assert_not_includes response.body, "update_user_list"
    assert_not_includes response.body, "delete_user_list"
  end
end
