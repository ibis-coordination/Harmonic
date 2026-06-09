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

  test "edit: returns 403 for the primary list (not editable)" do
    primary = @user.primary_user_list_in!(@tenant)
    sign_in_as(@user, tenant: @tenant)
    get "/lists/#{primary.truncated_id}/edit"
    assert_response :forbidden
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

  test "show HTML: primary list owner does not see Edit button" do
    primary = @user.primary_user_list_in!(@tenant)
    sign_in_as(@user, tenant: @tenant)
    get "/lists/#{primary.truncated_id}"
    assert_response :success
    assert_select "a[href=?]", "/lists/#{primary.truncated_id}/edit", count: 0
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

  test "show HTML: exposes the list's id to the header search bar for auto-prefill" do
    list = UserList.create!(creator: @user, owner: @user, name: "Prefill")
    sign_in_as(@user, tenant: @tenant)
    get "/lists/#{list.truncated_id}"
    assert_response :success
    assert_select "[data-controller~='header-search'][data-header-search-list-id-value=?]", list.truncated_id
  end

  test "show HTML: page exposes Activity and Members tabs (Activity default-active)" do
    list = UserList.create!(creator: @user, owner: @user, name: "Tabbed")
    sign_in_as(@user, tenant: @tenant)
    get "/lists/#{list.truncated_id}"
    assert_response :success
    assert_select "nav.pulse-tabs a", text: /Activity/
    assert_select "nav.pulse-tabs a", text: /Members/
    # Activity is the default-active tab; aria-current set to "page" indicates the active one.
    assert_select "nav.pulse-tabs a[aria-current='page']", text: /Activity/
  end

  test "show HTML: ?tab=members marks the Members tab active and renders the member list" do
    list = UserList.create!(creator: @user, owner: @user, name: "Tabbed")
    list.user_list_members.create!(added_by: @user, user: @other)
    sign_in_as(@user, tenant: @tenant)
    get "/lists/#{list.truncated_id}?tab=members"
    assert_response :success
    assert_select "nav.pulse-tabs a[aria-current='page']", text: /Members/
    assert_select ".pulse-list-members a", text: /#{Regexp.escape(@other.display_name)}/
  end

  test "show HTML: self_add list shows a Join button (not a handle input) for a non-owner non-member" do
    list = UserList.create!(creator: @user, owner: @user, name: "Self-add list", add_policy: "self_add")
    sign_in_as(@other, tenant: @tenant)
    get "/lists/#{list.truncated_id}?tab=members"
    assert_response :success
    # No handle input for the non-owner — Join button only.
    assert_select "input[type='text'][name='user_handle']", count: 0
    assert_select "form[action=?] button", "/lists/#{list.truncated_id}/actions/join_list", text: /Join/
  end

  test "show HTML: self_add list shows nothing add-related for a non-owner who is already a member" do
    list = UserList.create!(creator: @user, owner: @user, name: "Self-add list", add_policy: "self_add")
    list.user_list_members.create!(added_by: @other, user: @other)
    sign_in_as(@other, tenant: @tenant)
    get "/lists/#{list.truncated_id}?tab=members"
    assert_response :success
    assert_select "input[type='text'][name='user_handle']", count: 0
    assert_select "form[action=?] button", "/lists/#{list.truncated_id}/actions/join_list", text: /Join/, count: 0
  end

  test "show HTML: self_add list shows the owner the add-anyone form with a policy hint mentioning self-add" do
    list = UserList.create!(creator: @user, owner: @user, name: "Self-add list", add_policy: "self_add")
    sign_in_as(@user, tenant: @tenant)
    get "/lists/#{list.truncated_id}?tab=members"
    assert_response :success
    assert_select "input[type='text'][name='user_handle']", count: 1
    assert_match(/others can add themselves/i, response.body)
  end

  test "show HTML: owner_only list shows the owner the add-anyone form and others nothing" do
    list = UserList.create!(creator: @user, owner: @user, name: "Owner-only", add_policy: "owner_only")
    # Owner sees the form.
    sign_in_as(@user, tenant: @tenant)
    get "/lists/#{list.truncated_id}?tab=members"
    assert_response :success
    assert_select "input[type='text'][name='user_handle']", count: 1
    # Non-owner sees nothing.
    sign_in_as(@other, tenant: @tenant)
    get "/lists/#{list.truncated_id}?tab=members"
    assert_response :success
    assert_select "input[type='text'][name='user_handle']", count: 0
    assert_select "form[action=?]", "/lists/#{list.truncated_id}/actions/add_member_to_list", count: 0
  end

  test "show HTML: Activity tab shows content authored by list members" do
    list = UserList.create!(creator: @user, owner: @user, name: "Feedy")
    list.user_list_members.create!(added_by: @user, user: @other)

    Note.create!(
      tenant: @tenant, collective: @collective, created_by: @other,
      text: "post by a member on the feed tab",
      deadline: Time.current + 1.week,
    )

    sign_in_as(@user, tenant: @tenant)
    get "/lists/#{list.truncated_id}"
    assert_response :success
    assert_includes response.body, "post by a member on the feed tab"
  end

  test "show HTML: Activity tab hides content from blocked authors (defense in depth)" do
    list = UserList.create!(creator: @user, owner: @user, name: "Feedy")
    list.user_list_members.create!(added_by: @user, user: @other)

    # Block @other and bypass-validate a stale tune-in-style membership across
    # the block. Defense in depth: even though block-cleanup removes new memberships,
    # the list-feed scope should still exclude blocked authors.
    UserBlock.create!(blocker: @user, blocked: @other, tenant: @tenant)
    Note.create!(
      tenant: @tenant, collective: @collective, created_by: @other,
      text: "post by a blocked stale member",
      deadline: Time.current + 1.week,
    )

    sign_in_as(@user, tenant: @tenant)
    get "/lists/#{list.truncated_id}"
    assert_response :success
    assert_not_includes response.body, "post by a blocked stale member"
  end

  test "show HTML: Activity tab shows empty-state when no member content yet" do
    list = UserList.create!(creator: @user, owner: @user, name: "Empty Feed List")
    sign_in_as(@user, tenant: @tenant)
    get "/lists/#{list.truncated_id}"
    assert_response :success
    assert_match(/No recent activity from members of this list/i, response.body)
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

  test "profile HTML: shows 'Tuned in to you' badge when target tunes in to viewer" do
    # @other tunes in to @user — viewer (@user) should see the badge on @other's profile.
    other_primary = @other.primary_user_list_in!(@tenant)
    other_primary.user_list_members.create!(added_by: @other, user: @user)
    sign_in_as(@user, tenant: @tenant)
    get "/u/#{@other.handle}"
    assert_response :success
    assert_select ".pulse-tuning-in-to-you-badge", text: /Tuned in to you/
  end

  test "profile HTML: omits 'Tuned in to you' badge when target does NOT tune in to viewer" do
    sign_in_as(@user, tenant: @tenant)
    get "/u/#{@other.handle}"
    assert_response :success
    assert_select ".pulse-tuning-in-to-you-badge", count: 0
  end

  test "profile HTML: header shows a mutuals count linking to /u/:handle/mutuals" do
    # Establish a mutual: @user ↔ @other.
    @user.primary_user_list_in!(@tenant).user_list_members.create!(added_by: @user, user: @other)
    @other.primary_user_list_in!(@tenant).user_list_members.create!(added_by: @other, user: @user)

    sign_in_as(@user, tenant: @tenant)
    get "/u/#{@other.handle}"
    assert_response :success
    assert_select "a[href=?]", "/u/#{@other.handle}/mutuals", text: /1 mutual\b/
    assert_match(/has\s+1\s+mutual\b/, css_select(".pulse-user-mutuals-line").first.text)
  end

  test "profile HTML: header still shows a mutuals link when count is 0" do
    sign_in_as(@user, tenant: @tenant)
    get "/u/#{@other.handle}"
    assert_response :success
    assert_select "a[href=?]", "/u/#{@other.handle}/mutuals", text: /0 mutuals/
    assert_match(/has\s+0\s+mutuals/, css_select(".pulse-user-mutuals-line").first.text)
  end

  test "profile HTML: shows 'N mutuals in common' count when viewer and target share mutuals" do
    third = create_user(email: "third-#{SecureRandom.hex(4)}@example.com", name: "Third Bridge")
    @tenant.add_user!(third)
    @collective.add_user!(third)
    # Viewer (@user) ↔ third are mutuals.
    @user.primary_user_list_in!(@tenant).user_list_members.create!(added_by: @user, user: third)
    third.primary_user_list_in!(@tenant).user_list_members.create!(added_by: third, user: @user)
    # Target (@other) ↔ third are mutuals.
    @other.primary_user_list_in!(@tenant).user_list_members.create!(added_by: @other, user: third)
    third.primary_user_list_in!(@tenant).user_list_members.create!(added_by: third, user: @other)

    sign_in_as(@user, tenant: @tenant)
    get "/u/#{@other.handle}"
    assert_response :success
    assert_select ".pulse-user-mutuals-line", text: /\(1 in common\)/
  end

  test "profile HTML: 'mutuals in common' line is hidden on your own profile" do
    sign_in_as(@user, tenant: @tenant)
    get "/u/#{@user.handle}"
    assert_response :success
    assert_select ".pulse-user-mutuals-line", text: /in common/, count: 0
  end

  test "profile HTML: 'mutuals in common' count includes the bridge user even when the viewer has blocked them" do
    third = create_user(email: "third-#{SecureRandom.hex(4)}@example.com", name: "Third Bridge")
    @tenant.add_user!(third)
    @collective.add_user!(third)
    # Block first so the after_create callback has nothing to clean,
    # then bypass validation to insert the mutual on both sides.
    UserBlock.create!(blocker: @user, blocked: third, tenant: @tenant)
    [
      [@user, third], [third, @user], [@other, third], [third, @other],
    ].each do |owner, member|
      m = owner.primary_user_list_in!(@tenant).user_list_members.new(added_by: owner, user: member)
      m.save(validate: false)
    end

    sign_in_as(@user, tenant: @tenant)
    get "/u/#{@other.handle}"
    assert_response :success
    assert_select ".pulse-user-mutuals-line", text: /\(1 in common\)/
  end

  test "mutuals page redirects anonymous viewers to /login" do
    get "/u/#{@other.handle}/mutuals"
    assert_response :redirect
    assert_match %r{/login}, response.location
  end

  test "mutuals page markdown renders for a profile with mutuals" do
    @user.primary_user_list_in!(@tenant).user_list_members.create!(added_by: @user, user: @other)
    @other.primary_user_list_in!(@tenant).user_list_members.create!(added_by: @other, user: @user)
    sign_in_as(@user, tenant: @tenant)
    get "/u/#{@other.handle}/mutuals", headers: { "Accept" => "text/markdown" }
    assert_response :success
    assert_match(/Mutually tuned in|Mutuals/, response.body)
    assert_match(/@#{@user.handle}/, response.body)
  end

  test "mutuals page markdown renders the empty state" do
    sign_in_as(@user, tenant: @tenant)
    get "/u/#{@other.handle}/mutuals", headers: { "Accept" => "text/markdown" }
    assert_response :success
    assert_match(/No mutuals/i, response.body)
  end

  test "mutuals page HTML: lists the mutuals as profile cards" do
    @user.primary_user_list_in!(@tenant).user_list_members.create!(added_by: @user, user: @other)
    @other.primary_user_list_in!(@tenant).user_list_members.create!(added_by: @other, user: @user)

    sign_in_as(@user, tenant: @tenant)
    get "/u/#{@other.handle}/mutuals"
    assert_response :success
    assert_select "h1", text: /Mutuals|Mutually tuned in/
    assert_select ".pulse-list-members a", text: /#{Regexp.escape(@user.display_name)}/
  end

  test "mutuals page HTML: empty-state when the user has no mutuals" do
    sign_in_as(@user, tenant: @tenant)
    get "/u/#{@other.handle}/mutuals"
    assert_response :success
    assert_match(/No mutuals/i, response.body)
  end

  test "mutuals page HTML: ?filter=common limits the list to mutuals shared with the viewer" do
    bridge = create_user(email: "br-#{SecureRandom.hex(4)}@example.com", name: "Bridge Mutual")
    only_target = create_user(email: "ot-#{SecureRandom.hex(4)}@example.com", name: "TargetOnly Mutual")
    @tenant.add_user!(bridge)
    @tenant.add_user!(only_target)
    @collective.add_user!(bridge)
    @collective.add_user!(only_target)

    # bridge is mutual with both viewer (@user) and target (@other).
    @user.primary_user_list_in!(@tenant).user_list_members.create!(added_by: @user, user: bridge)
    bridge.primary_user_list_in!(@tenant).user_list_members.create!(added_by: bridge, user: @user)
    @other.primary_user_list_in!(@tenant).user_list_members.create!(added_by: @other, user: bridge)
    bridge.primary_user_list_in!(@tenant).user_list_members.create!(added_by: bridge, user: @other)
    # only_target is mutual with target only.
    @other.primary_user_list_in!(@tenant).user_list_members.create!(added_by: @other, user: only_target)
    only_target.primary_user_list_in!(@tenant).user_list_members.create!(added_by: only_target, user: @other)

    sign_in_as(@user, tenant: @tenant)

    # Without the filter — both bridge and only_target appear.
    get "/u/#{@other.handle}/mutuals"
    assert_response :success
    assert_select ".pulse-list-members a", text: /Bridge Mutual/
    assert_select ".pulse-list-members a", text: /TargetOnly Mutual/

    # With ?filter=common — only the bridge appears.
    get "/u/#{@other.handle}/mutuals?filter=common"
    assert_response :success
    assert_select ".pulse-list-members a", text: /Bridge Mutual/
    assert_select ".pulse-list-members a", text: /TargetOnly Mutual/, count: 0
  end

  test "mutuals page HTML: ?filter=common heading and 'show all' affordance" do
    sign_in_as(@user, tenant: @tenant)
    get "/u/#{@other.handle}/mutuals?filter=common"
    assert_response :success
    assert_select "h1", text: /in common with you/i
    assert_select "a[href=?]", "/u/#{@other.handle}/mutuals", text: /show all/i
  end

  test "mutuals page HTML: ?filter=common empty-state copy mentions 'common'" do
    sign_in_as(@user, tenant: @tenant)
    get "/u/#{@other.handle}/mutuals?filter=common"
    assert_response :success
    assert_match(/No common mutuals yet/, response.body)
  end

  test "mutuals page HTML: ?filter=common on your own profile falls back to full list" do
    # Self-view: viewer ∩ self = viewer's own mutuals, same as the unfiltered list.
    @user.primary_user_list_in!(@tenant).user_list_members.create!(added_by: @user, user: @other)
    @other.primary_user_list_in!(@tenant).user_list_members.create!(added_by: @other, user: @user)

    sign_in_as(@user, tenant: @tenant)
    get "/u/#{@user.handle}/mutuals?filter=common"
    assert_response :success
    assert_select ".pulse-list-members a", text: /#{Regexp.escape(@other.display_name)}/
  end

  test "profile HTML: 'in common' chip links to the filtered mutuals page" do
    bridge = create_user(email: "br-#{SecureRandom.hex(4)}@example.com", name: "Bridge Mutual")
    @tenant.add_user!(bridge)
    @collective.add_user!(bridge)
    @user.primary_user_list_in!(@tenant).user_list_members.create!(added_by: @user, user: bridge)
    bridge.primary_user_list_in!(@tenant).user_list_members.create!(added_by: bridge, user: @user)
    @other.primary_user_list_in!(@tenant).user_list_members.create!(added_by: @other, user: bridge)
    bridge.primary_user_list_in!(@tenant).user_list_members.create!(added_by: bridge, user: @other)

    sign_in_as(@user, tenant: @tenant)
    get "/u/#{@other.handle}"
    assert_response :success
    assert_select ".pulse-mutuals-in-common a[href=?]", "/u/#{@other.handle}/mutuals?filter=common"
  end

  test "mutuals page HTML: 404 for unknown handle" do
    sign_in_as(@user, tenant: @tenant)
    get "/u/totally-not-a-real-handle-xyz/mutuals"
    assert_response :not_found
  end

  test "mutuals page HTML: still lists users the viewer has blocked" do
    third = create_user(email: "third-#{SecureRandom.hex(4)}@example.com", name: "Third Mutual")
    @tenant.add_user!(third)
    @collective.add_user!(third)
    @other.primary_user_list_in!(@tenant).user_list_members.create!(added_by: @other, user: third)
    third.primary_user_list_in!(@tenant).user_list_members.create!(added_by: third, user: @other)
    UserBlock.create!(blocker: @user, blocked: third, tenant: @tenant)

    sign_in_as(@user, tenant: @tenant)
    get "/u/#{@other.handle}/mutuals"
    assert_response :success
    assert_select ".pulse-list-members a", text: /Third Mutual/

    # And the count on @other's profile header agrees with the unfiltered list.
    get "/u/#{@other.handle}"
    assert_response :success
    assert_match(/has\s+1\s+mutual\b/, css_select(".pulse-user-mutuals-line").first.text)
  end

  test "profile HTML: NO toggle on your own profile" do
    sign_in_as(@user, tenant: @tenant)
    get "/u/#{@user.handle}"
    assert_response :success
    assert_select "button[data-controller='ajax-toggle']", count: 0
  end

  test "profile HTML: Message link lives inside the kebab menu, not in the top-level actions row" do
    sign_in_as(@user, tenant: @tenant)
    get "/u/#{@other.handle}"
    assert_response :success

    # Not a direct affordance in the header actions row.
    assert_select ".pulse-user-actions > a[href*='/chat/']", count: 0

    # Present inside the kebab menu.
    assert_select "details[data-controller='kebab-menu'] a[href*='/chat/']", count: 1
  end

  test "profile HTML: Block button shows its description via tooltip, not as a separate list item" do
    sign_in_as(@user, tenant: @tenant)
    get "/u/#{@other.handle}"
    assert_response :success

    # The description is no longer rendered as standalone body text.
    assert_select "li", text: /Blocking hides their content/, count: 0

    # It's on the Block button itself as a title attribute.
    assert_select "details[data-controller='kebab-menu'] form button[title*='Blocking hides their content']", count: 1
  end

  test "profile HTML: viewer who has blocked the target sees no tune-in button + 'You have blocked' message" do
    UserBlock.create!(blocker: @user, blocked: @other, tenant: @tenant)
    sign_in_as(@user, tenant: @tenant)
    get "/u/#{@other.handle}"
    assert_response :success

    assert_select "button[data-controller='ajax-toggle']", count: 0
    assert_select ".pulse-user-actions", text: /You have blocked #{Regexp.escape(@other.display_name)}/
  end

  test "profile HTML: viewer blocked by the target sees no tune-in button + 'X has blocked you' message" do
    UserBlock.create!(blocker: @other, blocked: @user, tenant: @tenant)
    sign_in_as(@user, tenant: @tenant)
    get "/u/#{@other.handle}"
    assert_response :success

    assert_select "button[data-controller='ajax-toggle']", count: 0
    assert_select ".pulse-user-actions", text: /#{Regexp.escape(@other.display_name)} has blocked you/
  end

  test "profile HTML: Message link is hidden when viewer has blocked the target" do
    UserBlock.create!(blocker: @user, blocked: @other, tenant: @tenant)
    sign_in_as(@user, tenant: @tenant)
    get "/u/#{@other.handle}"
    assert_response :success
    assert_select "a[href*='/chat/']", count: 0
  end

  test "profile HTML: Message link is hidden when viewer is blocked by the target" do
    UserBlock.create!(blocker: @other, blocked: @user, tenant: @tenant)
    sign_in_as(@user, tenant: @tenant)
    get "/u/#{@other.handle}"
    assert_response :success
    assert_select "a[href*='/chat/']", count: 0
  end

  test "profile HTML: blocked profile is mostly empty — no accordions, no common-collective count" do
    # Seed data that would normally show accordions: a list owned by @other,
    # a note authored by @other (Recent Activity), shared non-main collective.
    other_collective = Collective.create!(
      tenant: @tenant, name: "Common", handle: "common-#{SecureRandom.hex(4)}",
      collective_type: "standard", created_by: @user, updated_by: @user
    )
    other_collective.add_user!(@user)
    other_collective.add_user!(@other)
    UserList.create!(creator: @other, owner: @other, name: "@other's public list")

    UserBlock.create!(blocker: @user, blocked: @other, tenant: @tenant)
    sign_in_as(@user, tenant: @tenant)
    get "/u/#{@other.handle}"
    assert_response :success

    # None of the accordion section titles should appear.
    assert_select "details summary", text: /Common Collectives/, count: 0
    assert_select "details summary", text: /Lists/, count: 0
    assert_select "details summary", text: /Recent Activity/, count: 0
    # Common-collective count chip absent too.
    assert_select ".pulse-user-common-counts", count: 0
  end

  test "profile HTML: profile blocked-by-target is also mostly empty — no accordions" do
    other_collective = Collective.create!(
      tenant: @tenant, name: "Common", handle: "common-#{SecureRandom.hex(4)}",
      collective_type: "standard", created_by: @user, updated_by: @user
    )
    other_collective.add_user!(@user)
    other_collective.add_user!(@other)
    UserList.create!(creator: @other, owner: @other, name: "@other's public list")

    UserBlock.create!(blocker: @other, blocked: @user, tenant: @tenant)
    sign_in_as(@user, tenant: @tenant)
    get "/u/#{@other.handle}"
    assert_response :success

    assert_select "details summary", text: /Common Collectives/, count: 0
    assert_select "details summary", text: /Lists/, count: 0
    assert_select "details summary", text: /Recent Activity/, count: 0
    assert_select ".pulse-user-common-counts", count: 0
  end

  test "profile HTML: Block button label is just 'Block' (no handle)" do
    sign_in_as(@user, tenant: @tenant)
    get "/u/#{@other.handle}"
    assert_response :success

    assert_select "details[data-controller='kebab-menu'] form button" do |btns|
      block_btn = btns.find { |b| b.text.include?("Block") }
      assert block_btn, "expected to find a Block button inside the kebab menu"
      assert_match(/\ABlock\z/, block_btn.text.strip)
    end
  end

  test "profile HTML: Lists tab is present for owner; New list link appears on the Lists tab body" do
    sign_in_as(@user, tenant: @tenant)
    get "/u/#{@user.handle}?tab=lists"
    assert_response :success
    assert_select "nav.pulse-profile-tabs a", text: /Lists/
    assert_select "a[href='/lists/new']", text: /New list/
  end

  test "profile HTML: Lists tab is present (with zero count) when viewing another user with no visible lists" do
    sign_in_as(@user, tenant: @tenant)
    get "/u/#{@other.handle}"
    assert_response :success
    # Lists tab is always visible per the new tab visibility rules; it carries
    # an empty state on the body. Confirm the tab is in the nav.
    assert_select "nav.pulse-profile-tabs a", text: /Lists/
  end
end
