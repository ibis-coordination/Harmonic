require "test_helper"

class NotificationServiceTest < ActiveSupport::TestCase
  test "create_and_deliver! creates notification and recipient" do
    tenant, superagent, user = create_tenant_superagent_user
    Superagent.scope_thread_to_superagent(subdomain: tenant.subdomain, handle: superagent.handle)

    event = Event.create!(
      tenant: tenant,
      superagent: superagent,
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
    tenant, superagent, user = create_tenant_superagent_user
    Superagent.scope_thread_to_superagent(subdomain: tenant.subdomain, handle: superagent.handle)

    event = Event.create!(
      tenant: tenant,
      superagent: superagent,
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
    tenant, superagent, user = create_tenant_superagent_user
    Superagent.scope_thread_to_superagent(subdomain: tenant.subdomain, handle: superagent.handle)

    event = Event.create!(tenant: tenant, superagent: superagent, event_type: "note.created")

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

    assert_equal 2, NotificationService.unread_count_for(user, tenant: tenant)
  end

  test "mark_all_read_for marks all in_app notifications as read" do
    tenant, superagent, user = create_tenant_superagent_user
    Superagent.scope_thread_to_superagent(subdomain: tenant.subdomain, handle: superagent.handle)

    event = Event.create!(tenant: tenant, superagent: superagent, event_type: "note.created")

    notification = Notification.create!(
      tenant: tenant,
      event: event,
      notification_type: "mention",
      title: "Test",
    )

    recipient1 = NotificationRecipient.create!(notification: notification, user: user, channel: "in_app", status: "pending")
    recipient2 = NotificationRecipient.create!(notification: notification, user: user, channel: "in_app", status: "delivered")
    email_recipient = NotificationRecipient.create!(notification: notification, user: user, channel: "email", status: "pending")

    NotificationService.mark_all_read_for(user, tenant: tenant)

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

  # === Tenant Scoping Tests ===
  #
  # These tests verify that notifications are properly scoped by tenant,
  # preventing cross-tenant data leakage when a user belongs to multiple tenants.

  test "unread_count_for only counts notifications from current tenant" do
    # Create two tenants with the same user in both
    tenant1, superagent1, user = create_tenant_superagent_user
    tenant2 = create_tenant(subdomain: "other-tenant", name: "Other Tenant")
    tenant2.add_user!(user)
    tenant2.create_main_superagent!(created_by: user)
    superagent2 = tenant2.main_superagent

    # Create notifications in tenant1
    Superagent.scope_thread_to_superagent(subdomain: tenant1.subdomain, handle: superagent1.handle)
    event1 = Event.create!(tenant: tenant1, superagent: superagent1, event_type: "note.created", actor: user)
    notification1 = Notification.create!(tenant: tenant1, event: event1, notification_type: "mention", title: "Tenant1 notification")
    NotificationRecipient.create!(notification: notification1, user: user, channel: "in_app", status: "pending", tenant: tenant1)

    # Create notifications in tenant2
    Superagent.scope_thread_to_superagent(subdomain: tenant2.subdomain, handle: superagent2.handle)
    event2 = Event.create!(tenant: tenant2, superagent: superagent2, event_type: "note.created", actor: user)
    notification2 = Notification.create!(tenant: tenant2, event: event2, notification_type: "mention", title: "Tenant2 notification")
    NotificationRecipient.create!(notification: notification2, user: user, channel: "in_app", status: "pending", tenant: tenant2)
    NotificationRecipient.create!(notification: notification2, user: user, channel: "in_app", status: "pending", tenant: tenant2)

    # When querying tenant1, should only see tenant1's notification (count = 1)
    Superagent.scope_thread_to_superagent(subdomain: tenant1.subdomain, handle: superagent1.handle)
    assert_equal 1, NotificationService.unread_count_for(user, tenant: tenant1), "Should only count notifications from tenant1"

    # When querying tenant2, should only see tenant2's notifications (count = 2)
    Superagent.scope_thread_to_superagent(subdomain: tenant2.subdomain, handle: superagent2.handle)
    assert_equal 2, NotificationService.unread_count_for(user, tenant: tenant2), "Should only count notifications from tenant2"
  end

  test "mark_all_read_for only marks notifications in current tenant as read" do
    # Create two tenants with the same user in both
    tenant1, superagent1, user = create_tenant_superagent_user
    tenant2 = create_tenant(subdomain: "other-tenant", name: "Other Tenant")
    tenant2.add_user!(user)
    tenant2.create_main_superagent!(created_by: user)
    superagent2 = tenant2.main_superagent

    # Create notification in tenant1
    Superagent.scope_thread_to_superagent(subdomain: tenant1.subdomain, handle: superagent1.handle)
    event1 = Event.create!(tenant: tenant1, superagent: superagent1, event_type: "note.created", actor: user)
    notification1 = Notification.create!(tenant: tenant1, event: event1, notification_type: "mention", title: "Tenant1 notification")
    recipient1 = NotificationRecipient.create!(notification: notification1, user: user, channel: "in_app", status: "pending", tenant: tenant1)

    # Create notification in tenant2
    Superagent.scope_thread_to_superagent(subdomain: tenant2.subdomain, handle: superagent2.handle)
    event2 = Event.create!(tenant: tenant2, superagent: superagent2, event_type: "note.created", actor: user)
    notification2 = Notification.create!(tenant: tenant2, event: event2, notification_type: "mention", title: "Tenant2 notification")
    recipient2 = NotificationRecipient.create!(notification: notification2, user: user, channel: "in_app", status: "pending", tenant: tenant2)

    # Mark all read for tenant1
    Superagent.scope_thread_to_superagent(subdomain: tenant1.subdomain, handle: superagent1.handle)
    NotificationService.mark_all_read_for(user, tenant: tenant1)

    recipient1.reload
    recipient2.reload

    # Tenant1 notification should be marked as read
    assert_equal "read", recipient1.status, "Tenant1 notification should be marked as read"
    assert recipient1.read_at.present?, "Tenant1 notification should have read_at set"

    # Tenant2 notification should still be unread
    assert_equal "pending", recipient2.status, "Tenant2 notification should still be pending"
    assert_nil recipient2.read_at, "Tenant2 notification should not have read_at set"
  end
end
