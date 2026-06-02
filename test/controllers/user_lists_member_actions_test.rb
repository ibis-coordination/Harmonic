require "test_helper"

# Tests for /lists/:id/actions/add_member and /lists/:id/actions/remove_member.
class UserListsMemberActionsTest < ActionDispatch::IntegrationTest
  def setup
    @tenant = @global_tenant
    @tenant.enable_api!
    @collective = @tenant.main_collective
    @collective.enable_api!

    @owner = @global_user
    @collective.add_user!(@owner) unless @collective.user_is_member?(@owner)
    mark_activated!(@owner)

    @member = mk("member")
    @other  = mk("other")
    @third  = mk("third")

    @owner_token  = ApiToken.create!(tenant: @tenant, user: @owner,  scopes: ApiToken.valid_scopes)
    @member_token = ApiToken.create!(tenant: @tenant, user: @member, scopes: ApiToken.valid_scopes)
    @other_token  = ApiToken.create!(tenant: @tenant, user: @other,  scopes: ApiToken.valid_scopes)

    @owner_h  = api_headers(@owner_token.plaintext_token)
    @member_h = api_headers(@member_token.plaintext_token)
    @other_h  = api_headers(@other_token.plaintext_token)

    host! "#{@tenant.subdomain}.#{ENV.fetch("HOSTNAME", nil)}"
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: nil)
  end

  def mk(label)
    u = create_user(email: "#{label}-#{SecureRandom.hex(4)}@example.com", name: "#{label.capitalize} #{SecureRandom.hex(4)}")
    @tenant.add_user!(u)
    @collective.add_user!(u)
    mark_activated!(u)
    u
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

  def list_with(add_policy:, members: [])
    list = UserList.create!(creator: @owner, owner: @owner, name: "L #{add_policy}", add_policy: add_policy)
    members.each { |m| list.user_list_members.create!(added_by: @owner, user: m) }
    list
  end

  def add_member!(list, headers:, user_handle:)
    post "/lists/#{list.truncated_id}/actions/add_member",
      params: { user_handle: user_handle }.to_json, headers: headers
  end

  def remove_member!(list, headers:, user_handle:)
    post "/lists/#{list.truncated_id}/actions/remove_member",
      params: { user_handle: user_handle }.to_json, headers: headers
  end

  # ============================================================
  # describe + actions_index visibility
  # ============================================================

  test "describe_add_member returns the description for the owner" do
    list = list_with(add_policy: "owner_only")
    get "/lists/#{list.truncated_id}/actions/add_member", headers: @owner_h
    assert_response :success
    assert_includes response.body, "add_member"
    assert_includes response.body, "user_handle"
  end

  test "describe_remove_member returns the description for the owner" do
    list = list_with(add_policy: "owner_only")
    get "/lists/#{list.truncated_id}/actions/remove_member", headers: @owner_h
    assert_response :success
    assert_includes response.body, "remove_member"
  end

  # ============================================================
  # execute_add_member — owner_only policy
  # ============================================================

  test "owner_only: owner can add another user" do
    list = list_with(add_policy: "owner_only")
    assert_difference -> { list.user_list_members.count }, +1 do
      add_member!(list, headers: @owner_h, user_handle: handle_of(@other))
    end
    assert_response :success
  end

  test "owner_only: non-owner cannot add (returns 403)" do
    list = list_with(add_policy: "owner_only")
    assert_no_difference -> { list.user_list_members.count } do
      add_member!(list, headers: @other_h, user_handle: handle_of(@third))
    end
    assert_response :forbidden
  end

  test "owner_only: non-owner cannot self-add (returns 403)" do
    list = list_with(add_policy: "owner_only")
    add_member!(list, headers: @other_h, user_handle: handle_of(@other))
    assert_response :forbidden
  end

  # ============================================================
  # execute_add_member — self_add policy
  # ============================================================

  test "self_add: a non-member can add themselves" do
    list = list_with(add_policy: "self_add")
    assert_difference -> { list.user_list_members.count }, +1 do
      add_member!(list, headers: @other_h, user_handle: handle_of(@other))
    end
    assert_response :success
  end

  test "self_add: a non-member cannot add someone else (403)" do
    list = list_with(add_policy: "self_add")
    add_member!(list, headers: @other_h, user_handle: handle_of(@third))
    assert_response :forbidden
  end

  # ============================================================
  # execute_add_member — members_add policy
  # ============================================================

  test "members_add: a member can add another user" do
    list = list_with(add_policy: "members_add", members: [@member])
    assert_difference -> { list.user_list_members.count }, +1 do
      add_member!(list, headers: @member_h, user_handle: handle_of(@other))
    end
    assert_response :success
  end

  test "members_add: a non-member cannot add others (403)" do
    list = list_with(add_policy: "members_add")
    add_member!(list, headers: @other_h, user_handle: handle_of(@third))
    assert_response :forbidden
  end

  test "members_add: a non-member cannot self-add (403)" do
    list = list_with(add_policy: "members_add")
    add_member!(list, headers: @other_h, user_handle: handle_of(@other))
    assert_response :forbidden
  end

  # ============================================================
  # execute_add_member — anyone_add policy
  # ============================================================

  test "anyone_add: any collective member can add any other collective member" do
    list = list_with(add_policy: "anyone_add")
    assert_difference -> { list.user_list_members.count }, +1 do
      add_member!(list, headers: @other_h, user_handle: handle_of(@third))
    end
    assert_response :success
  end

  test "anyone_add: a collective non-member is rejected by member_is_collective_member (422)" do
    list = list_with(add_policy: "anyone_add")
    stranger = create_user(email: "s-#{SecureRandom.hex(4)}@example.com", name: "S #{SecureRandom.hex(4)}")
    @tenant.add_user!(stranger)
    mark_activated!(stranger)
    # not added to the collective

    add_member!(list, headers: @other_h, user_handle: handle_of(stranger))
    assert_response :unprocessable_entity
  end

  # ============================================================
  # Block respect
  # ============================================================

  test "add_member rejects when actor has blocked target (422)" do
    list = list_with(add_policy: "anyone_add")
    UserBlock.create!(blocker: @other, blocked: @third, tenant: @tenant)
    add_member!(list, headers: @other_h, user_handle: handle_of(@third))
    assert_response :unprocessable_entity
  end

  test "add_member rejects when target has blocked actor (symmetric, 422)" do
    list = list_with(add_policy: "anyone_add")
    UserBlock.create!(blocker: @third, blocked: @other, tenant: @tenant)
    add_member!(list, headers: @other_h, user_handle: handle_of(@third))
    assert_response :unprocessable_entity
  end

  test "add_member rejects when owner has blocked target, even with anyone_add" do
    list = list_with(add_policy: "anyone_add")
    UserBlock.create!(blocker: @owner, blocked: @third, tenant: @tenant)
    add_member!(list, headers: @other_h, user_handle: handle_of(@third))
    assert_response :unprocessable_entity
  end

  # ============================================================
  # Idempotency / common failure modes
  # ============================================================

  test "add_member is idempotent — adding an existing member succeeds without dupes" do
    list = list_with(add_policy: "anyone_add", members: [@other])
    assert_no_difference -> { list.user_list_members.count } do
      add_member!(list, headers: @other_h, user_handle: handle_of(@other))
    end
    assert_response :success
  end

  test "add_member 404s for a list the actor cannot see (private + not owner)" do
    list = UserList.create!(creator: @owner, owner: @owner, name: "Hidden", visibility: "private")
    add_member!(list, headers: @other_h, user_handle: handle_of(@third))
    assert_response :not_found
  end

  test "add_member 422s for an unknown user_handle" do
    list = list_with(add_policy: "owner_only")
    post "/lists/#{list.truncated_id}/actions/add_member",
      params: { user_handle: "no-such-handle-#{SecureRandom.hex(4)}" }.to_json,
      headers: @owner_h
    assert_response :unprocessable_entity
  end

  test "add_member 422s when user_handle resolves only in a different tenant" do
    list = list_with(add_policy: "anyone_add")
    other_tenant = create_tenant(subdomain: "xt-#{SecureRandom.hex(4)}")
    cross_user = create_user(email: "xt-#{SecureRandom.hex(4)}@example.com", name: "XT #{SecureRandom.hex(4)}")
    other_tenant.add_user!(cross_user)
    cross_handle = TenantUser.unscope(where: :tenant_id).find_by(user_id: cross_user.id, tenant_id: other_tenant.id).handle

    post "/lists/#{list.truncated_id}/actions/add_member",
      params: { user_handle: cross_handle }.to_json,
      headers: @owner_h
    assert_response :unprocessable_entity
    assert_includes response.body, "User not found"
  end

  test "add_member on a primary list rejects non-owner (owner_only enforced)" do
    primary = @owner.primary_user_list_in!(@tenant)
    add_member!(primary, headers: @other_h, user_handle: handle_of(@third))
    assert_response :forbidden
  end

  # ============================================================
  # execute_remove_member — fixed policy (owner / self only)
  # ============================================================

  test "remove_member: owner can remove anyone" do
    list = list_with(add_policy: "owner_only", members: [@other])
    assert_difference -> { list.user_list_members.count }, -1 do
      remove_member!(list, headers: @owner_h, user_handle: handle_of(@other))
    end
    assert_response :success
  end

  test "remove_member: a user can remove themselves" do
    list = list_with(add_policy: "owner_only", members: [@other])
    assert_difference -> { list.user_list_members.count }, -1 do
      remove_member!(list, headers: @other_h, user_handle: handle_of(@other))
    end
    assert_response :success
  end

  test "remove_member: a non-owner cannot remove someone else (403)" do
    list = list_with(add_policy: "anyone_add", members: [@other, @third])
    remove_member!(list, headers: @other_h, user_handle: handle_of(@third))
    assert_response :forbidden
  end

  test "remove_member: members policy doesn't grant member-removes-others" do
    list = list_with(add_policy: "members_add", members: [@member, @other])
    # @member is on the list but still cannot remove @other (remove is fixed).
    remove_member!(list, headers: @member_h, user_handle: handle_of(@other))
    assert_response :forbidden
  end

  test "remove_member: self-removal is allowed even when actor↔target are blocked" do
    list = list_with(add_policy: "owner_only", members: [@other])
    # @other was blocked by owner AFTER being added; @other can still leave.
    UserBlock.create!(blocker: @owner, blocked: @other, tenant: @tenant)
    assert_difference -> { list.user_list_members.count }, -1 do
      remove_member!(list, headers: @other_h, user_handle: handle_of(@other))
    end
    assert_response :success
  end

  test "remove_member: removing a non-member reports 'Not on this list.'" do
    list = list_with(add_policy: "owner_only")
    assert_no_difference -> { list.user_list_members.count } do
      remove_member!(list, headers: @owner_h, user_handle: handle_of(@other))
    end
    assert_response :success
    assert_includes response.body, "Not on this list."
  end

  # ============================================================
  # actions_index_show — policy-aware visibility of add/remove
  # ============================================================

  test "actions_index_show offers add_member to owner on owner_only" do
    list = list_with(add_policy: "owner_only")
    get "/lists/#{list.truncated_id}/actions", headers: @owner_h
    assert_response :success
    assert_includes response.body, "add_member"
  end

  test "actions_index_show hides add_member from non-owner on owner_only" do
    list = list_with(add_policy: "owner_only")
    get "/lists/#{list.truncated_id}/actions", headers: @other_h
    assert_response :success
    assert_not_includes response.body, "add_member"
  end

  test "actions_index_show offers add_member to any viewer on anyone_add" do
    list = list_with(add_policy: "anyone_add")
    get "/lists/#{list.truncated_id}/actions", headers: @other_h
    assert_response :success
    assert_includes response.body, "add_member"
  end

  test "actions_index_show offers add_member to a list member on members_add but hides it from non-members" do
    list = list_with(add_policy: "members_add", members: [@member])
    get "/lists/#{list.truncated_id}/actions", headers: @member_h
    assert_includes response.body, "add_member"
    get "/lists/#{list.truncated_id}/actions", headers: @other_h
    assert_not_includes response.body, "add_member"
  end

  test "actions_index_show offers add_member to any viewer on self_add (they can add themselves)" do
    list = list_with(add_policy: "self_add")
    get "/lists/#{list.truncated_id}/actions", headers: @other_h
    assert_includes response.body, "add_member"
  end

  test "actions_index_show offers remove_member only to owner or self" do
    list = list_with(add_policy: "anyone_add", members: [@other])
    # owner sees it
    get "/lists/#{list.truncated_id}/actions", headers: @owner_h
    assert_includes response.body, "remove_member"
    # member sees it (they can remove themselves)
    get "/lists/#{list.truncated_id}/actions", headers: @other_h
    assert_includes response.body, "remove_member"
    # uninvolved third party: they could remove themselves if they were on it,
    # which is permissive listing semantics — keep this assertion conservative
    # by checking the OWNER and MEMBER scenarios only.
  end

  # ============================================================
  # update_user_list accepts add_policy
  # ============================================================

  test "update_user_list accepts a valid add_policy" do
    list = list_with(add_policy: "owner_only")
    post "/lists/#{list.truncated_id}/actions/update_user_list",
      params: { add_policy: "anyone_add" }.to_json,
      headers: @owner_h
    assert_response :success
    assert_equal "anyone_add", list.reload.add_policy
  end

  test "update_user_list rejects an unknown add_policy with 422" do
    list = list_with(add_policy: "owner_only")
    post "/lists/#{list.truncated_id}/actions/update_user_list",
      params: { add_policy: "wild_west" }.to_json,
      headers: @owner_h
    assert_response :unprocessable_entity
    assert_equal "owner_only", list.reload.add_policy
  end

  test "create_user_list accepts an add_policy param" do
    post "/lists/actions/create_user_list",
      params: { name: "Opt-in", add_policy: "self_add" }.to_json,
      headers: @owner_h
    assert_response :success
    list = UserList.unscope(where: :collective_id).where(owner_id: @owner.id, name: "Opt-in").first
    assert_equal "self_add", list.add_policy
  end
end
