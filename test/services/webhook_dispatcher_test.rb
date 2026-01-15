require "test_helper"

class WebhookDispatcherTest < ActiveSupport::TestCase
  setup do
    @tenant, @superagent, @user = create_tenant_superagent_user
    Superagent.scope_thread_to_superagent(subdomain: @tenant.subdomain, handle: @superagent.handle)
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
      superagent: @superagent,
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
      superagent: @superagent,
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
      superagent: @superagent,
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
      superagent: @superagent,
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
      superagent: @superagent,
      event_type: "agent.started",
      actor: @user,
    )

    WebhookDispatcher.dispatch(event)

    delivery = WebhookDelivery.where(webhook: webhook, event: event).first
    assert_nil delivery
  end

  test "dispatch matches studio-scoped webhooks" do
    # Create a studio-scoped webhook
    superagent_webhook = Webhook.create!(
      tenant: @tenant,
      superagent: @superagent,
      name: "Studio Webhook",
      url: "https://example.com/webhook",
      events: ["note.created"],
      created_by: @user,
    )

    # Create a tenant-level webhook
    tenant_webhook = Webhook.create!(
      tenant: @tenant,
      superagent: nil,
      name: "Tenant Webhook",
      url: "https://example.com/tenant-webhook",
      events: ["note.created"],
      created_by: @user,
    )

    note = create_note(
      tenant: @tenant,
      superagent: @superagent,
      created_by: @user,
    )

    event = Event.where(event_type: "note.created", subject: note).last

    # Both webhooks should receive the event
    superagent_delivery = WebhookDelivery.where(webhook: superagent_webhook, event: event).first
    tenant_delivery = WebhookDelivery.where(webhook: tenant_webhook, event: event).first

    assert_not_nil superagent_delivery
    assert_not_nil tenant_delivery
  end

  test "dispatch does not match webhooks from different studios" do
    other_superagent = create_superagent(tenant: @tenant, created_by: @user, name: "Other Studio", handle: "other-studio")

    # Create a webhook for a different studio
    other_webhook = Webhook.create!(
      tenant: @tenant,
      superagent: other_superagent,
      name: "Other Studio Webhook",
      url: "https://example.com/webhook",
      events: ["note.created"],
      created_by: @user,
    )

    note = create_note(
      tenant: @tenant,
      superagent: @superagent,
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
      superagent: @superagent,
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
    assert_equal @superagent.id, payload["studio"]["id"]
    assert_equal @superagent.handle, payload["studio"]["handle"]
    assert_equal @user.id, payload["actor"]["id"]
    assert_not_nil payload["data"]["note"]
    assert_equal note.id, payload["data"]["note"]["id"]
  end
end
