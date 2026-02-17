require "test_helper"
require "webmock/minitest"

class AutomationTestServiceTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @tenant, @collective, @user = create_tenant_collective_user
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
  end

  test "tests event-triggered automation with synthetic event" do
    stub_request(:post, "https://example.com/webhook")
      .to_return(status: 200, body: '{"received":true}')

    rule = AutomationRule.create!(
      tenant: @tenant,
      collective: @collective,
      name: "Test Event Automation",
      trigger_type: "event",
      trigger_config: { "event_type" => "note.created" },
      actions: [{ "type" => "webhook", "url" => "https://example.com/webhook", "body" => { "event" => "{{event.type}}" } }],
      created_by: @user,
    )

    result = AutomationTestService.test!(rule)

    assert result.success?, "Expected success but got error: #{result.error}"
    assert_not_nil result.run
    assert_equal "test", result.run.trigger_source
    assert_equal "completed", result.run.status
    assert result.actions_executed.any?

    # Verify synthetic event was created with test event type
    test_event = result.run.triggered_by_event
    assert_not_nil test_event
    assert_equal "automation_rule.tested", test_event.event_type
    assert_equal "note.created", test_event.metadata["simulated_event_type"]
    assert test_event.metadata["test"]

    # Execute queued webhook delivery job
    perform_enqueued_jobs

    # Verify webhook was called
    assert_requested(:post, "https://example.com/webhook")
  end

  test "tests schedule-triggered automation" do
    stub_request(:post, "https://example.com/schedule-hook")
      .to_return(status: 200, body: '{"ok":true}')

    rule = AutomationRule.create!(
      tenant: @tenant,
      collective: @collective,
      name: "Test Schedule Automation",
      trigger_type: "schedule",
      trigger_config: { "cron" => "0 9 * * *", "timezone" => "UTC" },
      actions: [{ "type" => "webhook", "url" => "https://example.com/schedule-hook", "body" => {} }],
      created_by: @user,
    )

    result = AutomationTestService.test!(rule)

    assert result.success?
    assert_not_nil result.run
    assert_equal "test", result.run.trigger_source
    assert result.run.trigger_data["test"]
    assert result.run.trigger_data["scheduled_time"].present?
  end

  test "tests webhook-triggered automation with synthetic payload" do
    stub_request(:post, "https://example.com/forward-hook")
      .to_return(status: 200, body: '{"forwarded":true}')

    rule = AutomationRule.create!(
      tenant: @tenant,
      collective: @collective,
      name: "Test Webhook Automation",
      trigger_type: "webhook",
      trigger_config: {},
      actions: [{ "type" => "webhook", "url" => "https://example.com/forward-hook", "body" => {} }],
      created_by: @user,
    )

    result = AutomationTestService.test!(rule)

    assert result.success?
    assert_not_nil result.run
    assert_equal "test", result.run.trigger_source
    assert result.run.trigger_data["webhook"]["body"].present?
  end

  test "tests manual-triggered automation with default inputs" do
    stub_request(:post, "https://example.com/manual-hook")
      .to_return(status: 200, body: '{"ok":true}')

    rule = AutomationRule.create!(
      tenant: @tenant,
      collective: @collective,
      name: "Test Manual Automation",
      trigger_type: "manual",
      trigger_config: {
        "inputs" => {
          "message" => { "type" => "string", "default" => "Hello", "label" => "Message" },
        },
      },
      actions: [{ "type" => "webhook", "url" => "https://example.com/manual-hook", "body" => {} }],
      created_by: @user,
    )

    result = AutomationTestService.test!(rule)

    assert result.success?
    assert_not_nil result.run
    assert_equal "test", result.run.trigger_source
    assert_equal "Hello", result.run.trigger_data.dig("inputs", "message")
  end

  test "tests manual-triggered automation with provided inputs" do
    stub_request(:post, "https://example.com/manual-hook")
      .to_return(status: 200, body: '{"ok":true}')

    rule = AutomationRule.create!(
      tenant: @tenant,
      collective: @collective,
      name: "Test Manual Automation",
      trigger_type: "manual",
      trigger_config: {
        "inputs" => {
          "message" => { "type" => "string", "default" => "Hello", "label" => "Message" },
        },
      },
      actions: [{ "type" => "webhook", "url" => "https://example.com/manual-hook", "body" => {} }],
      created_by: @user,
    )

    result = AutomationTestService.test!(rule, inputs: { "message" => "Custom message" })

    assert result.success?
    assert_equal "Custom message", result.run.trigger_data.dig("inputs", "message")
  end

  test "returns error result when execution fails" do
    rule = AutomationRule.create!(
      tenant: @tenant,
      collective: @collective,
      name: "Failing Automation",
      trigger_type: "event",
      trigger_config: { "event_type" => "note.created" },
      actions: "not an array", # Invalid actions format
      created_by: @user,
    )

    result = AutomationTestService.test!(rule)

    assert_not result.success?
    assert result.error.present?
  end

  test "creates run with test trigger_source" do
    stub_request(:post, "https://example.com/webhook")
      .to_return(status: 200, body: '{}')

    rule = AutomationRule.create!(
      tenant: @tenant,
      collective: @collective,
      name: "Test Automation",
      trigger_type: "event",
      trigger_config: { "event_type" => "note.created" },
      actions: [{ "type" => "webhook", "url" => "https://example.com/webhook", "body" => {} }],
      created_by: @user,
    )

    initial_run_count = AutomationRuleRun.count
    result = AutomationTestService.test!(rule)

    assert result.success?
    assert_equal initial_run_count + 1, AutomationRuleRun.count
    assert_equal "test", result.run.trigger_source
  end
end
