require "test_helper"

class NotificationTest < ActiveSupport::TestCase
  test "Notification.create works" do
    tenant, superagent, user = create_tenant_superagent_user
    Superagent.scope_thread_to_superagent(subdomain: tenant.subdomain, handle: superagent.handle)

    event = Event.create!(
      tenant: tenant,
      superagent: superagent,
      event_type: "note.created",
      actor: user,
    )

    notification = Notification.create!(
      tenant: tenant,
      event: event,
      notification_type: "mention",
      title: "Test notification",
      body: "Test body",
      url: "/n/abc123",
    )

    assert notification.persisted?
    assert_equal "mention", notification.notification_type
    assert_equal event, notification.event
    assert_equal "Test notification", notification.title
  end

  test "notification_type must be valid" do
    tenant, superagent, user = create_tenant_superagent_user
    Superagent.scope_thread_to_superagent(subdomain: tenant.subdomain, handle: superagent.handle)

    event = Event.create!(
      tenant: tenant,
      superagent: superagent,
      event_type: "note.created",
    )

    notification = Notification.new(
      tenant: tenant,
      event: event,
      notification_type: "invalid_type",
      title: "Test",
    )

    assert_not notification.valid?
    assert notification.errors[:notification_type].present?
  end

  test "notification can have recipients" do
    tenant, superagent, user = create_tenant_superagent_user
    Superagent.scope_thread_to_superagent(subdomain: tenant.subdomain, handle: superagent.handle)

    event = Event.create!(
      tenant: tenant,
      superagent: superagent,
      event_type: "note.created",
    )

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

    assert_includes notification.notification_recipients, recipient
    assert_includes notification.recipients, user
  end

  test "notification_category returns notification_type" do
    tenant, superagent, user = create_tenant_superagent_user
    Superagent.scope_thread_to_superagent(subdomain: tenant.subdomain, handle: superagent.handle)

    event = Event.create!(
      tenant: tenant,
      superagent: superagent,
      event_type: "note.created",
    )

    notification = Notification.create!(
      tenant: tenant,
      event: event,
      notification_type: "comment",
      title: "Test",
    )

    assert_equal "comment", notification.notification_category
  end

  test "scopes work correctly" do
    tenant, superagent, user = create_tenant_superagent_user
    Superagent.scope_thread_to_superagent(subdomain: tenant.subdomain, handle: superagent.handle)

    event = Event.create!(
      tenant: tenant,
      superagent: superagent,
      event_type: "note.created",
    )

    notification1 = Notification.create!(tenant: tenant, event: event, notification_type: "mention", title: "Test 1")
    notification2 = Notification.create!(tenant: tenant, event: event, notification_type: "comment", title: "Test 2")

    assert_includes Notification.of_type("mention").to_a, notification1
    assert_not_includes Notification.of_type("mention").to_a, notification2
  end
end
