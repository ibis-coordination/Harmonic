# typed: false

require "test_helper"

class HomeControllerTest < ActionDispatch::IntegrationTest
  def setup
    @tenant = @global_tenant
    @collective = @global_collective
    @user = @global_user
    host! "#{@tenant.subdomain}.#{ENV['HOSTNAME']}"
  end

  test "unauthenticated user is redirected to login" do
    get "/"
    assert_response :redirect
  end

  test "authenticated user sees homepage" do
    sign_in_as(@user, tenant: @tenant)
    get "/"
    assert_response :success
  end

  test "the home my:notified view offers mark-all-read scoped to the main collective" do
    sign_in_as(@user, tenant: @tenant)

    get "/", params: { q: "my:notified" }
    assert_response :success
    main = Collective.find(@tenant.main_collective_id)
    assert_select "button[data-action='click->notification-actions#markReadForCollective'][data-collective-id='#{main.id}']"

    get "/"
    assert_response :success
    assert_select "button[data-action='click->notification-actions#markReadForCollective']", count: 0
  end

  test "rail badges render with unread counts server-side on first paint" do
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    other = Collective.create!(tenant: @tenant, name: "Rail Badge Collective", handle: "rail-badge-collective", created_by: @user)
    other.add_user!(@user)

    event = Event.create!(tenant: @tenant, collective: other, event_type: "note.created", actor: @user)
    notification = Notification.create!(tenant: @tenant, event: event, notification_type: "mention", title: "Badge me")
    NotificationRecipient.create!(notification: notification, user: @user, channel: "in_app", status: "pending", tenant: @tenant)
    Collective.clear_thread_scope

    sign_in_as(@user, tenant: @tenant)
    get "/"
    assert_response :success
    assert_select ".pulse-rail-badge[data-collective-id='#{other.id}']", text: "1" do |badges|
      assert_not_includes badges.first["style"].to_s, "display: none"
    end
  end

  test "layout renders the places sheet, toggled from the tab bar's Places tab" do
    sign_in_as(@user, tenant: @tenant)
    get "/"
    assert_response :success

    assert_select "body[data-controller~='places-sheet']"
    # The sheet's toggle lives in the bottom tab bar now; the old header
    # toggle is gone.
    assert_select ".pulse-places-toggle", false
    assert_select ".pulse-tab-bar button[data-places-sheet-target='toggle'][aria-expanded='false']" do
      assert_select "[data-places-sheet-target='dot']"
    end
    assert_select ".pulse-places-sheet[aria-hidden='true']" do
      assert_select "a[href='/']", text: /Public space/
      assert_select "a[href='/chat']", text: /Chat/
      assert_select "a[href='/collectives']", text: /Create or join a collective/
    end
  end

  test "layout renders the bottom tab bar with its five destinations for signed-in users" do
    sign_in_as(@user, tenant: @tenant)
    get "/"
    assert_response :success

    assert_select ".pulse-tab-bar" do
      # Outward → inward: globe, places, search, inbox, you.
      assert_select "a[href='/'] .octicon-globe"
      assert_select "button[data-action*='places-sheet#toggle']", text: /Places/
      assert_select "a[href='/search']"
      assert_select "a[href='/notifications'] .pulse-tab-bar-badge"
      # You: the avatar menu, same items as the header menu.
      assert_select "[data-controller='top-right-menu']" do
        assert_select "a[href='#{@user.path}']", text: "Profile"
        assert_select "button[type=submit]", text: "Sign Out"
      end
    end
  end

  test "the tab bar's inbox badge renders the unread count server-side" do
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    notification = Notification.create!(tenant: @tenant, event: nil, notification_type: "reminder", title: "Badge probe")
    NotificationRecipient.create!(notification: notification, user: @user, channel: "in_app", status: "delivered", tenant: @tenant)
    Tenant.clear_thread_scope

    sign_in_as(@user, tenant: @tenant)
    get "/"
    assert_response :success
    assert_select ".pulse-tab-bar a[href='/notifications'] .pulse-tab-bar-badge[data-total-badge]", text: "1"
  end

  test "anonymous pages render no tab bar" do
    get "/login"
    follow_redirect!
    assert_response :success
    assert_select ".pulse-tab-bar", false
  end

  test "rail chat badge renders its unread count server-side on first paint" do
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    chat = Notification.create!(tenant: @tenant, event: nil, notification_type: "chat_message", title: "Ping", url: "/chat/somebody")
    NotificationRecipient.create!(notification: chat, user: @user, channel: "in_app", status: "delivered", tenant: @tenant)
    Collective.clear_thread_scope

    sign_in_as(@user, tenant: @tenant)
    get "/"
    assert_response :success
    assert_select ".pulse-rail-chat .pulse-rail-badge[data-chat-badge]", text: "1" do |badges|
      assert_not_includes badges.first["style"].to_s, "display: none"
    end
  end

  test "homepage hides content from tuned-in user posting in a different tenant" do
    sign_in_as(@user, tenant: @tenant)
    main = @tenant.main_collective
    main.add_user!(@user) unless main.user_is_member?(@user)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: main.handle)
    @user.primary_user_list_in!(@tenant).user_list_members.create!(user: @user, added_by: @user)
    Collective.clear_thread_scope

    other_tenant = create_tenant(subdomain: "other-#{SecureRandom.hex(4)}", name: "Other Tenant")
    other_tenant.add_user!(@user)
    other_tenant.create_main_collective!(created_by: @user)
    other_main = other_tenant.main_collective
    other_main.add_user!(@user) unless other_main.user_is_member?(@user)
    Tenant.scope_thread_to_tenant(subdomain: other_tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: other_tenant.subdomain, handle: other_main.handle)
    canary = Note.create!(
      tenant: other_tenant,
      collective: other_main,
      created_by: @user,
      text: "CROSS_TENANT_LEAK_CANARY",
      deadline: Time.current + 1.week,
    )
    SearchIndexer.reindex(canary)
    Collective.clear_thread_scope
    Tenant.clear_thread_scope

    get "/"
    assert_response :success
    refute_includes response.body, "CROSS_TENANT_LEAK_CANARY"
  end

  test "homepage displays feed items from main collective" do
    sign_in_as(@user, tenant: @tenant)

    # Create a note in the main collective
    main_collective = Collective.find(@tenant.main_collective_id)
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: main_collective.handle)
    note = Note.create!(
      tenant: @tenant,
      collective: main_collective,
      created_by: @user,
      text: "A public note visible on the homepage",
      deadline: Time.current + 1.week,
    )
    SearchIndexer.reindex(note)
    Collective.clear_thread_scope
    Tenant.clear_thread_scope

    get "/"
    assert_response :success
    assert_includes response.body, "A public note visible on the homepage"
    assert_includes response.body, "pulse-feed-item"
  end

  # Regression: the markdown feed views (home, pulse, users) called
  # `feed_item[:item].title` on every item — but ReminderEvent items wrap a
  # NoteHistoryEvent which has no `.title`, so any feed containing a fired
  # reminder crashed the markdown render with NoMethodError.
  test "homepage markdown renders when feed includes a fired reminder event" do
    sign_in_as(@user, tenant: @tenant)

    main_collective = Collective.find(@tenant.main_collective_id)
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: main_collective.handle)
    note = Note.create!(
      tenant: @tenant,
      collective: main_collective,
      created_by: @user,
      title: "Note with a reminder",
      text: "body",
      subtype: "reminder",
      deadline: Time.current + 1.week,
    )
    NoteHistoryEvent.create!(
      tenant: @tenant,
      note: note,
      user: @user,
      event_type: "reminder",
      happened_at: Time.current,
    )
    SearchIndexer.reindex(note)
    Collective.clear_thread_scope
    Tenant.clear_thread_scope

    get "/", headers: { "Accept" => "text/markdown" }
    assert_response :success
    assert_includes response.body, "[Reminder]"
    assert_includes response.body, "Note with a reminder"
    assert_includes response.body, note.path
  end

  test "homepage shows content from users the viewer has tuned in to" do
    other = create_user(email: "tuned-in-#{SecureRandom.hex(4)}@example.com", name: "Tuned-In User")
    @tenant.add_user!(other)
    main_collective = Collective.find(@tenant.main_collective_id)
    main_collective.add_user!(other)

    # Viewer tunes in to `other` (adds them to viewer's primary list).
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: main_collective.handle)
    @user.primary_user_list_in!(@tenant).user_list_members.create!(added_by: @user, user: other)
    note = Note.create!(
      tenant: @tenant, collective: main_collective, created_by: other,
      text: "post by someone I tune in to",
      deadline: Time.current + 1.week,
    )
    SearchIndexer.reindex(note)
    Collective.clear_thread_scope
    Tenant.clear_thread_scope

    sign_in_as(@user, tenant: @tenant)
    get "/"
    assert_response :success
    assert_includes response.body, "post by someone I tune in to"
  end

  test "homepage hides content from users the viewer has NOT tuned in to" do
    other = create_user(email: "stranger-#{SecureRandom.hex(4)}@example.com", name: "Stranger")
    @tenant.add_user!(other)
    main_collective = Collective.find(@tenant.main_collective_id)
    main_collective.add_user!(other)

    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: main_collective.handle)
    note = Note.create!(
      tenant: @tenant, collective: main_collective, created_by: other,
      text: "post by a stranger",
      deadline: Time.current + 1.week,
    )
    SearchIndexer.reindex(note)
    Collective.clear_thread_scope
    Tenant.clear_thread_scope

    sign_in_as(@user, tenant: @tenant)
    get "/"
    assert_response :success
    assert_not_includes response.body, "post by a stranger"
  end

  test "homepage shows tune-in explainer when the viewer hasn't tuned in to anyone and has no content" do
    sign_in_as(@user, tenant: @tenant)
    get "/"
    assert_response :success
    assert_match(/Tune in/, response.body)
    assert_match(/seeing their notes/i, response.body)
    assert_match(/Your home is quiet/, response.body)
  end

  test "homepage shows the viewer's own content even without tune-ins" do
    main_collective = Collective.find(@tenant.main_collective_id)
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: main_collective.handle)
    note = Note.create!(
      tenant: @tenant, collective: main_collective, created_by: @user,
      text: "my own post",
      deadline: Time.current + 1.week,
    )
    SearchIndexer.reindex(note)
    Collective.clear_thread_scope
    Tenant.clear_thread_scope

    sign_in_as(@user, tenant: @tenant)
    get "/"
    assert_response :success
    assert_includes response.body, "my own post"
  end

  test "homepage hides content from blocked users even if a stale primary-list membership survives" do
    other = create_user(email: "stale-blocked-#{SecureRandom.hex(4)}@example.com", name: "Stale Blocked")
    @tenant.add_user!(other)
    main_collective = Collective.find(@tenant.main_collective_id)
    main_collective.add_user!(other)

    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: main_collective.handle)
    note = Note.create!(
      tenant: @tenant, collective: main_collective, created_by: other,
      text: "post by blocked stale-tune-in user",
      deadline: Time.current + 1.week,
    )
    SearchIndexer.reindex(note)
    # Create the block first (cleanup callback runs but no membership to clean
    # yet). Then bypass validation to insert a stale tune-in across the block,
    # simulating data left behind from before the cleanup callback shipped.
    UserBlock.create!(blocker: @user, blocked: other, tenant: @tenant)
    primary = @user.primary_user_list_in!(@tenant)
    stale = primary.user_list_members.new(added_by: @user, user: other)
    stale.save(validate: false)
    Collective.clear_thread_scope
    Tenant.clear_thread_scope

    sign_in_as(@user, tenant: @tenant)

    # HTML — caught by FeedItemComponent's block-aware filter at render time.
    get "/"
    assert_response :success
    assert_not_includes response.body, "post by blocked stale-tune-in user"

    # Markdown — no render-time block filter; the controller must exclude
    # blocked authors from the feed scope itself.
    get "/", headers: { "Accept" => "text/markdown" }
    assert_response :success
    assert_not_includes response.body, "post by blocked stale-tune-in user"
  end

  test "homepage does not display feed items from non-main collectives" do
    sign_in_as(@user, tenant: @tenant)

    # Create a note in a regular collective (not the main one)
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    note = Note.create!(
      tenant: @tenant,
      collective: @collective,
      created_by: @user,
      text: "A private note only for collective members",
      deadline: Time.current + 1.week,
    )
    SearchIndexer.reindex(note)
    Collective.clear_thread_scope
    Tenant.clear_thread_scope

    get "/"
    assert_response :success
    assert_not_includes response.body, "A private note only for collective members"
  end

  # Feeds-are-queries behaviors (docs/NAVIGATION_DESIGN.md): the home feed
  # is a search with fixed scope visibility:public and default query
  # list:tuned_in. ?q absent applies the default; ?q present (even empty)
  # is the user's own refinement.

  def create_indexed_main_note(created_by:, text:)
    main_collective = Collective.find(@tenant.main_collective_id)
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: main_collective.handle)
    note = Note.create!(
      tenant: @tenant, collective: main_collective, created_by: created_by,
      text: text, deadline: Time.current + 1.week,
    )
    SearchIndexer.reindex(note)
    Collective.clear_thread_scope
    Tenant.clear_thread_scope
    note
  end

  test "explicitly empty ?q= broadens the feed to everything public" do
    other = create_user(email: "broadened-#{SecureRandom.hex(4)}@example.com", name: "Broadened")
    @tenant.add_user!(other)
    Collective.find(@tenant.main_collective_id).add_user!(other)
    create_indexed_main_note(created_by: other, text: "post by a stranger, broadened")

    sign_in_as(@user, tenant: @tenant)
    get "/"
    assert_not_includes response.body, "post by a stranger, broadened"

    get "/", params: { q: "" }
    assert_response :success
    assert_includes response.body, "post by a stranger, broadened"
  end

  test "query refinement filters the home feed" do
    create_indexed_main_note(created_by: @user, text: "refineme note body")

    sign_in_as(@user, tenant: @tenant)
    get "/", params: { q: "type:decision" }
    assert_response :success
    assert_not_includes response.body, "refineme note body"

    get "/", params: { q: "type:note refineme" }
    assert_includes response.body, "refineme note body"
  end

  test "the home feed's visibility cannot be widened by the query" do
    sign_in_as(@user, tenant: @tenant)
    get "/", params: { q: "visibility:private" }
    assert_response :success
    assert_select ".pulse-feed-bar-warning", text: /visibility:private ignored/
  end

  test "home feed bar shows the fixed scope chip and the editable default query" do
    sign_in_as(@user, tenant: @tenant)
    get "/"
    assert_response :success
    assert_select ".pulse-feed-bar-scope code", text: "visibility:public"
    # The comment exclusion is part of the visible default query — the
    # viewer can see it and remove it, not a hidden structural filter.
    assert_select "textarea[name='q']", text: "list:tuned_in -subtype:comment"
  end

  test "reminders interleave on the default view but not on refined queries" do
    main_collective = Collective.find(@tenant.main_collective_id)
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: main_collective.handle)
    note = Note.create!(
      tenant: @tenant, collective: main_collective, created_by: @user,
      title: "Reminder interleave note", text: "body", subtype: "reminder",
      deadline: Time.current + 1.week,
    )
    NoteHistoryEvent.create!(
      tenant: @tenant, note: note, user: @user,
      event_type: "reminder", happened_at: Time.current,
    )
    Collective.clear_thread_scope
    Tenant.clear_thread_scope

    sign_in_as(@user, tenant: @tenant)
    get "/", headers: { "Accept" => "text/markdown" }
    assert_includes response.body, "[Reminder]"

    get "/", params: { q: "type:decision" }, headers: { "Accept" => "text/markdown" }
    assert_not_includes response.body, "[Reminder]"
  end
end
