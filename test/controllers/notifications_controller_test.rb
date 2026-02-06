require "test_helper"

class NotificationsControllerTest < ActionDispatch::IntegrationTest
  def setup
    @tenant = @global_tenant
    @superagent = @global_superagent
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
    Superagent.scope_thread_to_superagent(subdomain: @tenant.subdomain, handle: @superagent.handle)
    event = Event.create!(tenant: @tenant, superagent: @superagent, event_type: "test.created")
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
    Superagent.clear_thread_scope

    get "/notifications"
    assert_response :success
    assert_match "Test notification", response.body
  end

  # === Unread Count Tests ===

  test "unread_count returns correct count" do
    sign_in_as(@user, tenant: @tenant)

    # Create unread notification
    Superagent.scope_thread_to_superagent(subdomain: @tenant.subdomain, handle: @superagent.handle)
    event = Event.create!(tenant: @tenant, superagent: @superagent, event_type: "test.created")
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
    Superagent.clear_thread_scope

    get "/notifications/unread_count", headers: { "Accept" => "application/json" }
    assert_response :success
    json_response = JSON.parse(response.body)
    assert_equal 1, json_response["count"]
  end

  # === Dismiss Tests ===

  test "dismiss dismisses notification" do
    sign_in_as(@user, tenant: @tenant)

    Superagent.scope_thread_to_superagent(subdomain: @tenant.subdomain, handle: @superagent.handle)
    event = Event.create!(tenant: @tenant, superagent: @superagent, event_type: "test.created")
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
    Superagent.clear_thread_scope

    post "/notifications/actions/dismiss", params: { id: recipient.id }
    assert_response :success

    recipient.reload
    assert_equal "dismissed", recipient.status
    assert recipient.dismissed_at.present?
  end

  # === Dismiss All Tests ===

  test "dismiss_all dismisses all notifications" do
    sign_in_as(@user, tenant: @tenant)

    Superagent.scope_thread_to_superagent(subdomain: @tenant.subdomain, handle: @superagent.handle)
    event = Event.create!(tenant: @tenant, superagent: @superagent, event_type: "test.created")
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
    Superagent.clear_thread_scope

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

  # === Scheduled Reminders Tests ===

  test "index shows scheduled reminders section" do
    sign_in_as(@user, tenant: @tenant)

    Superagent.scope_thread_to_superagent(subdomain: @tenant.subdomain, handle: @superagent.handle)
    Tenant.current_id = @tenant.id
    ReminderService.create!(user: @user, title: "Future reminder", scheduled_for: 1.day.from_now)
    Superagent.clear_thread_scope

    get "/notifications"
    assert_response :success
    assert_includes response.body, "Scheduled Reminders"
    assert_includes response.body, "Future reminder"
  end

  test "index does not show scheduled reminders section when empty" do
    sign_in_as(@user, tenant: @tenant)

    get "/notifications"
    assert_response :success
    assert_not_includes response.body, "Scheduled Reminders"
  end

  test "index always shows Schedule Reminder button" do
    sign_in_as(@user, tenant: @tenant)

    get "/notifications"
    assert_response :success
    assert_includes response.body, "Schedule Reminder"
    assert_includes response.body, "/notifications/new"
  end

  test "new page shows reminder creation form" do
    sign_in_as(@user, tenant: @tenant)

    get "/notifications/new"
    assert_response :success
    assert_includes response.body, "New Reminder"
    assert_includes response.body, "title"
    assert_includes response.body, "scheduled_for"
  end

  test "new page markdown shows action description" do
    sign_in_as(@user, tenant: @tenant)

    get "/notifications/new", headers: { "Accept" => "text/markdown" }
    assert_response :success
    assert_includes response.body, "# New Reminder"
    assert_includes response.body, "create_reminder"
  end

  test "scheduled reminders do not appear in immediate notifications list" do
    sign_in_as(@user, tenant: @tenant)

    Superagent.scope_thread_to_superagent(subdomain: @tenant.subdomain, handle: @superagent.handle)
    Tenant.current_id = @tenant.id
    ReminderService.create!(user: @user, title: "Scheduled Only", scheduled_for: 1.day.from_now)
    Superagent.clear_thread_scope

    get "/notifications"
    assert_response :success

    # The reminder should appear in the scheduled section only
    # Not in the main notification list (which shows immediate notifications)
    assert_includes response.body, "Scheduled Only"
  end

  test "scheduled reminders do not count in unread notification count" do
    sign_in_as(@user, tenant: @tenant)

    # Start with zero unread notifications
    get "/notifications/unread_count", headers: { "Accept" => "application/json" }
    json = JSON.parse(response.body)
    assert_equal 0, json["count"], "Should start with 0 unread"

    # Create a scheduled reminder for the future
    Superagent.scope_thread_to_superagent(subdomain: @tenant.subdomain, handle: @superagent.handle)
    Tenant.current_id = @tenant.id
    ReminderService.create!(user: @user, title: "Future reminder", scheduled_for: 1.day.from_now)
    Superagent.clear_thread_scope

    # The scheduled reminder should NOT count in unread count
    get "/notifications/unread_count", headers: { "Accept" => "application/json" }
    json = JSON.parse(response.body)
    assert_equal 0, json["count"], "Scheduled future reminder should not count as unread"
  end

  test "dismiss_all does not affect scheduled reminders" do
    sign_in_as(@user, tenant: @tenant)

    # Create a scheduled reminder for the future
    Superagent.scope_thread_to_superagent(subdomain: @tenant.subdomain, handle: @superagent.handle)
    Tenant.current_id = @tenant.id
    notification = ReminderService.create!(user: @user, title: "Future reminder", scheduled_for: 1.day.from_now)
    nr = notification.notification_recipients.first
    Superagent.clear_thread_scope

    # Dismiss all
    post "/notifications/actions/dismiss_all"
    assert_response :success

    # The scheduled reminder should still be in pending state
    nr.reload
    assert_equal "pending", nr.status, "Scheduled reminder should still be pending"
    assert_nil nr.dismissed_at, "Scheduled reminder should not be dismissed"
  end

  test "notifications page does not show dismiss all button when only scheduled reminders exist" do
    sign_in_as(@user, tenant: @tenant)

    # Create a scheduled reminder for the future
    Superagent.scope_thread_to_superagent(subdomain: @tenant.subdomain, handle: @superagent.handle)
    Tenant.current_id = @tenant.id
    ReminderService.create!(user: @user, title: "Future reminder", scheduled_for: 1.day.from_now)
    Superagent.clear_thread_scope

    get "/notifications"
    assert_response :success

    # Page title should NOT show unread count in parentheses
    assert_not_includes response.body, "<title>(1) Notifications</title>"
    # Should NOT show "Dismiss all" button
    assert_not_includes response.body, "Dismiss all"
    # Should show the scheduled reminder in the scheduled section
    assert_includes response.body, "Scheduled Reminders"
    assert_includes response.body, "Future reminder"
  end

  # === Create Reminder Action Tests ===

  test "describe_create_reminder returns action description" do
    sign_in_as(@user, tenant: @tenant)

    get "/notifications/actions/create_reminder", headers: { "Accept" => "text/markdown" }
    assert_response :success
    assert_includes response.body, "create_reminder"
    assert_includes response.body, "scheduled_for"
  end

  test "create_reminder action requires title" do
    sign_in_as(@user, tenant: @tenant)

    post "/notifications/actions/create_reminder",
      params: { scheduled_for: 1.day.from_now.iso8601 },
      headers: { "Accept" => "text/markdown" }

    assert_includes response.body, "Title is required"
  end

  test "create_reminder action requires scheduled_for" do
    sign_in_as(@user, tenant: @tenant)

    post "/notifications/actions/create_reminder",
      params: { title: "Test" },
      headers: { "Accept" => "text/markdown" }

    assert_includes response.body, "scheduled_for is required"
  end

  test "create_reminder action creates reminder with ISO 8601 datetime" do
    sign_in_as(@user, tenant: @tenant)

    assert_difference "Notification.count" do
      post "/notifications/actions/create_reminder",
        params: {
          title: "Remember this",
          body: "Important details",
          scheduled_for: 1.day.from_now.iso8601,
        },
        headers: { "Accept" => "text/markdown" }
    end

    notification = Notification.last
    assert_equal "reminder", notification.notification_type
    assert_equal "Remember this", notification.title
  end

  test "create_reminder action creates reminder with Unix timestamp" do
    sign_in_as(@user, tenant: @tenant)

    future_time = 1.day.from_now.to_i

    assert_difference "Notification.count" do
      post "/notifications/actions/create_reminder",
        params: {
          title: "Unix timestamp reminder",
          scheduled_for: future_time.to_s,
        },
        headers: { "Accept" => "text/markdown" }
    end

    notification = Notification.last
    assert_equal "Unix timestamp reminder", notification.title
  end

  test "create_reminder action uses timezone parameter for datetime-local values" do
    sign_in_as(@user, tenant: @tenant)

    # Submit a datetime-local value (no timezone info) with explicit timezone
    # Use a time 1 day from now in a specific timezone
    future_date = 1.day.from_now.strftime("%Y-%m-%dT%H:%M")

    post "/notifications/actions/create_reminder",
      params: {
        title: "Timezone test",
        scheduled_for: future_date,
        timezone: "Pacific Time (US & Canada)",
      },
      headers: { "Accept" => "application/json" }

    assert_response :success
    json = JSON.parse(response.body)
    assert json["success"], "Expected success but got: #{response.body}"

    notification = Notification.last
    nr = notification.notification_recipients.first

    # The time should be parsed in Pacific timezone and stored as UTC
    expected_utc = ActiveSupport::TimeZone["Pacific Time (US & Canada)"].parse(future_date).utc
    assert_equal expected_utc, nr.scheduled_for
  end

  test "create_reminder action creates reminder with relative time" do
    sign_in_as(@user, tenant: @tenant)

    assert_difference "Notification.count" do
      post "/notifications/actions/create_reminder",
        params: {
          title: "Relative time reminder",
          scheduled_for: "2h",
        },
        headers: { "Accept" => "text/markdown" }
    end

    notification = Notification.last
    assert_equal "Relative time reminder", notification.title

    nr = notification.notification_recipients.first
    # Should be approximately 2 hours from now
    assert_in_delta 2.hours.from_now, nr.scheduled_for, 5.seconds
  end

  test "create_reminder action supports various relative time formats" do
    sign_in_as(@user, tenant: @tenant)

    [
      ["30m", 30.minutes],
      ["1h", 1.hour],
      ["2d", 2.days],
      ["1w", 1.week],
    ].each do |input, expected_duration|
      expected_time = expected_duration.from_now
      post "/notifications/actions/create_reminder",
        params: { title: "Test #{input}", scheduled_for: input },
        headers: { "Accept" => "text/markdown" }

      # Find by title to ensure we get the right notification
      notification = Notification.find_by(title: "Test #{input}")
      nr = notification.notification_recipients.first
      assert_in_delta expected_time, nr.scheduled_for, 5.seconds,
        "Failed for input: #{input}"
    end
  end

  test "create_reminder markdown response includes scheduled time" do
    sign_in_as(@user, tenant: @tenant)

    post "/notifications/actions/create_reminder",
      params: { title: "Test", scheduled_for: 1.day.from_now.iso8601 },
      headers: { "Accept" => "text/markdown" }

    assert_response :success
    assert_includes response.body, "Reminder scheduled"
  end

  test "create_reminder JSON response includes id and scheduled_for" do
    sign_in_as(@user, tenant: @tenant)

    post "/notifications/actions/create_reminder",
      params: { title: "Test", scheduled_for: 1.day.from_now.iso8601 },
      headers: { "Accept" => "application/json" }

    assert_response :success
    json = JSON.parse(response.body)
    assert json["success"]
    assert json["id"].present?
    assert json["scheduled_for"].present?
  end

  # === Delete Reminder Action Tests ===

  test "describe_delete_reminder returns action description" do
    sign_in_as(@user, tenant: @tenant)

    get "/notifications/actions/delete_reminder", headers: { "Accept" => "text/markdown" }
    assert_response :success
    assert_includes response.body, "delete_reminder"
  end

  test "delete_reminder removes the reminder" do
    sign_in_as(@user, tenant: @tenant)

    Superagent.scope_thread_to_superagent(subdomain: @tenant.subdomain, handle: @superagent.handle)
    Tenant.current_id = @tenant.id
    notification = ReminderService.create!(user: @user, title: "To delete", scheduled_for: 1.day.from_now)
    nr = notification.notification_recipients.first
    Superagent.clear_thread_scope

    assert_difference "NotificationRecipient.count", -1 do
      post "/notifications/actions/delete_reminder",
        params: { id: nr.id },
        headers: { "Accept" => "text/markdown" }
    end

    assert_includes response.body, "Reminder deleted"
  end

  test "delete_reminder returns error for non-existent reminder" do
    sign_in_as(@user, tenant: @tenant)

    post "/notifications/actions/delete_reminder",
      params: { id: "nonexistent-uuid" },
      headers: { "Accept" => "text/markdown" }

    assert_includes response.body, "Reminder not found"
  end

  test "delete_reminder cannot delete other user's reminder" do
    other_user = create_user(name: "Other Notification User")
    @tenant.add_user!(other_user)
    @superagent.add_user!(other_user)

    Superagent.scope_thread_to_superagent(subdomain: @tenant.subdomain, handle: @superagent.handle)
    Tenant.current_id = @tenant.id
    notification = ReminderService.create!(user: other_user, title: "Other's reminder", scheduled_for: 1.day.from_now)
    nr = notification.notification_recipients.first
    Superagent.clear_thread_scope

    sign_in_as(@user, tenant: @tenant)

    assert_no_difference "NotificationRecipient.count" do
      post "/notifications/actions/delete_reminder",
        params: { id: nr.id },
        headers: { "Accept" => "text/markdown" }
    end

    assert_includes response.body, "Reminder not found"
  end

  # === Markdown Scheduled Reminders Tests ===

  test "markdown index shows scheduled reminders table" do
    sign_in_as(@user, tenant: @tenant)

    Superagent.scope_thread_to_superagent(subdomain: @tenant.subdomain, handle: @superagent.handle)
    Tenant.current_id = @tenant.id
    ReminderService.create!(user: @user, title: "MD Reminder", scheduled_for: 1.day.from_now)
    Superagent.clear_thread_scope

    get "/notifications", headers: { "Accept" => "text/markdown" }
    assert_response :success
    assert_includes response.body, "## Scheduled Reminders"
    assert_includes response.body, "MD Reminder"
  end

  test "markdown actions list includes reminder actions" do
    sign_in_as(@user, tenant: @tenant)

    get "/notifications", headers: { "Accept" => "text/markdown" }
    assert_response :success
    assert_includes response.body, "create_reminder"
    assert_includes response.body, "delete_reminder"
  end

  # === Dismiss For Studio Tests ===

  test "dismiss_for_studio dismisses notifications for specific studio" do
    sign_in_as(@user, tenant: @tenant)

    Superagent.scope_thread_to_superagent(subdomain: @tenant.subdomain, handle: @superagent.handle)

    # Create a second studio
    superagent2 = Superagent.create!(tenant: @tenant, name: "Second Studio", handle: "second-studio", created_by: @user)

    # Create notifications in first studio
    event1 = Event.create!(tenant: @tenant, superagent: @superagent, event_type: "test.created")
    notification1 = Notification.create!(tenant: @tenant, event: event1, notification_type: "mention", title: "Studio1 Notification")
    recipient1 = NotificationRecipient.create!(notification: notification1, user: @user, channel: "in_app", status: "pending")

    # Create notifications in second studio
    event2 = Event.create!(tenant: @tenant, superagent: superagent2, event_type: "test.created")
    notification2 = Notification.create!(tenant: @tenant, event: event2, notification_type: "mention", title: "Studio2 Notification")
    recipient2 = NotificationRecipient.create!(notification: notification2, user: @user, channel: "in_app", status: "pending")

    Superagent.clear_thread_scope

    # Dismiss only first studio's notifications
    post "/notifications/actions/dismiss_for_studio", params: { studio_id: @superagent.id }
    assert_response :success

    recipient1.reload
    recipient2.reload

    # First studio notification should be dismissed
    assert_equal "dismissed", recipient1.status
    assert recipient1.dismissed_at.present?

    # Second studio notification should still be pending
    assert_equal "pending", recipient2.status
    assert_nil recipient2.dismissed_at
  end

  test "dismiss_for_studio with reminders dismisses due reminders only" do
    sign_in_as(@user, tenant: @tenant)

    Superagent.scope_thread_to_superagent(subdomain: @tenant.subdomain, handle: @superagent.handle)
    Tenant.current_id = @tenant.id

    # Create a due reminder (notification without event)
    reminder_notification = Notification.create!(tenant: @tenant, event: nil, notification_type: "reminder", title: "Due reminder")
    reminder_recipient = NotificationRecipient.create!(notification: reminder_notification, user: @user, channel: "in_app", status: "pending")

    # Create a normal notification with an event
    event = Event.create!(tenant: @tenant, superagent: @superagent, event_type: "test.created")
    normal_notification = Notification.create!(tenant: @tenant, event: event, notification_type: "mention", title: "Normal notification")
    normal_recipient = NotificationRecipient.create!(notification: normal_notification, user: @user, channel: "in_app", status: "pending")

    Superagent.clear_thread_scope

    # Dismiss reminders using "reminders" as studio_id
    post "/notifications/actions/dismiss_for_studio", params: { studio_id: "reminders" }
    assert_response :success

    reminder_recipient.reload
    normal_recipient.reload

    # Reminder should be dismissed
    assert_equal "dismissed", reminder_recipient.status

    # Normal notification should still be pending
    assert_equal "pending", normal_recipient.status
  end

  test "dismiss_for_studio returns error for invalid studio" do
    sign_in_as(@user, tenant: @tenant)

    post "/notifications/actions/dismiss_for_studio", params: { studio_id: 99999 }
    assert_response :not_found

    json_response = JSON.parse(response.body)
    assert_equal false, json_response["success"]
    assert_equal "Studio not found.", json_response["error"]
  end

  test "dismiss_for_studio returns count in JSON response" do
    sign_in_as(@user, tenant: @tenant)

    Superagent.scope_thread_to_superagent(subdomain: @tenant.subdomain, handle: @superagent.handle)

    event = Event.create!(tenant: @tenant, superagent: @superagent, event_type: "test.created")
    notification = Notification.create!(tenant: @tenant, event: event, notification_type: "mention", title: "Test")

    # Create 3 recipients
    NotificationRecipient.create!(notification: notification, user: @user, channel: "in_app", status: "pending")
    NotificationRecipient.create!(notification: notification, user: @user, channel: "in_app", status: "delivered")
    NotificationRecipient.create!(notification: notification, user: @user, channel: "in_app", status: "pending")

    Superagent.clear_thread_scope

    post "/notifications/actions/dismiss_for_studio", params: { studio_id: @superagent.id }
    assert_response :success

    json_response = JSON.parse(response.body)
    assert_equal true, json_response["success"]
    assert_equal 3, json_response["count"]
  end

  # === Notifications Grouped by Studio Tests ===

  test "index groups notifications by studio in HTML" do
    sign_in_as(@user, tenant: @tenant)

    Superagent.scope_thread_to_superagent(subdomain: @tenant.subdomain, handle: @superagent.handle)

    # Create a second studio
    superagent2 = Superagent.create!(tenant: @tenant, name: "Second Studio", handle: "second-studio", created_by: @user)

    # Create notifications in first studio
    event1 = Event.create!(tenant: @tenant, superagent: @superagent, event_type: "test.created")
    notification1 = Notification.create!(tenant: @tenant, event: event1, notification_type: "mention", title: "Studio1 Notification")
    NotificationRecipient.create!(notification: notification1, user: @user, channel: "in_app", status: "pending")

    # Create notifications in second studio
    event2 = Event.create!(tenant: @tenant, superagent: superagent2, event_type: "test.created")
    notification2 = Notification.create!(tenant: @tenant, event: event2, notification_type: "mention", title: "Studio2 Notification")
    NotificationRecipient.create!(notification: notification2, user: @user, channel: "in_app", status: "pending")

    Superagent.clear_thread_scope

    get "/notifications"
    assert_response :success

    # Should show both studio names in accordion headers
    assert_includes response.body, @superagent.name
    assert_includes response.body, "Second Studio"
    assert_includes response.body, "pulse-accordion"
    assert_includes response.body, "data-superagent-group"
  end

  test "index groups notifications by studio in markdown" do
    sign_in_as(@user, tenant: @tenant)

    Superagent.scope_thread_to_superagent(subdomain: @tenant.subdomain, handle: @superagent.handle)

    # Create a second studio
    superagent2 = Superagent.create!(tenant: @tenant, name: "Second Studio", handle: "second-studio", created_by: @user)

    # Create notifications in first studio
    event1 = Event.create!(tenant: @tenant, superagent: @superagent, event_type: "test.created")
    notification1 = Notification.create!(tenant: @tenant, event: event1, notification_type: "mention", title: "Studio1 Notification")
    NotificationRecipient.create!(notification: notification1, user: @user, channel: "in_app", status: "pending")

    # Create notifications in second studio
    event2 = Event.create!(tenant: @tenant, superagent: superagent2, event_type: "test.created")
    notification2 = Notification.create!(tenant: @tenant, event: event2, notification_type: "mention", title: "Studio2 Notification")
    NotificationRecipient.create!(notification: notification2, user: @user, channel: "in_app", status: "pending")

    Superagent.clear_thread_scope

    get "/notifications", headers: { "Accept" => "text/markdown" }
    assert_response :success

    # Should show studio names as markdown headers
    assert_includes response.body, "### #{@superagent.name}"
    assert_includes response.body, "### Second Studio"
    assert_includes response.body, "dismiss_for_studio"
  end
end
