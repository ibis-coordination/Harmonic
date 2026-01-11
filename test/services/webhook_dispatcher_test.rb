require "test_helper"

class WebhookDispatcherTest < ActiveSupport::TestCase
  setup do
    @tenant, @studio, @user = create_tenant_studio_user
    Studio.scope_thread_to_studio(subdomain: @tenant.subdomain, handle: @studio.handle)
  end

  test "dispatch creates delivery for matching webhook" do
    webhook = Webhook.create!(
      tenant: @tenant,
      name: "Test Webhook",
      url: "https://example.com/webhook",
      events: ["note.created"],
      created_by: @user,
    )

    note = create_note(
      tenant: @tenant,
      studio: @studio,
      created_by: @user,
    )

    event = Event.where(event_type: "note.created", subject: note).last

    delivery = WebhookDelivery.where(webhook: webhook, event: event).first
    assert_not_nil delivery
    assert_equal "pending", delivery.status
    assert_equal 0, delivery.attempt_count
    assert_not_nil delivery.request_body
  end

  test "dispatch skips disabled webhooks" do
    webhook = Webhook.create!(
      tenant: @tenant,
      name: "Disabled Webhook",
      url: "https://example.com/webhook",
      events: ["note.created"],
      created_by: @user,
      enabled: false,
    )

    note = create_note(
      tenant: @tenant,
      studio: @studio,
      created_by: @user,
    )

    event = Event.where(event_type: "note.created", subject: note).last

    delivery = WebhookDelivery.where(webhook: webhook, event: event).first
    assert_nil delivery
  end

  test "dispatch skips webhooks not subscribed to event type" do
    webhook = Webhook.create!(
      tenant: @tenant,
      name: "Decision Webhook",
      url: "https://example.com/webhook",
      events: ["decision.created"],
      created_by: @user,
    )

    note = create_note(
      tenant: @tenant,
      studio: @studio,
      created_by: @user,
    )

    event = Event.where(event_type: "note.created", subject: note).last

    delivery = WebhookDelivery.where(webhook: webhook, event: event).first
    assert_nil delivery
  end

  test "dispatch matches wildcard subscription" do
    webhook = Webhook.create!(
      tenant: @tenant,
      name: "All Events Webhook",
      url: "https://example.com/webhook",
      events: ["*"],
      created_by: @user,
    )

    note = create_note(
      tenant: @tenant,
      studio: @studio,
      created_by: @user,
    )

    event = Event.where(event_type: "note.created", subject: note).last

    delivery = WebhookDelivery.where(webhook: webhook, event: event).first
    assert_not_nil delivery
  end

  test "dispatch skips agent events" do
    webhook = Webhook.create!(
      tenant: @tenant,
      name: "All Events Webhook",
      url: "https://example.com/webhook",
      events: ["*"],
      created_by: @user,
    )

    event = Event.create!(
      tenant: @tenant,
      studio: @studio,
      event_type: "agent.started",
      actor: @user,
    )

    WebhookDispatcher.dispatch(event)

    delivery = WebhookDelivery.where(webhook: webhook, event: event).first
    assert_nil delivery
  end

  test "dispatch matches studio-scoped webhooks" do
    # Create a studio-scoped webhook
    studio_webhook = Webhook.create!(
      tenant: @tenant,
      studio: @studio,
      name: "Studio Webhook",
      url: "https://example.com/webhook",
      events: ["note.created"],
      created_by: @user,
    )

    # Create a tenant-level webhook
    tenant_webhook = Webhook.create!(
      tenant: @tenant,
      studio: nil,
      name: "Tenant Webhook",
      url: "https://example.com/tenant-webhook",
      events: ["note.created"],
      created_by: @user,
    )

    note = create_note(
      tenant: @tenant,
      studio: @studio,
      created_by: @user,
    )

    event = Event.where(event_type: "note.created", subject: note).last

    # Both webhooks should receive the event
    studio_delivery = WebhookDelivery.where(webhook: studio_webhook, event: event).first
    tenant_delivery = WebhookDelivery.where(webhook: tenant_webhook, event: event).first

    assert_not_nil studio_delivery
    assert_not_nil tenant_delivery
  end

  test "dispatch does not match webhooks from different studios" do
    other_studio = create_studio(tenant: @tenant, created_by: @user, name: "Other Studio", handle: "other-studio")

    # Create a webhook for a different studio
    other_webhook = Webhook.create!(
      tenant: @tenant,
      studio: other_studio,
      name: "Other Studio Webhook",
      url: "https://example.com/webhook",
      events: ["note.created"],
      created_by: @user,
    )

    note = create_note(
      tenant: @tenant,
      studio: @studio,
      created_by: @user,
    )

    event = Event.where(event_type: "note.created", subject: note).last

    delivery = WebhookDelivery.where(webhook: other_webhook, event: event).first
    assert_nil delivery
  end

  test "build_payload includes event data" do
    webhook = Webhook.create!(
      tenant: @tenant,
      name: "Test Webhook",
      url: "https://example.com/webhook",
      events: ["note.created"],
      created_by: @user,
    )

    note = create_note(
      tenant: @tenant,
      studio: @studio,
      created_by: @user,
    )

    event = Event.where(event_type: "note.created", subject: note).last
    delivery = WebhookDelivery.where(webhook: webhook, event: event).first

    payload = JSON.parse(delivery.request_body)

    assert_equal event.id, payload["id"]
    assert_equal "note.created", payload["type"]
    assert_not_nil payload["created_at"]
    assert_equal @tenant.id, payload["tenant"]["id"]
    assert_equal @tenant.subdomain, payload["tenant"]["subdomain"]
    assert_equal @studio.id, payload["studio"]["id"]
    assert_equal @studio.handle, payload["studio"]["handle"]
    assert_equal @user.id, payload["actor"]["id"]
    assert_not_nil payload["data"]["note"]
    assert_equal note.id, payload["data"]["note"]["id"]
  end
end
