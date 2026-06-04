require "test_helper"

# Tests for the markdown show / index pages:
#   GET /lists/:list_id
#   GET /u/:handle/lists
class UserListsShowTest < ActionDispatch::IntegrationTest
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

    @stranger = create_user(email: "s-#{SecureRandom.hex(4)}@example.com", name: "S #{SecureRandom.hex(4)}")
    @tenant.add_user!(@stranger)
    mark_activated!(@stranger)
    # NOT added to @collective.

    @api_token      = ApiToken.create!(tenant: @tenant, user: @user,     scopes: ApiToken.valid_scopes)
    @other_token    = ApiToken.create!(tenant: @tenant, user: @other,    scopes: ApiToken.valid_scopes)
    @stranger_token = ApiToken.create!(tenant: @tenant, user: @stranger, scopes: ApiToken.valid_scopes)

    @headers          = api_headers(@api_token.plaintext_token)
    @other_headers    = api_headers(@other_token.plaintext_token)
    @stranger_headers = api_headers(@stranger_token.plaintext_token)

    host! "#{@tenant.subdomain}.#{ENV.fetch("HOSTNAME", nil)}"

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

  def handle_of(user)
    user.tenant_users.find_by(tenant_id: @tenant.id).handle
  end

  # ============================================================
  # GET /lists/:list_id (show)
  # ============================================================

  test "show renders a public list including its members" do
    list = UserList.create!(creator: @user, owner: @user, name: "Friends", description: "the good ones")
    list.user_list_members.create!(added_by: @user, user: @other)

    get "/lists/#{list.truncated_id}", headers: @headers
    assert_response :success
    assert_includes response.body, "Friends"
    assert_includes response.body, "the good ones"
    assert_includes response.body, handle_of(@other)
  end

  test "show 404s for an unknown list id" do
    get "/lists/deadbeef", headers: @headers
    assert_response :not_found
  end

  test "show 404s for a soft-deleted list" do
    list = UserList.create!(creator: @user, owner: @user, name: "Goner")
    list.soft_delete!(by: @user)

    get "/lists/#{list.truncated_id}", headers: @headers
    assert_response :not_found
  end

  test "show returns 404 for a private list to non-owner (existence-hidden)" do
    list = UserList.create!(creator: @other, owner: @other, name: "Hidden", visibility: "private")

    get "/lists/#{list.truncated_id}", headers: @headers
    assert_response :not_found
  end

  test "show frontmatter omits delete_user_list for a primary list (cannot be deleted)" do
    primary = @user.primary_user_list_in!(@tenant)
    get "/lists/#{primary.truncated_id}", headers: @headers
    assert_response :success
    frontmatter = response.body.split("---").at(1).to_s
    assert_includes frontmatter, "update_user_list"
    assert_not_includes frontmatter, "delete_user_list"
  end

  test "show frontmatter omits update/delete on a list the viewer doesn't own (visible public)" do
    list = UserList.create!(creator: @other, owner: @other, name: "Theirs")
    get "/lists/#{list.truncated_id}", headers: @headers
    assert_response :success
    frontmatter = response.body.split("---").at(1).to_s
    assert_not_includes frontmatter, "update_user_list"
    assert_not_includes frontmatter, "delete_user_list"
  end

  test "show returns 200 for the owner viewing their own private list" do
    list = UserList.create!(creator: @other, owner: @other, name: "Hidden", visibility: "private")

    get "/lists/#{list.truncated_id}", headers: @other_headers
    assert_response :success
    assert_includes response.body, "Hidden"
  end

  test "show markdown includes an Activity section listing content authored by members" do
    list = UserList.create!(creator: @user, owner: @user, name: "Feedy")
    list.user_list_members.create!(added_by: @user, user: @other)

    Note.create!(
      tenant: @tenant, collective: @collective, created_by: @other,
      text: "markdown feed note from a member",
      deadline: Time.current + 1.week,
    )

    get "/lists/#{list.truncated_id}", headers: @headers
    assert_response :success
    assert_includes response.body, "## Activity"
    assert_includes response.body, "markdown feed note from a member"
  end

  test "show markdown activity section excludes content from blocked members" do
    list = UserList.create!(creator: @user, owner: @user, name: "Feedy")
    list.user_list_members.create!(added_by: @user, user: @other)
    UserBlock.create!(blocker: @user, blocked: @other, tenant: @tenant)

    Note.create!(
      tenant: @tenant, collective: @collective, created_by: @other,
      text: "markdown post from blocked stale member",
      deadline: Time.current + 1.week,
    )

    get "/lists/#{list.truncated_id}", headers: @headers
    assert_response :success
    assert_not_includes response.body, "markdown post from blocked stale member"
  end

  test "show 404s for a stranger (not a collective member) viewing a public list" do
    list = UserList.create!(creator: @user, owner: @user, name: "Public")

    get "/lists/#{list.truncated_id}", headers: @stranger_headers
    assert_response :not_found
  end

  # ============================================================
  # GET /u/:handle/lists (index)
  # ============================================================

  test "index lists primary first, then custom lists, owned by the user" do
    primary = @user.primary_user_list_in!(@tenant)
    UserList.create!(creator: @user, owner: @user, name: "A")
    UserList.create!(creator: @user, owner: @user, name: "B")

    get "/u/#{handle_of(@user)}/lists", headers: @headers
    assert_response :success
    body = response.body
    assert_includes body, primary.path
    assert_includes body, "tuned in"
    assert_includes body, "A"
    assert_includes body, "B"
    assert body.index(primary.path) < body.index("A")
    assert body.index("tuned in") < body.index("A")
  end

  test "index hides private lists from non-owners" do
    UserList.create!(creator: @other, owner: @other, name: "Visible Public", visibility: "public")
    UserList.create!(creator: @other, owner: @other, name: "Hidden Private", visibility: "private")

    get "/u/#{handle_of(@other)}/lists", headers: @headers
    assert_response :success
    assert_includes response.body, "Visible Public"
    assert_not_includes response.body, "Hidden Private"
  end

  test "index shows private lists to the owner" do
    UserList.create!(creator: @other, owner: @other, name: "Hidden Private", visibility: "private")

    get "/u/#{handle_of(@other)}/lists", headers: @other_headers
    assert_response :success
    assert_includes response.body, "Hidden Private"
  end

  test "index excludes soft-deleted lists" do
    deleted = UserList.create!(creator: @user, owner: @user, name: "Goner")
    deleted.soft_delete!(by: @user)

    get "/u/#{handle_of(@user)}/lists", headers: @headers
    assert_response :success
    assert_not_includes response.body, "Goner"
  end

  test "index 404s for an unknown handle" do
    get "/u/no-such-handle-#{SecureRandom.hex(4)}/lists", headers: @headers
    assert_response :not_found
  end
end
