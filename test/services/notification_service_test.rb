require "test_helper"

class NotificationServiceTest < ActiveSupport::TestCase
  test "create_and_deliver! creates notification and recipient" do
    tenant, collective, user = create_tenant_collective_user
    Collective.scope_thread_to_collective(subdomain: tenant.subdomain, handle: collective.handle)

    event = Event.create!(
      tenant: tenant,
      collective: collective,
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
    tenant, collective, user = create_tenant_collective_user
    Collective.scope_thread_to_collective(subdomain: tenant.subdomain, handle: collective.handle)

    event = Event.create!(
      tenant: tenant,
      collective: collective,
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
    tenant, collective, user = create_tenant_collective_user
    Collective.scope_thread_to_collective(subdomain: tenant.subdomain, handle: collective.handle)

    event = Event.create!(tenant: tenant, collective: collective, event_type: "note.created")

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

    # Create 1 dismissed recipient (should not be counted)
    NotificationRecipient.create!(
      notification: notification1,
      user: user,
      channel: "in_app",
      status: "dismissed",
      dismissed_at: Time.current,
    )

    # Email recipients shouldn't be counted
    NotificationRecipient.create!(notification: notification1, user: user, channel: "email", status: "pending")

    assert_equal 2, NotificationService.unread_count_for(user, tenant: tenant)
  end

  test "dismiss_all_for dismisses all in_app notifications" do
    tenant, collective, user = create_tenant_collective_user
    Collective.scope_thread_to_collective(subdomain: tenant.subdomain, handle: collective.handle)

    event = Event.create!(tenant: tenant, collective: collective, event_type: "note.created")

    notification = Notification.create!(
      tenant: tenant,
      event: event,
      notification_type: "mention",
      title: "Test",
    )

    recipient1 = NotificationRecipient.create!(notification: notification, user: user, channel: "in_app", status: "pending")
    recipient2 = NotificationRecipient.create!(notification: notification, user: user, channel: "in_app", status: "delivered")
    email_recipient = NotificationRecipient.create!(notification: notification, user: user, channel: "email", status: "pending")

    NotificationService.dismiss_all_for(user, tenant: tenant)

    recipient1.reload
    recipient2.reload
    email_recipient.reload

    assert_equal "dismissed", recipient1.status
    assert recipient1.dismissed_at.present?
    assert_equal "dismissed", recipient2.status
    assert recipient2.dismissed_at.present?
    # Email should be unchanged
    assert_equal "pending", email_recipient.status
    assert_nil email_recipient.dismissed_at
  end

  # === Tenant Scoping Tests ===
  #
  # These tests verify that notifications are properly scoped by tenant,
  # preventing cross-tenant data leakage when a user belongs to multiple tenants.

  test "unread_count_for only counts notifications from current tenant" do
    # Create two tenants with the same user in both
    tenant1, collective1, user = create_tenant_collective_user
    tenant2 = create_tenant(subdomain: "other-tenant", name: "Other Tenant")
    tenant2.add_user!(user)
    tenant2.create_main_collective!(created_by: user)
    collective2 = tenant2.main_collective

    # Create notifications in tenant1
    Collective.scope_thread_to_collective(subdomain: tenant1.subdomain, handle: collective1.handle)
    event1 = Event.create!(tenant: tenant1, collective: collective1, event_type: "note.created", actor: user)
    notification1 = Notification.create!(tenant: tenant1, event: event1, notification_type: "mention", title: "Tenant1 notification")
    NotificationRecipient.create!(notification: notification1, user: user, channel: "in_app", status: "pending", tenant: tenant1)

    # Create notifications in tenant2
    Collective.scope_thread_to_collective(subdomain: tenant2.subdomain, handle: collective2.handle)
    event2 = Event.create!(tenant: tenant2, collective: collective2, event_type: "note.created", actor: user)
    notification2 = Notification.create!(tenant: tenant2, event: event2, notification_type: "mention", title: "Tenant2 notification")
    NotificationRecipient.create!(notification: notification2, user: user, channel: "in_app", status: "pending", tenant: tenant2)
    NotificationRecipient.create!(notification: notification2, user: user, channel: "in_app", status: "pending", tenant: tenant2)

    # When querying tenant1, should only see tenant1's notification (count = 1)
    Collective.scope_thread_to_collective(subdomain: tenant1.subdomain, handle: collective1.handle)
    assert_equal 1, NotificationService.unread_count_for(user, tenant: tenant1), "Should only count notifications from tenant1"

    # When querying tenant2, should only see tenant2's notifications (count = 2)
    Collective.scope_thread_to_collective(subdomain: tenant2.subdomain, handle: collective2.handle)
    assert_equal 2, NotificationService.unread_count_for(user, tenant: tenant2), "Should only count notifications from tenant2"
  end

  test "dismiss_all_for only dismisses notifications in current tenant" do
    # Create two tenants with the same user in both
    tenant1, collective1, user = create_tenant_collective_user
    tenant2 = create_tenant(subdomain: "other-tenant", name: "Other Tenant")
    tenant2.add_user!(user)
    tenant2.create_main_collective!(created_by: user)
    collective2 = tenant2.main_collective

    # Create notification in tenant1
    Collective.scope_thread_to_collective(subdomain: tenant1.subdomain, handle: collective1.handle)
    event1 = Event.create!(tenant: tenant1, collective: collective1, event_type: "note.created", actor: user)
    notification1 = Notification.create!(tenant: tenant1, event: event1, notification_type: "mention", title: "Tenant1 notification")
    recipient1 = NotificationRecipient.create!(notification: notification1, user: user, channel: "in_app", status: "pending", tenant: tenant1)

    # Create notification in tenant2
    Collective.scope_thread_to_collective(subdomain: tenant2.subdomain, handle: collective2.handle)
    event2 = Event.create!(tenant: tenant2, collective: collective2, event_type: "note.created", actor: user)
    notification2 = Notification.create!(tenant: tenant2, event: event2, notification_type: "mention", title: "Tenant2 notification")
    recipient2 = NotificationRecipient.create!(notification: notification2, user: user, channel: "in_app", status: "pending", tenant: tenant2)

    # Dismiss all for tenant1
    Collective.scope_thread_to_collective(subdomain: tenant1.subdomain, handle: collective1.handle)
    NotificationService.dismiss_all_for(user, tenant: tenant1)

    recipient1.reload
    recipient2.reload

    # Tenant1 notification should be dismissed
    assert_equal "dismissed", recipient1.status, "Tenant1 notification should be dismissed"
    assert recipient1.dismissed_at.present?, "Tenant1 notification should have dismissed_at set"

    # Tenant2 notification should still be pending
    assert_equal "pending", recipient2.status, "Tenant2 notification should still be pending"
    assert_nil recipient2.dismissed_at, "Tenant2 notification should not have dismissed_at set"
  end

  # === Studio Grouping Tests ===

  test "dismiss_all_for_collective only dismisses notifications for that studio" do
    tenant, collective1, user = create_tenant_collective_user
    Collective.scope_thread_to_collective(subdomain: tenant.subdomain, handle: collective1.handle)

    # Create a second studio
    collective2 = Collective.create!(tenant: tenant, name: "Second Studio", handle: "second-studio", created_by: user)

    # Create notifications in studio 1
    event1 = Event.create!(tenant: tenant, collective: collective1, event_type: "note.created", actor: user)
    notification1 = Notification.create!(tenant: tenant, event: event1, notification_type: "mention", title: "Studio1 notification")
    recipient1 = NotificationRecipient.create!(notification: notification1, user: user, channel: "in_app", status: "pending", tenant: tenant)

    # Create notifications in studio 2
    event2 = Event.create!(tenant: tenant, collective: collective2, event_type: "note.created", actor: user)
    notification2 = Notification.create!(tenant: tenant, event: event2, notification_type: "mention", title: "Studio2 notification")
    recipient2 = NotificationRecipient.create!(notification: notification2, user: user, channel: "in_app", status: "pending", tenant: tenant)

    # Dismiss all for studio 1
    count = NotificationService.dismiss_all_for_collective(user, tenant: tenant, collective_id: collective1.id)

    assert_equal 1, count, "Should have dismissed 1 notification"

    recipient1.reload
    recipient2.reload

    # Studio 1 notification should be dismissed
    assert_equal "dismissed", recipient1.status
    assert recipient1.dismissed_at.present?

    # Studio 2 notification should still be pending
    assert_equal "pending", recipient2.status
    assert_nil recipient2.dismissed_at
  end

  test "dismiss_all_for_collective returns count of dismissed notifications" do
    tenant, collective, user = create_tenant_collective_user
    Collective.scope_thread_to_collective(subdomain: tenant.subdomain, handle: collective.handle)

    event = Event.create!(tenant: tenant, collective: collective, event_type: "note.created", actor: user)
    notification = Notification.create!(tenant: tenant, event: event, notification_type: "mention", title: "Test")

    # Create 3 recipients
    NotificationRecipient.create!(notification: notification, user: user, channel: "in_app", status: "pending", tenant: tenant)
    NotificationRecipient.create!(notification: notification, user: user, channel: "in_app", status: "delivered", tenant: tenant)
    NotificationRecipient.create!(notification: notification, user: user, channel: "in_app", status: "pending", tenant: tenant)

    count = NotificationService.dismiss_all_for_collective(user, tenant: tenant, collective_id: collective.id)

    assert_equal 3, count
  end

  test "dismiss_all_reminders only dismisses due reminders without events" do
    tenant, collective, user = create_tenant_collective_user
    Collective.scope_thread_to_collective(subdomain: tenant.subdomain, handle: collective.handle)
    Tenant.current_id = tenant.id

    # Create a reminder (notification without event)
    reminder_notification = Notification.create!(tenant: tenant, event: nil, notification_type: "reminder", title: "Due reminder")
    reminder_recipient = NotificationRecipient.create!(notification: reminder_notification, user: user, channel: "in_app", status: "pending", tenant: tenant)

    # Create a normal notification with an event
    event = Event.create!(tenant: tenant, collective: collective, event_type: "note.created", actor: user)
    normal_notification = Notification.create!(tenant: tenant, event: event, notification_type: "mention", title: "Normal notification")
    normal_recipient = NotificationRecipient.create!(notification: normal_notification, user: user, channel: "in_app", status: "pending", tenant: tenant)

    # Dismiss all reminders
    count = NotificationService.dismiss_all_reminders(user, tenant: tenant)

    assert_equal 1, count, "Should have dismissed 1 reminder"

    reminder_recipient.reload
    normal_recipient.reload

    # Reminder should be dismissed
    assert_equal "dismissed", reminder_recipient.status
    assert reminder_recipient.dismissed_at.present?

    # Normal notification should still be pending
    assert_equal "pending", normal_recipient.status
    assert_nil normal_recipient.dismissed_at
  end
end
