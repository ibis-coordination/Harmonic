require "test_helper"

# Tests for /u/:handle/actions/add_to_list and remove_from_list — the
# "add to list" gesture.
class UsersListsActionsTest < ActionDispatch::IntegrationTest
  def setup
    @tenant = @global_tenant
    @tenant.enable_api!
    @collective = @tenant.main_collective
    @collective.enable_api!
    @user = @global_user

    @target = create_user(email: "t-#{SecureRandom.hex(4)}@example.com", name: "T #{SecureRandom.hex(4)}")
    @tenant.add_user!(@target)
    @collective.add_user!(@target)
    mark_activated!(@user)
    mark_activated!(@target)

    @api_token       = ApiToken.create!(tenant: @tenant, user: @user,   scopes: ApiToken.valid_scopes)
    @target_token    = ApiToken.create!(tenant: @tenant, user: @target, scopes: ApiToken.valid_scopes)

    @headers        = api_headers(@api_token.plaintext_token)
    @target_headers = api_headers(@target_token.plaintext_token)

    host! "#{@tenant.subdomain}.#{ENV.fetch("HOSTNAME", nil)}"
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

  def handle_of(user)
    user.tenant_users.find_by(tenant_id: @tenant.id).handle
  end

  # ---- describe_add_to_list ----

  test "describe_add_to_list returns the action description" do
    get "/u/#{handle_of(@target)}/actions/add_to_list", headers: @headers
    assert_response :success
    assert is_markdown?
    assert_includes response.body, "add_to_list"
  end

  test "describe_add_to_list 404s for unknown handle" do
    get "/u/no-such-handle-#{SecureRandom.hex(4)}/actions/add_to_list", headers: @headers
    assert_response :not_found
  end

  # ---- execute_add_to_list ----

  test "execute_add_to_list creates the actor's primary list and adds the target" do
    assert_difference -> { UserList.unscope(where: :collective_id).where(owner_id: @user.id, is_primary: true).count }, +1 do
      assert_difference -> { UserListMember.where(user_id: @target.id).count }, +1 do
        post "/u/#{handle_of(@target)}/actions/add_to_list", params: {}.to_json, headers: @headers
      end
    end

    assert_response :success
    primary = UserList.unscope(where: :collective_id).find_by(owner_id: @user.id, is_primary: true)
    assert_includes primary.members, @target
  end

  test "execute_add_to_list reuses an existing primary list" do
    @user.primary_user_list_in!(@tenant)
    assert_no_difference -> { UserList.unscope(where: :collective_id).where(owner_id: @user.id, is_primary: true).count } do
      post "/u/#{handle_of(@target)}/actions/add_to_list", params: {}.to_json, headers: @headers
    end
    assert_response :success
  end

  test "execute_add_to_list is idempotent — adding twice succeeds without error" do
    post "/u/#{handle_of(@target)}/actions/add_to_list", params: {}.to_json, headers: @headers
    assert_response :success

    assert_no_difference -> { UserListMember.where(user_id: @target.id).count } do
      post "/u/#{handle_of(@target)}/actions/add_to_list", params: {}.to_json, headers: @headers
    end
    assert_response :success
  end

  test "execute_add_to_list rejects self-add with 422" do
    post "/u/#{handle_of(@user)}/actions/add_to_list", params: {}.to_json, headers: @headers
    assert_response :unprocessable_entity
    assert_includes response.body.downcase, "yourself"
  end

  test "execute_add_to_list rejects when actor has blocked target" do
    UserBlock.create!(blocker: @user, blocked: @target, tenant: @tenant)
    post "/u/#{handle_of(@target)}/actions/add_to_list", params: {}.to_json, headers: @headers
    assert_response :unprocessable_entity
    assert_includes response.body.downcase, "block"
  end

  test "execute_add_to_list rejects when target has blocked actor (symmetric)" do
    UserBlock.create!(blocker: @target, blocked: @user, tenant: @tenant)
    post "/u/#{handle_of(@target)}/actions/add_to_list", params: {}.to_json, headers: @headers
    assert_response :unprocessable_entity
    assert_includes response.body.downcase, "block"
  end

  test "execute_add_to_list rejects when target is not a collective member" do
    stranger = create_user(email: "s-#{SecureRandom.hex(4)}@example.com", name: "S #{SecureRandom.hex(4)}")
    @tenant.add_user!(stranger)
    mark_activated!(stranger)
    # NOT added to @collective

    post "/u/#{handle_of(stranger)}/actions/add_to_list", params: {}.to_json, headers: @headers
    assert_response :unprocessable_entity
    assert_includes response.body.downcase, "collective"
  end

  test "execute_add_to_list 404s for unknown handle" do
    post "/u/no-such-handle-#{SecureRandom.hex(4)}/actions/add_to_list", params: {}.to_json, headers: @headers
    assert_response :not_found
  end

  # ---- describe_remove_from_list ----

  test "describe_remove_from_list returns the action description" do
    get "/u/#{handle_of(@target)}/actions/remove_from_list", headers: @headers
    assert_response :success
    assert is_markdown?
    assert_includes response.body, "remove_from_list"
  end

  # ---- execute_remove_from_list ----

  test "execute_remove_from_list removes an existing membership" do
    # Seed: actor has primary with target on it
    post "/u/#{handle_of(@target)}/actions/add_to_list", params: {}.to_json, headers: @headers
    assert_response :success

    assert_difference -> { UserListMember.where(user_id: @target.id).count }, -1 do
      post "/u/#{handle_of(@target)}/actions/remove_from_list", params: {}.to_json, headers: @headers
    end
    assert_response :success
    assert_includes response.body, "Removed from your list."
  end

  test "execute_remove_from_list reports 'Not on your list' when target was never a member" do
    @user.primary_user_list_in!(@tenant)
    assert_no_difference -> { UserListMember.where(user_id: @target.id).count } do
      post "/u/#{handle_of(@target)}/actions/remove_from_list", params: {}.to_json, headers: @headers
    end
    assert_response :success
    assert_includes response.body, "Not on your list."
  end

  test "execute_remove_from_list reports 'Not on your list' when actor has no primary list yet" do
    assert_no_difference -> { UserList.unscope(where: :collective_id).where(owner_id: @user.id).count } do
      post "/u/#{handle_of(@target)}/actions/remove_from_list", params: {}.to_json, headers: @headers
    end
    assert_response :success
    assert_includes response.body, "Not on your list."
  end

  test "execute_remove_from_list 404s for unknown handle" do
    post "/u/no-such-handle-#{SecureRandom.hex(4)}/actions/remove_from_list", params: {}.to_json, headers: @headers
    assert_response :not_found
  end

  # ---- Frontmatter visibility (own vs other profile) ----

  test "frontmatter on another user's profile lists add_to_list and remove_from_list" do
    get "/u/#{handle_of(@target)}", headers: @headers
    assert_response :success
    # Actions block in frontmatter (between '---' fences)
    frontmatter = response.body.split("---").at(1).to_s
    assert_includes frontmatter, "add_to_list"
    assert_includes frontmatter, "remove_from_list"
  end

  test "frontmatter on your own profile hides add_to_list and remove_from_list" do
    get "/u/#{handle_of(@user)}", headers: @headers
    assert_response :success
    frontmatter = response.body.split("---").at(1).to_s
    assert_not_includes frontmatter, "add_to_list"
    assert_not_includes frontmatter, "remove_from_list"
  end
end
