require "test_helper"

class WebhookDeliveryTest < ActiveSupport::TestCase
  setup do
    @tenant, @studio, @user = create_tenant_studio_user
    Studio.scope_thread_to_studio(subdomain: @tenant.subdomain, handle: @studio.handle)

    @webhook = Webhook.create!(
      tenant: @tenant,
      name: "Test Webhook",
      url: "https://example.com/webhook",
      events: ["note.created"],
      created_by: @user,
    )

    @event = Event.create!(
      tenant: @tenant,
      studio: @studio,
      event_type: "note.created",
      actor: @user,
    )
  end

  test "valid delivery creation" do
    delivery = WebhookDelivery.new(
      webhook: @webhook,
      event: @event,
      status: "pending",
      attempt_count: 0,
      request_body: '{"test":"data"}',
    )
    assert delivery.valid?
  end

  test "requires valid status" do
    delivery = WebhookDelivery.new(
      webhook: @webhook,
      event: @event,
      status: "invalid",
      attempt_count: 0,
      request_body: '{"test":"data"}',
    )
    assert_not delivery.valid?
    assert_includes delivery.errors[:status], "is not included in the list"
  end

  test "success? returns true for success status" do
    delivery = WebhookDelivery.new(status: "success")
    assert delivery.success?

    delivery.status = "pending"
    assert_not delivery.success?
  end

  test "failed? returns true for failed status" do
    delivery = WebhookDelivery.new(status: "failed")
    assert delivery.failed?

    delivery.status = "pending"
    assert_not delivery.failed?
  end

  test "retrying? returns true for retrying status" do
    delivery = WebhookDelivery.new(status: "retrying")
    assert delivery.retrying?

    delivery.status = "pending"
    assert_not delivery.retrying?
  end

  test "pending scope returns pending deliveries" do
    pending_delivery = WebhookDelivery.create!(
      webhook: @webhook,
      event: @event,
      status: "pending",
      attempt_count: 0,
      request_body: '{"test":"data"}',
    )

    WebhookDelivery.create!(
      webhook: @webhook,
      event: @event,
      status: "success",
      attempt_count: 1,
      request_body: '{"test":"data"}',
    )

    pending = WebhookDelivery.pending
    assert_equal 1, pending.count
    assert_equal pending_delivery.id, pending.first.id
  end

  test "failed scope returns failed deliveries" do
    WebhookDelivery.create!(
      webhook: @webhook,
      event: @event,
      status: "pending",
      attempt_count: 0,
      request_body: '{"test":"data"}',
    )

    failed_delivery = WebhookDelivery.create!(
      webhook: @webhook,
      event: @event,
      status: "failed",
      attempt_count: 5,
      request_body: '{"test":"data"}',
    )

    failed = WebhookDelivery.failed
    assert_equal 1, failed.count
    assert_equal failed_delivery.id, failed.first.id
  end

  test "needs_retry scope returns deliveries ready for retry" do
    WebhookDelivery.create!(
      webhook: @webhook,
      event: @event,
      status: "retrying",
      attempt_count: 1,
      request_body: '{"test":"data"}',
      next_retry_at: 1.hour.from_now,
    )

    ready_delivery = WebhookDelivery.create!(
      webhook: @webhook,
      event: @event,
      status: "retrying",
      attempt_count: 1,
      request_body: '{"test":"data"}',
      next_retry_at: 1.hour.ago,
    )

    needs_retry = WebhookDelivery.needs_retry
    assert_equal 1, needs_retry.count
    assert_equal ready_delivery.id, needs_retry.first.id
  end
end
