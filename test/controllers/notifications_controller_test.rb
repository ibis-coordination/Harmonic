require "test_helper"

class NotificationsControllerTest < ActionDispatch::IntegrationTest
  def setup
    @tenant = @global_tenant
    @studio = @global_studio
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
    Studio.scope_thread_to_studio(subdomain: @tenant.subdomain, handle: @studio.handle)
    event = Event.create!(tenant: @tenant, studio: @studio, event_type: "test.created")
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
    Studio.clear_thread_scope

    get "/notifications"
    assert_response :success
    assert_match "Test notification", response.body
  end

  # === Unread Count Tests ===

  test "unread_count returns correct count" do
    sign_in_as(@user, tenant: @tenant)

    # Create unread notification
    Studio.scope_thread_to_studio(subdomain: @tenant.subdomain, handle: @studio.handle)
    event = Event.create!(tenant: @tenant, studio: @studio, event_type: "test.created")
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
    Studio.clear_thread_scope

    get "/notifications/unread_count", headers: { "Accept" => "application/json" }
    assert_response :success
    json_response = JSON.parse(response.body)
    assert_equal 1, json_response["count"]
  end

  # === Mark Read Tests ===

  test "mark_read marks notification as read" do
    sign_in_as(@user, tenant: @tenant)

    Studio.scope_thread_to_studio(subdomain: @tenant.subdomain, handle: @studio.handle)
    event = Event.create!(tenant: @tenant, studio: @studio, event_type: "test.created")
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
    Studio.clear_thread_scope

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

    Studio.scope_thread_to_studio(subdomain: @tenant.subdomain, handle: @studio.handle)
    event = Event.create!(tenant: @tenant, studio: @studio, event_type: "test.created")
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
    Studio.clear_thread_scope

    post "/notifications/actions/dismiss", params: { id: recipient.id }
    assert_response :success

    recipient.reload
    assert_equal "dismissed", recipient.status
    assert recipient.dismissed_at.present?
  end

  # === Mark All Read Tests ===

  test "mark_all_read marks all notifications as read" do
    sign_in_as(@user, tenant: @tenant)

    Studio.scope_thread_to_studio(subdomain: @tenant.subdomain, handle: @studio.handle)
    event = Event.create!(tenant: @tenant, studio: @studio, event_type: "test.created")
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
    Studio.clear_thread_scope

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
end
