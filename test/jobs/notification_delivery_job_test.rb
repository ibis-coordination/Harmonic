require "test_helper"

class NotificationDeliveryJobTest < ActiveSupport::TestCase
  test "perform marks in_app recipient as delivered" do
    tenant, collective, user = create_tenant_collective_user
    Collective.scope_thread_to_collective(subdomain: tenant.subdomain, handle: collective.handle)

    event = Event.create!(tenant: tenant, collective: collective, event_type: "note.created")
    notification = Notification.create!(
      tenant: tenant,
      event: event,
      notification_type: "mention",
      title: "Test",
    )

    recipient = NotificationRecipient.create!(
      notification: notification,
      user: user,
      channel: "in_app",
      status: "pending",
    )

    NotificationDeliveryJob.perform_now(recipient.id)

    recipient.reload
    assert_equal "delivered", recipient.status
    assert recipient.delivered_at.present?
  end

  test "perform marks email recipient as delivered" do
    tenant, collective, user = create_tenant_collective_user
    Collective.scope_thread_to_collective(subdomain: tenant.subdomain, handle: collective.handle)

    event = Event.create!(tenant: tenant, collective: collective, event_type: "note.created")
    notification = Notification.create!(
      tenant: tenant,
      event: event,
      notification_type: "mention",
      title: "Test",
    )

    recipient = NotificationRecipient.create!(
      notification: notification,
      user: user,
      channel: "email",
      status: "pending",
    )

    NotificationDeliveryJob.perform_now(recipient.id)

    recipient.reload
    assert_equal "delivered", recipient.status
    assert recipient.delivered_at.present?
  end

  test "perform sends email for email recipient" do
    tenant, collective, user = create_tenant_collective_user
    Collective.scope_thread_to_collective(subdomain: tenant.subdomain, handle: collective.handle)

    event = Event.create!(tenant: tenant, collective: collective, event_type: "note.created")
    notification = Notification.create!(
      tenant: tenant,
      event: event,
      notification_type: "mention",
      title: "Test Email Notification",
      body: "This is a test notification body",
      url: "/n/test123",
    )

    recipient = NotificationRecipient.create!(
      notification: notification,
      user: user,
      channel: "email",
      status: "pending",
    )

    initial_count = ActionMailer::Base.deliveries.size
    NotificationDeliveryJob.perform_now(recipient.id)

    assert_equal initial_count + 1, ActionMailer::Base.deliveries.size
    recipient.reload
    assert_equal "delivered", recipient.status
  end

  test "perform does nothing if recipient not found" do
    # Should not raise an error
    assert_nothing_raised do
      NotificationDeliveryJob.perform_now("nonexistent-id")
    end
  end

  test "perform does nothing if recipient already delivered" do
    tenant, collective, user = create_tenant_collective_user
    Collective.scope_thread_to_collective(subdomain: tenant.subdomain, handle: collective.handle)

    event = Event.create!(tenant: tenant, collective: collective, event_type: "note.created")
    notification = Notification.create!(
      tenant: tenant,
      event: event,
      notification_type: "mention",
      title: "Test",
    )

    original_time = 1.hour.ago
    recipient = NotificationRecipient.create!(
      notification: notification,
      user: user,
      channel: "in_app",
      status: "delivered",
      delivered_at: original_time,
    )

    NotificationDeliveryJob.perform_now(recipient.id)

    recipient.reload
    # delivered_at should not have changed
    assert_equal original_time.to_i, recipient.delivered_at.to_i
  end

  test "perform fires notifications.delivered event for non-reminder notifications" do
    tenant, collective, user = create_tenant_collective_user
    Collective.scope_thread_to_collective(subdomain: tenant.subdomain, handle: collective.handle)

    event = Event.create!(tenant: tenant, collective: collective, event_type: "note.created")
    notification = Notification.create!(
      tenant: tenant,
      event: event,
      notification_type: "mention",
      title: "Test Mention",
    )

    recipient = NotificationRecipient.create!(
      notification: notification,
      user: user,
      channel: "in_app",
      status: "pending",
    )

    initial_event_count = Event.where(event_type: "notifications.delivered").count

    NotificationDeliveryJob.perform_now(recipient.id)

    # Should fire one notifications.delivered event
    assert_equal initial_event_count + 1, Event.where(event_type: "notifications.delivered").count
  end

  test "perform does NOT fire notifications.delivered event for reminder notifications" do
    tenant, collective, user = create_tenant_collective_user
    Collective.scope_thread_to_collective(subdomain: tenant.subdomain, handle: collective.handle)

    event = Event.create!(tenant: tenant, collective: collective, event_type: "note.created")
    notification = Notification.create!(
      tenant: tenant,
      event: event,
      notification_type: "reminder",
      title: "Reminder Test",
    )

    recipient = NotificationRecipient.create!(
      notification: notification,
      user: user,
      channel: "in_app",
      status: "pending",
      scheduled_for: 1.hour.ago,  # Due reminder
    )

    initial_event_count = Event.where(event_type: "notifications.delivered").count

    NotificationDeliveryJob.perform_now(recipient.id)

    # Should NOT fire notifications.delivered event (reminders already have reminders.delivered)
    assert_equal initial_event_count, Event.where(event_type: "notifications.delivered").count
  end

  test "perform fires only ONE notifications.delivered event for multiple channels" do
    tenant, collective, user = create_tenant_collective_user
    Collective.scope_thread_to_collective(subdomain: tenant.subdomain, handle: collective.handle)

    event = Event.create!(tenant: tenant, collective: collective, event_type: "note.created")
    notification = Notification.create!(
      tenant: tenant,
      event: event,
      notification_type: "mention",
      title: "Multi-channel Test",
    )

    # Create recipients for both channels (simulating what NotificationService does)
    in_app_recipient = NotificationRecipient.create!(
      notification: notification,
      user: user,
      channel: "in_app",
      status: "pending",
    )

    email_recipient = NotificationRecipient.create!(
      notification: notification,
      user: user,
      channel: "email",
      status: "pending",
    )

    initial_event_count = Event.where(event_type: "notifications.delivered").count

    # Deliver both channels
    NotificationDeliveryJob.perform_now(in_app_recipient.id)
    NotificationDeliveryJob.perform_now(email_recipient.id)

    # Should fire only ONE notifications.delivered event (from in_app channel only)
    assert_equal initial_event_count + 1, Event.where(event_type: "notifications.delivered").count
  end
end
