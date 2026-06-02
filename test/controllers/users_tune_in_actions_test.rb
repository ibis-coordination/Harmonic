require "test_helper"

# Tests for /u/:handle/actions/tune_in and tune_out — the "tune in" gesture
# that maintains the actor's primary UserList.
class UsersTuneInActionsTest < ActionDispatch::IntegrationTest
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

  # ---- describe_tune_in ----

  test "describe_tune_in returns the action description" do
    get "/u/#{handle_of(@target)}/actions/tune_in", headers: @headers
    assert_response :success
    assert is_markdown?
    assert_includes response.body, "tune_in"
  end

  test "describe_tune_in 404s for unknown handle" do
    get "/u/no-such-handle-#{SecureRandom.hex(4)}/actions/tune_in", headers: @headers
    assert_response :not_found
  end

  # ---- execute_tune_in ----

  test "execute_tune_in creates the actor's primary list and adds the target" do
    assert_difference -> { UserList.unscope(where: :collective_id).where(owner_id: @user.id, is_primary: true).count }, +1 do
      assert_difference -> { UserListMember.where(user_id: @target.id).count }, +1 do
        post "/u/#{handle_of(@target)}/actions/tune_in", params: {}.to_json, headers: @headers
      end
    end

    assert_response :success
    primary = UserList.unscope(where: :collective_id).find_by(owner_id: @user.id, is_primary: true)
    assert_includes primary.members, @target
  end

  test "execute_tune_in reuses an existing primary list" do
    @user.primary_user_list_in!(@tenant)
    assert_no_difference -> { UserList.unscope(where: :collective_id).where(owner_id: @user.id, is_primary: true).count } do
      post "/u/#{handle_of(@target)}/actions/tune_in", params: {}.to_json, headers: @headers
    end
    assert_response :success
  end

  test "execute_tune_in is idempotent — adding twice succeeds without error" do
    post "/u/#{handle_of(@target)}/actions/tune_in", params: {}.to_json, headers: @headers
    assert_response :success

    assert_no_difference -> { UserListMember.where(user_id: @target.id).count } do
      post "/u/#{handle_of(@target)}/actions/tune_in", params: {}.to_json, headers: @headers
    end
    assert_response :success
  end

  test "execute_tune_in rejects tuning in to yourself with 422" do
    post "/u/#{handle_of(@user)}/actions/tune_in", params: {}.to_json, headers: @headers
    assert_response :unprocessable_entity
    assert_includes response.body.downcase, "yourself"
  end

  test "execute_tune_in rejects when actor has blocked target" do
    UserBlock.create!(blocker: @user, blocked: @target, tenant: @tenant)
    post "/u/#{handle_of(@target)}/actions/tune_in", params: {}.to_json, headers: @headers
    assert_response :unprocessable_entity
    assert_includes response.body.downcase, "block"
  end

  test "execute_tune_in rejects when target has blocked actor (symmetric)" do
    UserBlock.create!(blocker: @target, blocked: @user, tenant: @tenant)
    post "/u/#{handle_of(@target)}/actions/tune_in", params: {}.to_json, headers: @headers
    assert_response :unprocessable_entity
    assert_includes response.body.downcase, "block"
  end

  test "execute_tune_in rejects when target is not a collective member" do
    stranger = create_user(email: "s-#{SecureRandom.hex(4)}@example.com", name: "S #{SecureRandom.hex(4)}")
    @tenant.add_user!(stranger)
    mark_activated!(stranger)
    # NOT added to @collective

    post "/u/#{handle_of(stranger)}/actions/tune_in", params: {}.to_json, headers: @headers
    assert_response :unprocessable_entity
    assert_includes response.body.downcase, "collective"
  end

  test "execute_tune_in 404s for unknown handle" do
    post "/u/no-such-handle-#{SecureRandom.hex(4)}/actions/tune_in", params: {}.to_json, headers: @headers
    assert_response :not_found
  end

  # ---- describe_tune_out ----

  test "describe_tune_out returns the action description" do
    get "/u/#{handle_of(@target)}/actions/tune_out", headers: @headers
    assert_response :success
    assert is_markdown?
    assert_includes response.body, "tune_out"
  end

  # ---- execute_tune_out ----

  test "execute_tune_out removes an existing membership" do
    # Seed: actor has primary with target on it
    post "/u/#{handle_of(@target)}/actions/tune_in", params: {}.to_json, headers: @headers
    assert_response :success

    assert_difference -> { UserListMember.where(user_id: @target.id).count }, -1 do
      post "/u/#{handle_of(@target)}/actions/tune_out", params: {}.to_json, headers: @headers
    end
    assert_response :success
    assert_includes response.body, "Tuned out."
  end

  test "execute_tune_out reports 'Not tuning in' when target was never a member" do
    @user.primary_user_list_in!(@tenant)
    assert_no_difference -> { UserListMember.where(user_id: @target.id).count } do
      post "/u/#{handle_of(@target)}/actions/tune_out", params: {}.to_json, headers: @headers
    end
    assert_response :success
    assert_includes response.body, "Not tuning in."
  end

  test "execute_tune_out reports 'Not tuning in' when actor has no primary list yet" do
    assert_no_difference -> { UserList.unscope(where: :collective_id).where(owner_id: @user.id).count } do
      post "/u/#{handle_of(@target)}/actions/tune_out", params: {}.to_json, headers: @headers
    end
    assert_response :success
    assert_includes response.body, "Not tuning in."
  end

  test "execute_tune_out 404s for unknown handle" do
    post "/u/no-such-handle-#{SecureRandom.hex(4)}/actions/tune_out", params: {}.to_json, headers: @headers
    assert_response :not_found
  end

  # ---- Tuning-in status line on the markdown profile ----

  test "markdown profile says 'You are tuning in to <name>' when target is on viewer's primary list" do
    # Seed the membership via the API so we don't have to deal with thread
    # scope in the test (the request middleware sets it for us).
    post "/u/#{handle_of(@target)}/actions/tune_in", params: {}.to_json, headers: @headers
    assert_response :success

    get "/u/#{handle_of(@target)}", headers: @headers
    assert_response :success
    assert_includes response.body, "You are _tuning in_ to #{@target.display_name}."
    assert_not_includes response.body, "_not tuned in_"
  end

  test "markdown profile says 'You are not tuned in to <name>' when target is not on viewer's primary list" do
    get "/u/#{handle_of(@target)}", headers: @headers
    assert_response :success
    assert_includes response.body, "You are _not tuned in_ to #{@target.display_name}."
    assert_not_includes response.body, "_tuning in_"
  end

  test "markdown profile omits the tuning-in line on your own profile" do
    get "/u/#{handle_of(@user)}", headers: @headers
    assert_response :success
    assert_not_includes response.body, "tuning in"
    assert_not_includes response.body, "tuned in"
  end

  # ---- Frontmatter visibility (own vs other profile) ----

  test "frontmatter on another user's profile lists tune_in and tune_out" do
    get "/u/#{handle_of(@target)}", headers: @headers
    assert_response :success
    # Actions block in frontmatter (between '---' fences)
    frontmatter = response.body.split("---").at(1).to_s
    assert_includes frontmatter, "tune_in"
    assert_includes frontmatter, "tune_out"
  end

  test "frontmatter on your own profile hides tune_in and tune_out" do
    get "/u/#{handle_of(@user)}", headers: @headers
    assert_response :success
    frontmatter = response.body.split("---").at(1).to_s
    assert_not_includes frontmatter, "tune_in"
    assert_not_includes frontmatter, "tune_out"
  end
end
