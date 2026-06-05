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
    Note.create!(
      tenant: other_tenant,
      collective: other_main,
      created_by: @user,
      text: "CROSS_TENANT_LEAK_CANARY",
      deadline: Time.current + 1.week,
    )
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
    Note.create!(
      tenant: @tenant, collective: main_collective, created_by: other,
      text: "post by someone I tune in to",
      deadline: Time.current + 1.week,
    )
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
    Note.create!(
      tenant: @tenant, collective: main_collective, created_by: other,
      text: "post by a stranger",
      deadline: Time.current + 1.week,
    )
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
    Note.create!(
      tenant: @tenant, collective: main_collective, created_by: @user,
      text: "my own post",
      deadline: Time.current + 1.week,
    )
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
    Note.create!(
      tenant: @tenant, collective: main_collective, created_by: other,
      text: "post by blocked stale-tune-in user",
      deadline: Time.current + 1.week,
    )
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
    Collective.clear_thread_scope
    Tenant.clear_thread_scope

    get "/"
    assert_response :success
    assert_not_includes response.body, "A private note only for collective members"
  end
end
