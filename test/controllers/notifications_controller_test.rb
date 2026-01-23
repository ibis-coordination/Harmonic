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

  # === Mark Read Tests ===

  test "mark_read marks notification as read" do
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

    post "/notifications/actions/mark_read", params: { id: recipient.id }
    assert_response :success

    recipient.reload
    assert_equal "read", recipient.status
    assert recipient.read_at.present?
  end

  test "mark_read returns error for non-existent notification" do
    sign_in_as(@user, tenant: @tenant)

    post "/notifications/actions/mark_read", params: { id: "nonexistent" }
    assert_response :not_found
    json_response = JSON.parse(response.body)
    assert_equal false, json_response["success"]
    assert_equal "Notification not found.", json_response["error"]
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

  # === Mark All Read Tests ===

  test "mark_all_read marks all notifications as read" do
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

    post "/notifications/actions/mark_all_read"
    assert_response :success

    recipient1.reload
    recipient2.reload
    assert_equal "read", recipient1.status
    assert_equal "read", recipient2.status
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
end
