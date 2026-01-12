require "test_helper"

class NotificationServiceTest < ActiveSupport::TestCase
  test "create_and_deliver! creates notification and recipient" do
    tenant, studio, user = create_tenant_studio_user
    Studio.scope_thread_to_studio(subdomain: tenant.subdomain, handle: studio.handle)

    event = Event.create!(
      tenant: tenant,
      studio: studio,
      event_type: "note.created",
      actor: user,
    )

    assert_difference ["Notification.count", "NotificationRecipient.count"], 1 do
      notification = NotificationService.create_and_deliver!(
        event: event,
        recipient: user,
        notification_type: "mention",
        title: "Test notification",
        body: "Test body",
        url: "/n/abc123",
      )

      assert notification.persisted?
      assert_equal "mention", notification.notification_type
      assert_equal "Test notification", notification.title
      assert_equal "Test body", notification.body
      assert_equal "/n/abc123", notification.url
    end
  end

  test "create_and_deliver! creates recipients for multiple channels" do
    tenant, studio, user = create_tenant_studio_user
    Studio.scope_thread_to_studio(subdomain: tenant.subdomain, handle: studio.handle)

    event = Event.create!(
      tenant: tenant,
      studio: studio,
      event_type: "note.created",
      actor: user,
    )

    assert_difference "NotificationRecipient.count", 2 do
      NotificationService.create_and_deliver!(
        event: event,
        recipient: user,
        notification_type: "mention",
        title: "Test notification",
        channels: ["in_app", "email"],
      )
    end

    recipients = NotificationRecipient.where(user: user).to_a
    channels = recipients.map(&:channel)
    assert_includes channels, "in_app"
    assert_includes channels, "email"
  end

  test "unread_count_for returns correct count" do
    tenant, studio, user = create_tenant_studio_user
    Studio.scope_thread_to_studio(subdomain: tenant.subdomain, handle: studio.handle)

    event = Event.create!(tenant: tenant, studio: studio, event_type: "note.created")

    notification1 = Notification.create!(
      tenant: tenant,
      event: event,
      notification_type: "mention",
      title: "Test 1",
    )
    notification2 = Notification.create!(
      tenant: tenant,
      event: event,
      notification_type: "mention",
      title: "Test 2",
    )

    # Create 2 unread recipients
    NotificationRecipient.create!(notification: notification1, user: user, channel: "in_app", status: "pending")
    NotificationRecipient.create!(notification: notification2, user: user, channel: "in_app", status: "delivered")

    # Create 1 read recipient
    NotificationRecipient.create!(
      notification: notification1,
      user: user,
      channel: "in_app",
      status: "read",
      read_at: Time.current,
    )

    # Email recipients shouldn't be counted
    NotificationRecipient.create!(notification: notification1, user: user, channel: "email", status: "pending")

    assert_equal 2, NotificationService.unread_count_for(user)
  end

  test "mark_all_read_for marks all in_app notifications as read" do
    tenant, studio, user = create_tenant_studio_user
    Studio.scope_thread_to_studio(subdomain: tenant.subdomain, handle: studio.handle)

    event = Event.create!(tenant: tenant, studio: studio, event_type: "note.created")

    notification = Notification.create!(
      tenant: tenant,
      event: event,
      notification_type: "mention",
      title: "Test",
    )

    recipient1 = NotificationRecipient.create!(notification: notification, user: user, channel: "in_app", status: "pending")
    recipient2 = NotificationRecipient.create!(notification: notification, user: user, channel: "in_app", status: "delivered")
    email_recipient = NotificationRecipient.create!(notification: notification, user: user, channel: "email", status: "pending")

    NotificationService.mark_all_read_for(user)

    recipient1.reload
    recipient2.reload
    email_recipient.reload

    assert_equal "read", recipient1.status
    assert recipient1.read_at.present?
    assert_equal "read", recipient2.status
    assert recipient2.read_at.present?
    # Email should be unchanged
    assert_equal "pending", email_recipient.status
    assert_nil email_recipient.read_at
  end
end
