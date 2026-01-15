require "test_helper"

class NotificationDeliveryJobTest < ActiveSupport::TestCase
  test "perform marks in_app recipient as delivered" do
    tenant, superagent, user = create_tenant_superagent_user
    Superagent.scope_thread_to_superagent(subdomain: tenant.subdomain, handle: superagent.handle)

    event = Event.create!(tenant: tenant, superagent: superagent, event_type: "note.created")
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
    tenant, superagent, user = create_tenant_superagent_user
    Superagent.scope_thread_to_superagent(subdomain: tenant.subdomain, handle: superagent.handle)

    event = Event.create!(tenant: tenant, superagent: superagent, event_type: "note.created")
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
    tenant, superagent, user = create_tenant_superagent_user
    Superagent.scope_thread_to_superagent(subdomain: tenant.subdomain, handle: superagent.handle)

    event = Event.create!(tenant: tenant, superagent: superagent, event_type: "note.created")
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
    tenant, superagent, user = create_tenant_superagent_user
    Superagent.scope_thread_to_superagent(subdomain: tenant.subdomain, handle: superagent.handle)

    event = Event.create!(tenant: tenant, superagent: superagent, event_type: "note.created")
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
end
