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
    @collective.add_user!(@user) unless @collective.user_is_member?(@user)

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

  def anon_json_headers
    { "Accept" => "application/json", "Content-Type" => "application/json" }
  end

  def anon_md_headers
    { "Accept" => "text/markdown", "Content-Type" => "application/json" }
  end

  # ---- authentication ----
  #
  # Unauthenticated requests must never mutate state. For JSON the contract
  # is 401; for markdown the global before-action redirects to /login.

  test "execute_tune_in does not create a membership without authentication (json)" do
    assert_no_difference -> { UserListMember.count } do
      post "/u/#{handle_of(@target)}/actions/tune_in", params: {}.to_json, headers: anon_json_headers
    end
    assert_response :unauthorized
  end

  test "execute_tune_out does not destroy a membership without authentication (json)" do
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    @user.primary_user_list_in!(@tenant).user_list_members.create!(user: @target, added_by: @user)
    assert_no_difference -> { UserListMember.count } do
      post "/u/#{handle_of(@target)}/actions/tune_out", params: {}.to_json, headers: anon_json_headers
    end
    assert_response :unauthorized
  end

  test "execute_tune_in redirects to /login without authentication (markdown)" do
    assert_no_difference -> { UserListMember.count } do
      post "/u/#{handle_of(@target)}/actions/tune_in", params: {}.to_json, headers: anon_md_headers
    end
    assert_response :redirect
    assert_match %r{/login}, response.location
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

  test "execute_tune_in creates a tune_in notification for the target" do
    assert_difference -> { Notification.where(notification_type: "tune_in").count }, +1 do
      post "/u/#{handle_of(@target)}/actions/tune_in", params: {}.to_json, headers: @headers
    end
    notification = Notification.where(notification_type: "tune_in").last
    assert_equal "#{@user.display_name} tuned in to you", notification.title
    recipient = notification.notification_recipients.first
    assert_equal @target.id, recipient.user_id
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

  test "execute_tune_out reports 'Not tuned in' when target was never a member" do
    @user.primary_user_list_in!(@tenant)
    assert_no_difference -> { UserListMember.where(user_id: @target.id).count } do
      post "/u/#{handle_of(@target)}/actions/tune_out", params: {}.to_json, headers: @headers
    end
    assert_response :success
    assert_includes response.body, "Not tuned in."
  end

  test "execute_tune_out reports 'Not tuned in' when actor has no primary list yet" do
    assert_no_difference -> { UserList.unscope(where: :collective_id).where(owner_id: @user.id).count } do
      post "/u/#{handle_of(@target)}/actions/tune_out", params: {}.to_json, headers: @headers
    end
    assert_response :success
    assert_includes response.body, "Not tuned in."
  end

  test "execute_tune_out 404s for unknown handle" do
    post "/u/no-such-handle-#{SecureRandom.hex(4)}/actions/tune_out", params: {}.to_json, headers: @headers
    assert_response :not_found
  end

  # ---- Tuning-in status line on the markdown profile ----

  # The four states of tuning-in between viewer (V = @user) and profile
  # user (P = @target). Seeded via the API so the request middleware sets
  # thread scope for us.
  #
  #   V→P  P→V  status
  #   ✗    ✗    "You are _not tuned in_ to P."
  #   ✓    ✗    "You are _tuned in_ to P."
  #   ✗    ✓    "P is _tuned in_ to you."
  #   ✓    ✓    "You and P are _mutually tuned in_ to each other."

  test "markdown profile: neither direction — 'not tuned in'" do
    get "/u/#{handle_of(@target)}", headers: @headers
    assert_response :success
    assert_includes response.body, "You are _not tuned in_ to #{@target.display_name}."
    assert_not_includes response.body, "_mutually tuned in_"
  end

  test "markdown profile: viewer tunes in to target only — 'You are tuned in to P'" do
    post "/u/#{handle_of(@target)}/actions/tune_in", params: {}.to_json, headers: @headers
    assert_response :success

    get "/u/#{handle_of(@target)}", headers: @headers
    assert_response :success
    assert_includes response.body, "You are _tuned in_ to #{@target.display_name}."
    assert_not_includes response.body, "_not tuned in_"
    assert_not_includes response.body, "_mutually tuned in_"
  end

  test "markdown profile: target tunes in to viewer only — 'P is tuned in to you'" do
    # Target tunes in to viewer (using @target_headers).
    post "/u/#{handle_of(@user)}/actions/tune_in", params: {}.to_json, headers: @target_headers
    assert_response :success

    get "/u/#{handle_of(@target)}", headers: @headers
    assert_response :success
    assert_includes response.body, "#{@target.display_name} is _tuned in_ to you."
    assert_not_includes response.body, "_not tuned in_"
    assert_not_includes response.body, "_mutually tuned in_"
  end

  test "markdown profile: both directions — 'mutually tuned in'" do
    post "/u/#{handle_of(@target)}/actions/tune_in", params: {}.to_json, headers: @headers
    assert_response :success
    post "/u/#{handle_of(@user)}/actions/tune_in",   params: {}.to_json, headers: @target_headers
    assert_response :success

    get "/u/#{handle_of(@target)}", headers: @headers
    assert_response :success
    assert_includes response.body, "You and #{@target.display_name} are _mutually tuned in_ to each other."
    # The one-way phrases should NOT also appear.
    assert_not_includes response.body, "You are _tuned in_ to #{@target.display_name}."
    assert_not_includes response.body, "#{@target.display_name} is _tuned in_ to you."
    assert_not_includes response.body, "_not tuned in_"
  end

  test "markdown profile omits the tuned-in line on your own profile" do
    get "/u/#{handle_of(@user)}", headers: @headers
    assert_response :success
    assert_not_includes response.body, "tuned in"
    assert_not_includes response.body, "mutually"
  end

  # ---- Block messages on profile (replace tune-in line + frontmatter) ----

  test "markdown profile: viewer has blocked the target — shows 'You have blocked' and omits tune-in" do
    UserBlock.create!(blocker: @user, blocked: @target, tenant: @tenant)
    get "/u/#{handle_of(@target)}", headers: @headers
    assert_response :success
    assert_includes response.body, "You have blocked #{@target.display_name}."
    assert_not_includes response.body, "tuned in"
    frontmatter = response.body.split("---").at(1).to_s
    assert_not_includes frontmatter, "tune_in"
    assert_not_includes frontmatter, "tune_out"
  end

  test "markdown profile: viewer blocked by the target — shows 'has blocked you' and omits tune-in" do
    UserBlock.create!(blocker: @target, blocked: @user, tenant: @tenant)
    get "/u/#{handle_of(@target)}", headers: @headers
    assert_response :success
    assert_includes response.body, "#{@target.display_name} has blocked you."
    assert_not_includes response.body, "tuned in"
    frontmatter = response.body.split("---").at(1).to_s
    assert_not_includes frontmatter, "tune_in"
    assert_not_includes frontmatter, "tune_out"
  end

  test "markdown profile: blocked profile is mostly empty — no Common Collectives, Social Proximity, or Recent Activity sections" do
    other_collective = Collective.create!(
      tenant: @tenant, name: "Common", handle: "common-#{SecureRandom.hex(4)}",
      collective_type: "standard", created_by: @user, updated_by: @user
    )
    other_collective.add_user!(@user)
    other_collective.add_user!(@target)

    UserBlock.create!(blocker: @user, blocked: @target, tenant: @tenant)
    get "/u/#{handle_of(@target)}", headers: @headers
    assert_response :success

    assert_not_includes response.body, "## Common Collectives"
    assert_not_includes response.body, "## Social Proximity"
    assert_not_includes response.body, "## Recent Activity"
    assert_not_includes response.body, "common collective"
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
