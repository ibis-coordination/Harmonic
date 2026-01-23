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

  # === Scheduled Reminder Scopes ===

  test "scheduled scope returns future scheduled notifications" do
    tenant, superagent, user = create_tenant_superagent_user
    Superagent.scope_thread_to_superagent(subdomain: tenant.subdomain, handle: superagent.handle)

    notification = Notification.create!(
      tenant: tenant,
      notification_type: "reminder",
      title: "Reminder Test",
    )

    past = NotificationRecipient.create!(
      notification: notification,
      user: user,
      channel: "in_app",
      status: "pending",
      scheduled_for: 1.hour.ago,
    )

    future = NotificationRecipient.create!(
      notification: notification,
      user: user,
      channel: "in_app",
      status: "pending",
      scheduled_for: 1.hour.from_now,
    )

    immediate = NotificationRecipient.create!(
      notification: notification,
      user: user,
      channel: "in_app",
      status: "pending",
      scheduled_for: nil,
    )

    assert_not_includes NotificationRecipient.scheduled.to_a, past
    assert_includes NotificationRecipient.scheduled.to_a, future
    assert_not_includes NotificationRecipient.scheduled.to_a, immediate
  end

  test "due scope returns past scheduled notifications" do
    tenant, superagent, user = create_tenant_superagent_user
    Superagent.scope_thread_to_superagent(subdomain: tenant.subdomain, handle: superagent.handle)

    notification = Notification.create!(
      tenant: tenant,
      notification_type: "reminder",
      title: "Reminder Test",
    )

    past = NotificationRecipient.create!(
      notification: notification,
      user: user,
      channel: "in_app",
      status: "pending",
      scheduled_for: 1.hour.ago,
    )

    future = NotificationRecipient.create!(
      notification: notification,
      user: user,
      channel: "in_app",
      status: "pending",
      scheduled_for: 1.hour.from_now,
    )

    assert_includes NotificationRecipient.due.to_a, past
    assert_not_includes NotificationRecipient.due.to_a, future
  end

  test "immediate scope returns non-scheduled notifications" do
    tenant, superagent, user = create_tenant_superagent_user
    Superagent.scope_thread_to_superagent(subdomain: tenant.subdomain, handle: superagent.handle)

    notification = Notification.create!(
      tenant: tenant,
      notification_type: "reminder",
      title: "Reminder Test",
    )

    scheduled = NotificationRecipient.create!(
      notification: notification,
      user: user,
      channel: "in_app",
      status: "pending",
      scheduled_for: 1.hour.from_now,
    )

    immediate = NotificationRecipient.create!(
      notification: notification,
      user: user,
      channel: "in_app",
      status: "pending",
      scheduled_for: nil,
    )

    assert_not_includes NotificationRecipient.immediate.to_a, scheduled
    assert_includes NotificationRecipient.immediate.to_a, immediate
  end

  test "scheduled? returns true for future scheduled notifications" do
    tenant, superagent, user = create_tenant_superagent_user
    Superagent.scope_thread_to_superagent(subdomain: tenant.subdomain, handle: superagent.handle)

    notification = Notification.create!(
      tenant: tenant,
      notification_type: "reminder",
      title: "Reminder Test",
    )

    nr = NotificationRecipient.create!(
      notification: notification,
      user: user,
      channel: "in_app",
      status: "pending",
      scheduled_for: 1.hour.from_now,
    )

    assert nr.scheduled?
  end

  test "scheduled? returns false for past scheduled notifications" do
    tenant, superagent, user = create_tenant_superagent_user
    Superagent.scope_thread_to_superagent(subdomain: tenant.subdomain, handle: superagent.handle)

    notification = Notification.create!(
      tenant: tenant,
      notification_type: "reminder",
      title: "Reminder Test",
    )

    nr = NotificationRecipient.create!(
      notification: notification,
      user: user,
      channel: "in_app",
      status: "pending",
      scheduled_for: 1.hour.ago,
    )

    assert_not nr.scheduled?
  end

  test "due? returns true for past scheduled notifications" do
    tenant, superagent, user = create_tenant_superagent_user
    Superagent.scope_thread_to_superagent(subdomain: tenant.subdomain, handle: superagent.handle)

    notification = Notification.create!(
      tenant: tenant,
      notification_type: "reminder",
      title: "Reminder Test",
    )

    nr = NotificationRecipient.create!(
      notification: notification,
      user: user,
      channel: "in_app",
      status: "pending",
      scheduled_for: 1.hour.ago,
    )

    assert nr.due?
  end

  test "due? returns false for future scheduled notifications" do
    tenant, superagent, user = create_tenant_superagent_user
    Superagent.scope_thread_to_superagent(subdomain: tenant.subdomain, handle: superagent.handle)

    notification = Notification.create!(
      tenant: tenant,
      notification_type: "reminder",
      title: "Reminder Test",
    )

    nr = NotificationRecipient.create!(
      notification: notification,
      user: user,
      channel: "in_app",
      status: "pending",
      scheduled_for: 1.hour.from_now,
    )

    assert_not nr.due?
  end

  test "rate_limited is a valid status" do
    tenant, superagent, user = create_tenant_superagent_user
    Superagent.scope_thread_to_superagent(subdomain: tenant.subdomain, handle: superagent.handle)

    notification = Notification.create!(
      tenant: tenant,
      notification_type: "reminder",
      title: "Reminder Test",
    )

    nr = NotificationRecipient.new(
      notification: notification,
      user: user,
      channel: "in_app",
      status: "rate_limited",
    )

    assert nr.valid?
  end
end
