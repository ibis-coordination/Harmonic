require "test_helper"

class NotificationsControllerTest < ActionDispatch::IntegrationTest
  def setup
    @tenant = @global_tenant
    @collective = @global_collective
    @user = @global_user
    host! "#{@tenant.subdomain}.#{ENV['HOSTNAME']}"
  end

  # === Unauthenticated Access Tests ===

  test "unauthenticated user is redirected from notifications" do
    get "/notifications"
    assert_response :redirect
  end

  test "unauthenticated user gets 401 for unread_count JSON request" do
    get "/notifications/unread_count", headers: { "Accept" => "application/json" }
    assert_response :unauthorized
  end

  # === Index Tests ===

  test "authenticated user can access notifications" do
    sign_in_as(@user, tenant: @tenant)
    get "/notifications"
    assert_response :success
  end

  test "notifications index shows user notifications" do
    sign_in_as(@user, tenant: @tenant)

    # Create a notification for the user
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    event = Event.create!(tenant: @tenant, collective: @collective, event_type: "test.created")
    notification = Notification.create!(
      tenant: @tenant,
      event: event,
      notification_type: "mention",
      title: "Test notification",
    )
    NotificationRecipient.create!(
      notification: notification,
      user: @user,
      channel: "in_app",
      status: "delivered",
    )
    Collective.clear_thread_scope

    get "/notifications"
    assert_response :success
    assert_match "Test notification", response.body
  end

  # === Tune-in back button on tune_in notifications ===

  test "tune_in notification renders a 'Tune in' button (viewer not yet tuned in to actor)" do
    main = @tenant.main_collective
    main.add_user!(@user) unless main.user_is_member?(@user)
    actor = create_user(email: "ti-actor@example.com", name: "Tune Actor")
    @tenant.add_user!(actor); main.add_user!(actor)

    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: main.handle)
    event = Event.create!(tenant: @tenant, collective: main, actor_id: actor.id, event_type: "user_list_member.added")
    notification = Notification.create!(
      tenant: @tenant, event: event, notification_type: "tune_in",
      title: "Tune Actor tuned in to you", url: "/u/#{actor.handle}",
    )
    NotificationRecipient.create!(
      notification: notification, user: @user, channel: "in_app", status: "delivered",
    )
    Collective.clear_thread_scope

    sign_in_as(@user, tenant: @tenant)
    get "/notifications"
    assert_response :success
    assert_select ".pulse-notification .pulse-tune-in-btn", text: /Tune in/
  end

  test "tune_in notification hides the button when viewer is already tuned in to actor" do
    main = @tenant.main_collective
    main.add_user!(@user) unless main.user_is_member?(@user)
    actor = create_user(email: "ti-actor-already@example.com", name: "Already Tuned")
    @tenant.add_user!(actor); main.add_user!(actor)

    # Viewer is already tuned in to actor.
    list = @user.primary_user_list_in!(@tenant)
    list.user_list_members.create!(
      tenant: list.tenant, collective: list.collective, added_by: @user, user: actor,
    )

    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: main.handle)
    event = Event.create!(tenant: @tenant, collective: main, actor_id: actor.id, event_type: "user_list_member.added")
    notification = Notification.create!(
      tenant: @tenant, event: event, notification_type: "tune_in",
      title: "Already Tuned tuned in to you", url: "/u/#{actor.handle}",
    )
    NotificationRecipient.create!(
      notification: notification, user: @user, channel: "in_app", status: "delivered",
    )
    Collective.clear_thread_scope

    sign_in_as(@user, tenant: @tenant)
    get "/notifications"
    assert_response :success
    # Button shows "Tuned in" (the on-state) since the viewer is already tuned in
    assert_select ".pulse-notification .pulse-tune-in-btn", text: /Tuned in/
  end

  # === Unread Count Tests ===

  test "unread_count returns correct count" do
    sign_in_as(@user, tenant: @tenant)

    # Create unread notification
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    event = Event.create!(tenant: @tenant, collective: @collective, event_type: "test.created")
    notification = Notification.create!(
      tenant: @tenant,
      event: event,
      notification_type: "mention",
      title: "Test notification",
    )
    NotificationRecipient.create!(
      notification: notification,
      user: @user,
      channel: "in_app",
      status: "pending",
    )
    Collective.clear_thread_scope

    get "/notifications/unread_count", headers: { "Accept" => "application/json" }
    assert_response :success
    json_response = JSON.parse(response.body)
    assert_equal 1, json_response["count"]
  end

  # === Dismiss Tests ===

  test "dismiss dismisses notification" do
    sign_in_as(@user, tenant: @tenant)

    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    event = Event.create!(tenant: @tenant, collective: @collective, event_type: "test.created")
    notification = Notification.create!(
      tenant: @tenant,
      event: event,
      notification_type: "mention",
      title: "Test notification",
    )
    recipient = NotificationRecipient.create!(
      notification: notification,
      user: @user,
      channel: "in_app",
      status: "delivered",
    )
    Collective.clear_thread_scope

    post "/notifications/actions/dismiss", params: { id: recipient.id }
    assert_response :success

    recipient.reload
    assert_equal "dismissed", recipient.status
    assert recipient.dismissed_at.present?
  end

  # === Dismiss All Tests ===

  test "dismiss_all dismisses all notifications" do
    sign_in_as(@user, tenant: @tenant)

    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    event = Event.create!(tenant: @tenant, collective: @collective, event_type: "test.created")
    notification = Notification.create!(
      tenant: @tenant,
      event: event,
      notification_type: "mention",
      title: "Test notification",
    )
    recipient1 = NotificationRecipient.create!(
      notification: notification,
      user: @user,
      channel: "in_app",
      status: "pending",
    )
    recipient2 = NotificationRecipient.create!(
      notification: notification,
      user: @user,
      channel: "in_app",
      status: "delivered",
    )
    Collective.clear_thread_scope

    post "/notifications/actions/dismiss_all"
    assert_response :success

    recipient1.reload
    recipient2.reload
    assert_equal "dismissed", recipient1.status
    assert_equal "dismissed", recipient2.status
  end

  # === Markdown API Tests ===

  test "notifications index returns markdown for LLM" do
    sign_in_as(@user, tenant: @tenant)

    get "/notifications", headers: { "Accept" => "text/markdown" }
    assert_response :success
    assert_includes response.content_type, "text/markdown"
    assert_match "# Notifications", response.body
  end

  test "notifications actions index returns markdown for LLM" do
    sign_in_as(@user, tenant: @tenant)

    get "/notifications/actions", headers: { "Accept" => "text/markdown" }
    assert_response :success
  end

  # === Dismiss For Collective Tests ===

  test "dismiss_for_collective dismisses notifications for specific collective" do
    sign_in_as(@user, tenant: @tenant)

    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)

    # Create a second collective
    collective2 = Collective.create!(tenant: @tenant, name: "Second Collective", handle: "second-collective", created_by: @user)

    # Create notifications in first collective
    event1 = Event.create!(tenant: @tenant, collective: @collective, event_type: "test.created")
    notification1 = Notification.create!(tenant: @tenant, event: event1, notification_type: "mention", title: "Collective1 Notification")
    recipient1 = NotificationRecipient.create!(notification: notification1, user: @user, channel: "in_app", status: "pending")

    # Create notifications in second collective
    event2 = Event.create!(tenant: @tenant, collective: collective2, event_type: "test.created")
    notification2 = Notification.create!(tenant: @tenant, event: event2, notification_type: "mention", title: "Collective2 Notification")
    recipient2 = NotificationRecipient.create!(notification: notification2, user: @user, channel: "in_app", status: "pending")

    Collective.clear_thread_scope

    # Dismiss only first collective's notifications
    post "/notifications/actions/dismiss_for_collective", params: { collective_id: @collective.id }
    assert_response :success

    recipient1.reload
    recipient2.reload

    # First collective notification should be dismissed
    assert_equal "dismissed", recipient1.status
    assert recipient1.dismissed_at.present?

    # Second collective notification should still be pending
    assert_equal "pending", recipient2.status
    assert_nil recipient2.dismissed_at
  end

  test "dismiss_for_collective with reminders dismisses due reminders only" do
    sign_in_as(@user, tenant: @tenant)

    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    Tenant.current_id = @tenant.id

    # Create a due reminder (notification without event)
    reminder_notification = Notification.create!(tenant: @tenant, event: nil, notification_type: "reminder", title: "Due reminder")
    reminder_recipient = NotificationRecipient.create!(notification: reminder_notification, user: @user, channel: "in_app", status: "pending")

    # Create a normal notification with an event
    event = Event.create!(tenant: @tenant, collective: @collective, event_type: "test.created")
    normal_notification = Notification.create!(tenant: @tenant, event: event, notification_type: "mention", title: "Normal notification")
    normal_recipient = NotificationRecipient.create!(notification: normal_notification, user: @user, channel: "in_app", status: "pending")

    Collective.clear_thread_scope

    # Dismiss reminders using "reminders" as collective_id
    post "/notifications/actions/dismiss_for_collective", params: { collective_id: "reminders" }
    assert_response :success

    reminder_recipient.reload
    normal_recipient.reload

    # Reminder should be dismissed
    assert_equal "dismissed", reminder_recipient.status

    # Normal notification should still be pending
    assert_equal "pending", normal_recipient.status
  end

  test "dismiss_for_collective returns error for invalid collective" do
    sign_in_as(@user, tenant: @tenant)

    post "/notifications/actions/dismiss_for_collective", params: { collective_id: 99999 }
    assert_response :not_found

    json_response = JSON.parse(response.body)
    assert_equal false, json_response["success"]
    assert_equal "Collective not found.", json_response["error"]
  end

  test "dismiss_for_collective returns count in JSON response" do
    sign_in_as(@user, tenant: @tenant)

    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)

    event = Event.create!(tenant: @tenant, collective: @collective, event_type: "test.created")
    notification = Notification.create!(tenant: @tenant, event: event, notification_type: "mention", title: "Test")

    # Create 3 recipients
    NotificationRecipient.create!(notification: notification, user: @user, channel: "in_app", status: "pending")
    NotificationRecipient.create!(notification: notification, user: @user, channel: "in_app", status: "delivered")
    NotificationRecipient.create!(notification: notification, user: @user, channel: "in_app", status: "pending")

    Collective.clear_thread_scope

    post "/notifications/actions/dismiss_for_collective", params: { collective_id: @collective.id }
    assert_response :success

    json_response = JSON.parse(response.body)
    assert_equal true, json_response["success"]
    assert_equal 3, json_response["count"]
  end

  # === Notifications Grouped by Collective Tests ===

  test "index groups notifications by collective in HTML" do
    sign_in_as(@user, tenant: @tenant)

    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)

    # Create a second collective
    collective2 = Collective.create!(tenant: @tenant, name: "Second Collective", handle: "second-collective", created_by: @user)

    # Create notifications in first collective
    event1 = Event.create!(tenant: @tenant, collective: @collective, event_type: "test.created")
    notification1 = Notification.create!(tenant: @tenant, event: event1, notification_type: "mention", title: "Collective1 Notification")
    NotificationRecipient.create!(notification: notification1, user: @user, channel: "in_app", status: "pending")

    # Create notifications in second collective
    event2 = Event.create!(tenant: @tenant, collective: collective2, event_type: "test.created")
    notification2 = Notification.create!(tenant: @tenant, event: event2, notification_type: "mention", title: "Collective2 Notification")
    NotificationRecipient.create!(notification: notification2, user: @user, channel: "in_app", status: "pending")

    Collective.clear_thread_scope

    get "/notifications"
    assert_response :success

    # Should show both collective names in accordion headers
    assert_includes response.body, @collective.name
    assert_includes response.body, "Second Collective"
    assert_includes response.body, "pulse-accordion"
    assert_includes response.body, "data-collective-group"
  end

  test "index groups notifications by collective in markdown" do
    sign_in_as(@user, tenant: @tenant)

    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)

    # Create a second collective
    collective2 = Collective.create!(tenant: @tenant, name: "Second Collective", handle: "second-collective", created_by: @user)

    # Create notifications in first collective
    event1 = Event.create!(tenant: @tenant, collective: @collective, event_type: "test.created")
    notification1 = Notification.create!(tenant: @tenant, event: event1, notification_type: "mention", title: "Collective1 Notification")
    NotificationRecipient.create!(notification: notification1, user: @user, channel: "in_app", status: "pending")

    # Create notifications in second collective
    event2 = Event.create!(tenant: @tenant, collective: collective2, event_type: "test.created")
    notification2 = Notification.create!(tenant: @tenant, event: event2, notification_type: "mention", title: "Collective2 Notification")
    NotificationRecipient.create!(notification: notification2, user: @user, channel: "in_app", status: "pending")

    Collective.clear_thread_scope

    get "/notifications", headers: { "Accept" => "text/markdown" }
    assert_response :success

    # Should show collective names as markdown headers
    assert_includes response.body, "### #{@collective.name}"
    assert_includes response.body, "### Second Collective"
    assert_includes response.body, "dismiss_for_collective"
  end

  # === Mark Read Tests ===

  test "mark_read marks notification read without dismissing" do
    sign_in_as(@user, tenant: @tenant)
    recipient = create_notification_recipient(title: "Mark me read")

    post "/notifications/actions/mark_read", params: { id: recipient.id }
    assert_response :success

    recipient.reload
    assert recipient.read?
    assert_nil recipient.dismissed_at
    assert_equal "delivered", recipient.status
  end

  test "mark_read returns 404 for unknown notification" do
    sign_in_as(@user, tenant: @tenant)

    post "/notifications/actions/mark_read",
      params: { id: SecureRandom.uuid },
      headers: { "Accept" => "application/json" }
    assert_response :not_found
  end

  test "mark_all_read marks all unread notifications read and returns count" do
    sign_in_as(@user, tenant: @tenant)
    recipient1 = create_notification_recipient(title: "First")
    recipient2 = create_notification_recipient(title: "Second")

    post "/notifications/actions/mark_all_read", headers: { "Accept" => "application/json" }
    assert_response :success
    assert_equal 2, JSON.parse(response.body)["count"]

    [recipient1, recipient2].each do |recipient|
      recipient.reload
      assert recipient.read?
      assert_nil recipient.dismissed_at
    end
  end

  test "mark_all_read returns markdown action success for LLM" do
    sign_in_as(@user, tenant: @tenant)
    create_notification_recipient(title: "Readable")

    post "/notifications/actions/mark_all_read", headers: { "Accept" => "text/markdown" }
    assert_response :success
    assert_match "marked", response.body
  end

  test "mark_read_for_collective only marks notifications for that collective" do
    sign_in_as(@user, tenant: @tenant)

    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    collective2 = Collective.create!(tenant: @tenant, name: "Second Collective", handle: "second-collective", created_by: @user)

    event1 = Event.create!(tenant: @tenant, collective: @collective, event_type: "test.created")
    notification1 = Notification.create!(tenant: @tenant, event: event1, notification_type: "mention", title: "Collective1 Notification")
    recipient1 = NotificationRecipient.create!(notification: notification1, user: @user, channel: "in_app", status: "delivered")

    event2 = Event.create!(tenant: @tenant, collective: collective2, event_type: "test.created")
    notification2 = Notification.create!(tenant: @tenant, event: event2, notification_type: "mention", title: "Collective2 Notification")
    recipient2 = NotificationRecipient.create!(notification: notification2, user: @user, channel: "in_app", status: "delivered")
    Collective.clear_thread_scope

    post "/notifications/actions/mark_read_for_collective",
      params: { collective_id: @collective.id },
      headers: { "Accept" => "application/json" }
    assert_response :success
    assert_equal 1, JSON.parse(response.body)["count"]

    assert recipient1.reload.read?
    assert_not recipient2.reload.read?
  end

  test "mark_read_for_collective with reminders marks due reminders only" do
    sign_in_as(@user, tenant: @tenant)

    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    reminder_notification = Notification.create!(tenant: @tenant, event: nil, notification_type: "reminder", title: "Due reminder")
    reminder = NotificationRecipient.create!(notification: reminder_notification, user: @user, channel: "in_app", status: "pending")

    event = Event.create!(tenant: @tenant, collective: @collective, event_type: "test.created")
    normal_notification = Notification.create!(tenant: @tenant, event: event, notification_type: "mention", title: "Normal")
    normal = NotificationRecipient.create!(notification: normal_notification, user: @user, channel: "in_app", status: "delivered")
    Collective.clear_thread_scope

    post "/notifications/actions/mark_read_for_collective",
      params: { collective_id: "reminders" },
      headers: { "Accept" => "application/json" }
    assert_response :success

    assert reminder.reload.read?
    assert_not normal.reload.read?
  end

  test "mark_read_for_collective returns error for invalid collective" do
    sign_in_as(@user, tenant: @tenant)

    post "/notifications/actions/mark_read_for_collective",
      params: { collective_id: SecureRandom.uuid },
      headers: { "Accept" => "application/json" }
    assert_response :not_found
  end

  # === Dismiss For Chat Tests ===

  test "dismiss_for_chat dismisses chat notifications from the given partner only" do
    sign_in_as(@user, tenant: @tenant)

    hex = SecureRandom.hex(4)
    partner = create_user(name: "Partner #{hex}", email: "partner-#{hex}@example.com")
    other = create_user(name: "Other #{hex}", email: "other-#{hex}@example.com")
    @tenant.add_user!(partner)
    @tenant.add_user!(other)

    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    partner_handle = TenantUser.tenant_scoped_only(@tenant.id).find_by(user: partner).handle
    other_handle = TenantUser.tenant_scoped_only(@tenant.id).find_by(user: other).handle
    NotificationService.notify_chat_message!(sender: partner, recipient: @user, tenant: @tenant, url: "/chat/#{partner_handle}")
    NotificationService.notify_chat_message!(sender: other, recipient: @user, tenant: @tenant, url: "/chat/#{other_handle}")
    Collective.clear_thread_scope

    post "/notifications/actions/dismiss_for_chat",
      params: { handle: partner_handle },
      headers: { "Accept" => "application/json" }
    assert_response :success

    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    remaining = NotificationRecipient.where(user: @user, tenant: @tenant).in_app.undismissed
    assert_equal 1, remaining.count
    assert_equal "/chat/#{other_handle}", remaining.first.notification.url
    Collective.clear_thread_scope
  end

  test "dismiss_for_chat returns error for unknown handle" do
    sign_in_as(@user, tenant: @tenant)

    post "/notifications/actions/dismiss_for_chat",
      params: { handle: "no-such-handle" },
      headers: { "Accept" => "application/json" }
    assert_response :not_found
  end

  # === Read State in Index ===

  test "index includes read notifications until dismissed" do
    sign_in_as(@user, tenant: @tenant)

    read_recipient = create_notification_recipient(title: "Already read")
    read_recipient.mark_read!
    dismissed_recipient = create_notification_recipient(title: "Already dismissed")
    dismissed_recipient.dismiss!

    get "/notifications"
    assert_response :success
    assert_match "Already read", response.body
    assert_no_match(/Already dismissed/, response.body)
  end

  test "markdown index shows read state and mark_read actions" do
    sign_in_as(@user, tenant: @tenant)

    unread_recipient = create_notification_recipient(title: "Unread one")
    read_recipient = create_notification_recipient(title: "Read one")
    read_recipient.mark_read!

    get "/notifications", headers: { "Accept" => "text/markdown" }
    assert_response :success
    assert_match "mark_read?id=#{unread_recipient.id}", response.body
    assert_match "mark_all_read", response.body
    assert_match "unread", response.body
    assert_no_match(/mark_read\?id=#{read_recipient.id}/, response.body)
  end

  private

  def create_notification_recipient(title:)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    event = Event.create!(tenant: @tenant, collective: @collective, event_type: "test.created")
    notification = Notification.create!(
      tenant: @tenant,
      event: event,
      notification_type: "mention",
      title: title,
    )
    recipient = NotificationRecipient.create!(
      notification: notification,
      user: @user,
      channel: "in_app",
      status: "delivered",
    )
    Collective.clear_thread_scope
    recipient
  end

  # === Push opt-in banner ===

  test "index shows the push opt-in banner when eligible" do
    @tenant.enable_feature_flag!(:web_push)
    sign_in_as(@user, tenant: @tenant)

    get "/notifications"

    assert_response :success
    assert_match "push-optin-banner", response.body
    assert_match "lock screen", response.body
  end

  test "index hides the banner when the web_push flag is off" do
    @tenant.disable_feature_flag!(:web_push)
    sign_in_as(@user, tenant: @tenant)

    get "/notifications"

    assert_no_match(/push-optin-banner/, response.body)
  end

  test "index hides the banner when the user already has an active subscription" do
    @tenant.enable_feature_flag!(:web_push)
    WebPushSubscription.upsert_for!(
      user: @user, endpoint: "https://push.example.com/send/here", p256dh_key: "k", auth_key: "a"
    )
    sign_in_as(@user, tenant: @tenant)

    get "/notifications"

    assert_no_match(/push-optin-banner/, response.body)
  end

  test "index hides the banner after the user dismisses it" do
    @tenant.enable_feature_flag!(:web_push)
    sign_in_as(@user, tenant: @tenant)

    post "/notifications/dismiss-push-banner"
    assert_response :redirect

    get "/notifications"

    assert_no_match(/push-optin-banner/, response.body)
  end

  test "dismiss-push-banner records the notice on the tenant_user" do
    @tenant.enable_feature_flag!(:web_push)
    sign_in_as(@user, tenant: @tenant)

    post "/notifications/dismiss-push-banner"

    tenant_user = @tenant.tenant_users.find_by(user: @user)
    assert_includes tenant_user.dismissed_notices, "push-optin-banner"
  end

  test "dismiss-push-banner requires authentication" do
    post "/notifications/dismiss-push-banner"

    assert_response :redirect
    tenant_user = @tenant.tenant_users.find_by(user: @user)
    assert_not_includes tenant_user.dismissed_notices, "push-optin-banner"
  end
end
