require "test_helper"

class WebhookDeliveryTest < ActiveSupport::TestCase
  setup do
    @tenant, @collective, @user = create_tenant_collective_user
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)

    @automation_rule = AutomationRule.create!(
      tenant: @tenant,
      collective: @collective,
      name: "Test Automation",
      trigger_type: "event",
      trigger_config: { "event_type" => "note.created" },
      actions: [{ "type" => "webhook", "url" => "https://example.com/webhook" }],
      created_by: @user,
    )

    @automation_run = AutomationRuleRun.create!(
      tenant: @tenant,
      collective: @collective,
      automation_rule: @automation_rule,
      trigger_source: "event",
      status: "running",
    )

    @event = Event.create!(
      tenant: @tenant,
      collective: @collective,
      event_type: "note.created",
      actor: @user,
    )
  end

  test "valid delivery creation with automation_rule_run" do
    delivery = WebhookDelivery.new(
      tenant: @tenant,
      automation_rule_run: @automation_run,
      event: @event,
      url: "https://example.com/webhook",
      secret: "test_secret",
      status: "pending",
      attempt_count: 0,
      request_body: '{"test":"data"}',
    )
    assert delivery.valid?
  end

  test "requires automation_rule_run" do
    delivery = WebhookDelivery.new(
      tenant: @tenant,
      event: @event,
      url: "https://example.com/webhook",
      secret: "test_secret",
      status: "pending",
      attempt_count: 0,
      request_body: '{"test":"data"}',
    )
    assert_not delivery.valid?
    assert_includes delivery.errors[:automation_rule_run], "must exist"
  end

  test "requires valid status" do
    delivery = WebhookDelivery.new(
      tenant: @tenant,
      automation_rule_run: @automation_run,
      event: @event,
      url: "https://example.com/webhook",
      secret: "test_secret",
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
      tenant: @tenant,
      automation_rule_run: @automation_run,
      event: @event,
      url: "https://example.com/webhook",
      secret: "test_secret",
      status: "pending",
      attempt_count: 0,
      request_body: '{"test":"data"}',
    )

    WebhookDelivery.create!(
      tenant: @tenant,
      automation_rule_run: @automation_run,
      event: @event,
      url: "https://example.com/webhook",
      secret: "test_secret",
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
      tenant: @tenant,
      automation_rule_run: @automation_run,
      event: @event,
      url: "https://example.com/webhook",
      secret: "test_secret",
      status: "pending",
      attempt_count: 0,
      request_body: '{"test":"data"}',
    )

    failed_delivery = WebhookDelivery.create!(
      tenant: @tenant,
      automation_rule_run: @automation_run,
      event: @event,
      url: "https://example.com/webhook",
      secret: "test_secret",
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
      tenant: @tenant,
      automation_rule_run: @automation_run,
      event: @event,
      url: "https://example.com/webhook",
      secret: "test_secret",
      status: "retrying",
      attempt_count: 1,
      request_body: '{"test":"data"}',
      next_retry_at: 1.hour.from_now,
    )

    ready_delivery = WebhookDelivery.create!(
      tenant: @tenant,
      automation_rule_run: @automation_run,
      event: @event,
      url: "https://example.com/webhook",
      secret: "test_secret",
      status: "retrying",
      attempt_count: 1,
      request_body: '{"test":"data"}',
      next_retry_at: 1.hour.ago,
    )

    needs_retry = WebhookDelivery.needs_retry
    assert_equal 1, needs_retry.count
    assert_equal ready_delivery.id, needs_retry.first.id
  end

  test "automation_rule_run association" do
    delivery = WebhookDelivery.create!(
      tenant: @tenant,
      automation_rule_run: @automation_run,
      event: @event,
      url: "https://example.com/webhook",
      secret: "test_secret",
      status: "pending",
      attempt_count: 0,
      request_body: '{"test":"data"}',
    )

    assert_equal @automation_run, delivery.automation_rule_run
    assert_includes @automation_run.webhook_deliveries, delivery
  end
end
