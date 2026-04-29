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
end
