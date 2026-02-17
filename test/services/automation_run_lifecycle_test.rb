# typed: false

require "test_helper"

# Tests for the automation run lifecycle - from creation through completion.
# These tests ensure that run status accurately reflects the state of all actions.
class AutomationRunLifecycleTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @tenant, @superagent, @user = create_tenant_studio_user
    @tenant.set_feature_flag!("ai_agents", true)
    @ai_agent = create_ai_agent(parent: @user)
    @tenant.add_user!(@ai_agent)
  end

  # === Run Status Should Reflect Async Action Status ===

  test "run with webhook action stays 'running' until webhook is delivered" do
    stub_request(:post, "https://example.com/webhook")
      .to_return(status: 200, body: '{"ok": true}')

    rule = create_webhook_rule
    run = create_run_for_rule(rule)

    # Execute the automation (queues the webhook)
    AutomationExecutor.execute(run)
    run.reload

    # Run should still be 'running' since webhook hasn't been delivered yet
    assert_equal "running", run.status, "Run should be 'running' while webhook is pending"
    assert_nil run.completed_at, "completed_at should be nil while webhook is pending"

    # Now deliver the webhook
    perform_enqueued_jobs

    run.reload
    assert_equal "completed", run.status, "Run should be 'completed' after webhook succeeds"
    assert_not_nil run.completed_at, "completed_at should be set after completion"
  end

  test "run with webhook action shows 'failed' when webhook fails after all retries" do
    stub_request(:post, "https://example.com/webhook")
      .to_return(status: 500, body: 'Server Error')

    rule = create_webhook_rule
    run = create_run_for_rule(rule)

    AutomationExecutor.execute(run)
    run.reload

    # Run should be 'running' while webhook is being retried
    assert_equal "running", run.status

    # Simulate all retries exhausted
    delivery = run.webhook_deliveries.first
    delivery.update!(status: "failed", attempt_count: 5, error_message: "Max retries exceeded")
    # Simulate the callback that would normally be called by WebhookDeliveryService
    run.update_status_from_actions!

    run.reload
    assert_equal "failed", run.status, "Run should be 'failed' when webhook fails permanently"
    assert_includes run.error_message.to_s, "Max retries exceeded", "Error should include webhook error message"
  end

  test "run with trigger_agent action stays 'running' until agent task completes" do
    other_agent = create_ai_agent(parent: @user, name: "Helper Agent")
    @tenant.add_user!(other_agent)

    rule = create_trigger_agent_rule(other_agent)
    run = create_run_for_rule(rule)

    AutomationExecutor.execute(run)
    run.reload

    # Run should be 'running' while agent task is in progress
    assert_equal "running", run.status, "Run should be 'running' while agent task is pending"

    # Find the task run that was created
    task_run = AiAgentTaskRun.last
    assert_not_nil task_run

    # Simulate agent task completion
    task_run.update!(status: "completed", completed_at: Time.current)
    # Simulate the callback that would normally be called by the job
    task_run.notify_parent_automation_runs!

    run.reload
    assert_equal "completed", run.status, "Run should be 'completed' after agent task finishes"
  end

  test "run with trigger_agent action shows 'failed' when agent task fails" do
    other_agent = create_ai_agent(parent: @user, name: "Helper Agent")
    @tenant.add_user!(other_agent)

    rule = create_trigger_agent_rule(other_agent)
    run = create_run_for_rule(rule)

    AutomationExecutor.execute(run)
    run.reload

    task_run = AiAgentTaskRun.last
    task_run.update!(status: "failed", completed_at: Time.current, error: "Agent crashed")
    # Simulate the callback that would normally be called by the job
    task_run.notify_parent_automation_runs!

    run.reload
    assert_equal "failed", run.status, "Run should be 'failed' when agent task fails"
    assert_includes run.error_message, "Agent crashed"
  end

  # === Multiple Actions ===

  test "run with multiple webhook actions completes only when all succeed" do
    stub_request(:post, "https://example.com/webhook1")
      .to_return(status: 200, body: '{"ok": true}')
    stub_request(:post, "https://example.com/webhook2")
      .to_return(status: 200, body: '{"ok": true}')

    rule = create_multi_webhook_rule
    run = create_run_for_rule(rule)

    AutomationExecutor.execute(run)
    run.reload

    # Should be running until both webhooks complete
    assert_equal "running", run.status

    # Deliver first webhook
    delivery1 = run.webhook_deliveries.find { |d| d.url.include?("webhook1") }
    WebhookDeliveryService.deliver!(delivery1)
    run.reload

    # Still running because second webhook is pending
    assert_equal "running", run.status

    # Deliver second webhook
    delivery2 = run.webhook_deliveries.find { |d| d.url.include?("webhook2") }
    WebhookDeliveryService.deliver!(delivery2)
    run.reload

    # Now completed
    assert_equal "completed", run.status
  end

  test "run with mixed success and failure shows partial failure status" do
    stub_request(:post, "https://example.com/webhook1")
      .to_return(status: 200, body: '{"ok": true}')
    stub_request(:post, "https://example.com/webhook2")
      .to_return(status: 500, body: 'Error')

    rule = create_multi_webhook_rule
    run = create_run_for_rule(rule)

    AutomationExecutor.execute(run)

    # Deliver both webhooks
    run.webhook_deliveries.each do |delivery|
      # Simulate max retries for the failing one
      if delivery.url.include?("webhook2")
        5.times { WebhookDeliveryService.deliver!(delivery.reload) }
      else
        WebhookDeliveryService.deliver!(delivery)
      end
    end

    run.reload

    # Run completes but with an error message indicating some actions failed
    assert_equal "completed", run.status
    assert run.error_message.present?, "Should have error message when some actions failed"
    assert_includes run.error_message, "failed"

    # Verify we have both success and failure in deliveries
    assert run.webhook_deliveries.any?(&:success?), "Should have at least one successful delivery"
    assert run.webhook_deliveries.any?(&:failed?), "Should have at least one failed delivery"
  end

  # === Webhook Delivery Status Updates ===

  test "webhook delivery success updates run status" do
    stub_request(:post, "https://example.com/webhook")
      .to_return(status: 200, body: '{"ok": true}')

    rule = create_webhook_rule
    run = create_run_for_rule(rule)
    AutomationExecutor.execute(run)

    delivery = run.webhook_deliveries.first
    assert_equal "pending", delivery.status

    # Deliver webhook
    WebhookDeliveryService.deliver!(delivery)
    delivery.reload

    assert_equal "success", delivery.status
    assert_equal 1, delivery.attempt_count, "Should record attempt count"

    run.reload
    assert_equal "completed", run.status, "Run status should be updated when webhook succeeds"
  end

  test "webhook delivery attempt count is accurate" do
    stub_request(:post, "https://example.com/webhook")
      .to_return(status: 500, body: 'Error').times(2)
      .then.to_return(status: 200, body: '{"ok": true}')

    rule = create_webhook_rule
    run = create_run_for_rule(rule)
    AutomationExecutor.execute(run)

    delivery = run.webhook_deliveries.first
    assert_equal 0, delivery.attempt_count, "Initial attempt count should be 0"

    # First attempt - fails
    WebhookDeliveryService.deliver!(delivery)
    delivery.reload
    assert_equal 1, delivery.attempt_count
    assert_equal "retrying", delivery.status

    # Second attempt - fails
    WebhookDeliveryService.deliver!(delivery)
    delivery.reload
    assert_equal 2, delivery.attempt_count
    assert_equal "retrying", delivery.status

    # Third attempt - succeeds
    WebhookDeliveryService.deliver!(delivery)
    delivery.reload
    assert_equal 3, delivery.attempt_count
    assert_equal "success", delivery.status

    run.reload
    assert_equal "completed", run.status
  end

  # === UI Display Consistency ===

  test "run status and action status are consistent for display" do
    stub_request(:post, "https://example.com/webhook")
      .to_return(status: 200, body: '{"ok": true}')

    rule = create_webhook_rule
    run = create_run_for_rule(rule)
    AutomationExecutor.execute(run)

    # Before delivery
    run.reload
    delivery = run.webhook_deliveries.first

    # CRITICAL: Status should be consistent
    if run.status == "completed"
      # If run says completed, actions should also be done
      assert delivery.success?, "If run is completed, webhook should be successful"
    elsif run.status == "running"
      # If run is running, at least one action is pending
      assert_not delivery.success?, "If run is running, webhook might still be pending"
    end

    # After delivery
    WebhookDeliveryService.deliver!(delivery)
    run.reload
    delivery.reload

    # Both should now show success
    assert_equal "completed", run.status
    assert_equal "success", delivery.status
  end

  private

  def create_webhook_rule
    AutomationRule.create!(
      tenant: @tenant,
      superagent: @superagent,
      created_by: @user,
      name: "Webhook Rule",
      trigger_type: "event",
      trigger_config: { "event_type" => "note.created" },
      actions: [
        { "type" => "webhook", "url" => "https://example.com/webhook", "body" => {} },
      ],
      enabled: true
    )
  end

  def create_multi_webhook_rule
    AutomationRule.create!(
      tenant: @tenant,
      superagent: @superagent,
      created_by: @user,
      name: "Multi Webhook Rule",
      trigger_type: "event",
      trigger_config: { "event_type" => "note.created" },
      actions: [
        { "type" => "webhook", "url" => "https://example.com/webhook1", "body" => {} },
        { "type" => "webhook", "url" => "https://example.com/webhook2", "body" => {} },
      ],
      enabled: true
    )
  end

  def create_trigger_agent_rule(agent)
    AutomationRule.create!(
      tenant: @tenant,
      superagent: @superagent,
      created_by: @user,
      name: "Trigger Agent Rule",
      trigger_type: "event",
      trigger_config: { "event_type" => "note.created" },
      actions: [
        { "type" => "trigger_agent", "agent_id" => agent.id, "task" => "Do something" },
      ],
      enabled: true
    )
  end

  def create_run_for_rule(rule)
    note = Note.create!(
      tenant: @tenant,
      superagent: @superagent,
      created_by: @user,
      text: "Test note"
    )

    event = Event.create!(
      tenant: @tenant,
      superagent: @superagent,
      event_type: "note.created",
      actor: @user,
      subject: note
    )

    AutomationRuleRun.create!(
      tenant: @tenant,
      superagent: @superagent,
      automation_rule: rule,
      triggered_by_event: event,
      trigger_source: "event",
      status: "pending"
    )
  end
end
