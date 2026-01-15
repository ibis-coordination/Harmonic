require "test_helper"

class NotificationRecipientTest < ActiveSupport::TestCase
  test "NotificationRecipient.create works" do
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

    assert recipient.persisted?
    assert_equal "in_app", recipient.channel
    assert_equal "pending", recipient.status
    assert_equal notification, recipient.notification
    assert_equal user, recipient.user
  end

  test "channel must be valid" do
    tenant, superagent, user = create_tenant_superagent_user
    Superagent.scope_thread_to_superagent(subdomain: tenant.subdomain, handle: superagent.handle)

    event = Event.create!(tenant: tenant, superagent: superagent, event_type: "note.created")
    notification = Notification.create!(
      tenant: tenant,
      event: event,
      notification_type: "mention",
      title: "Test",
    )

    recipient = NotificationRecipient.new(
      notification: notification,
      user: user,
      channel: "invalid",
      status: "pending",
    )

    assert_not recipient.valid?
    assert recipient.errors[:channel].present?
  end

  test "status must be valid" do
    tenant, superagent, user = create_tenant_superagent_user
    Superagent.scope_thread_to_superagent(subdomain: tenant.subdomain, handle: superagent.handle)

    event = Event.create!(tenant: tenant, superagent: superagent, event_type: "note.created")
    notification = Notification.create!(
      tenant: tenant,
      event: event,
      notification_type: "mention",
      title: "Test",
    )

    recipient = NotificationRecipient.new(
      notification: notification,
      user: user,
      channel: "in_app",
      status: "invalid",
    )

    assert_not recipient.valid?
    assert recipient.errors[:status].present?
  end

  test "read! marks recipient as read" do
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
      status: "delivered",
    )

    recipient.read!

    assert_equal "read", recipient.status
    assert recipient.read_at.present?
    assert recipient.read?
  end

  test "dismiss! marks recipient as dismissed" do
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
      status: "delivered",
    )

    recipient.dismiss!

    assert_equal "dismissed", recipient.status
    assert recipient.dismissed_at.present?
    assert recipient.dismissed?
  end

  test "mark_delivered! marks recipient as delivered" do
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

    recipient.mark_delivered!

    assert_equal "delivered", recipient.status
    assert recipient.delivered_at.present?
  end

  test "scopes filter correctly" do
    tenant, superagent, user = create_tenant_superagent_user
    Superagent.scope_thread_to_superagent(subdomain: tenant.subdomain, handle: superagent.handle)

    event = Event.create!(tenant: tenant, superagent: superagent, event_type: "note.created")
    notification = Notification.create!(
      tenant: tenant,
      event: event,
      notification_type: "mention",
      title: "Test",
    )

    in_app_pending = NotificationRecipient.create!(
      notification: notification,
      user: user,
      channel: "in_app",
      status: "pending",
    )

    email_delivered = NotificationRecipient.create!(
      notification: notification,
      user: user,
      channel: "email",
      status: "delivered",
    )

    assert_includes NotificationRecipient.in_app.to_a, in_app_pending
    assert_not_includes NotificationRecipient.in_app.to_a, email_delivered

    assert_includes NotificationRecipient.email.to_a, email_delivered
    assert_not_includes NotificationRecipient.email.to_a, in_app_pending

    assert_includes NotificationRecipient.pending.to_a, in_app_pending
    assert_includes NotificationRecipient.delivered.to_a, email_delivered

    assert_includes NotificationRecipient.unread.to_a, in_app_pending
    assert_includes NotificationRecipient.unread.to_a, email_delivered
  end
end
