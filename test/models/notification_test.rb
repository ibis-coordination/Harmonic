require "test_helper"

class NotificationTest < ActiveSupport::TestCase
  test "Notification.create works" do
    tenant, collective, user = create_tenant_collective_user
    Collective.scope_thread_to_collective(subdomain: tenant.subdomain, handle: collective.handle)

    event = Event.create!(
      tenant: tenant,
      collective: collective,
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
    tenant, collective, user = create_tenant_collective_user
    Collective.scope_thread_to_collective(subdomain: tenant.subdomain, handle: collective.handle)

    event = Event.create!(
      tenant: tenant,
      collective: collective,
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
    tenant, collective, user = create_tenant_collective_user
    Collective.scope_thread_to_collective(subdomain: tenant.subdomain, handle: collective.handle)

    event = Event.create!(
      tenant: tenant,
      collective: collective,
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
    tenant, collective, user = create_tenant_collective_user
    Collective.scope_thread_to_collective(subdomain: tenant.subdomain, handle: collective.handle)

    event = Event.create!(
      tenant: tenant,
      collective: collective,
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
    tenant, collective, user = create_tenant_collective_user
    Collective.scope_thread_to_collective(subdomain: tenant.subdomain, handle: collective.handle)

    event = Event.create!(
      tenant: tenant,
      collective: collective,
      event_type: "note.created",
    )

    notification1 = Notification.create!(tenant: tenant, event: event, notification_type: "mention", title: "Test 1")
    notification2 = Notification.create!(tenant: tenant, event: event, notification_type: "comment", title: "Test 2")

    assert_includes Notification.of_type("mention").to_a, notification1
    assert_not_includes Notification.of_type("mention").to_a, notification2
  end

  # === needs_action triage facet (issue #456) ===

  test "NEEDS_ACTION_TYPES is a subset of the valid notification types" do
    # Guards against a typo in the facet cut silently classifying nothing.
    assert (Notification::NEEDS_ACTION_TYPES - Notification::NOTIFICATION_TYPES).empty?,
           "NEEDS_ACTION_TYPES contains types not in NOTIFICATION_TYPES"
  end

  test "needs_action? and the needs_action scope agree on the classification" do
    tenant, collective, _user = create_tenant_collective_user
    Collective.scope_thread_to_collective(subdomain: tenant.subdomain, handle: collective.handle)
    event = Event.create!(tenant: tenant, collective: collective, event_type: "note.created")

    action = Notification.create!(tenant: tenant, event: event, notification_type: "mention", title: "Review")
    fyi = Notification.create!(tenant: tenant, event: event, notification_type: "participation", title: "FYI")

    assert action.needs_action?
    assert_not fyi.needs_action?
    assert_includes Notification.needs_action.to_a, action
    assert_not_includes Notification.needs_action.to_a, fyi
  end
end
