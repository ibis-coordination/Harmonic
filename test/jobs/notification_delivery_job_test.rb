require "test_helper"

class NotificationDeliveryJobTest < ActiveSupport::TestCase
  test "perform marks in_app recipient as delivered" do
    tenant, studio, user = create_tenant_studio_user
    Studio.scope_thread_to_studio(subdomain: tenant.subdomain, handle: studio.handle)

    event = Event.create!(tenant: tenant, studio: studio, event_type: "note.created")
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
    tenant, studio, user = create_tenant_studio_user
    Studio.scope_thread_to_studio(subdomain: tenant.subdomain, handle: studio.handle)

    event = Event.create!(tenant: tenant, studio: studio, event_type: "note.created")
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

  test "perform does nothing if recipient not found" do
    # Should not raise an error
    assert_nothing_raised do
      NotificationDeliveryJob.perform_now("nonexistent-id")
    end
  end

  test "perform does nothing if recipient already delivered" do
    tenant, studio, user = create_tenant_studio_user
    Studio.scope_thread_to_studio(subdomain: tenant.subdomain, handle: studio.handle)

    event = Event.create!(tenant: tenant, studio: studio, event_type: "note.created")
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
