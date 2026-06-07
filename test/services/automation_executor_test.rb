# typed: false

require "test_helper"

class AutomationExecutorTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @tenant, @collective, @user = create_tenant_collective_user
    @tenant.set_feature_flag!("internal_ai_agents", true)
    @tenant.set_feature_flag!("external_ai_agents", true)
    @ai_agent = create_ai_agent(parent: @user)
    @tenant.add_user!(@ai_agent)
  end

  # === Agent Rule Execution ===

  test "executes agent rule and creates task run" do
    rule = create_agent_rule(task: "You were mentioned. Respond appropriately.")
    event = create_test_event
    run = create_automation_run(rule, event)

    dispatched = []
    AgentRunnerDispatchService.stub :dispatch, ->(tr) { dispatched << tr } do
      assert_difference "AiAgentTaskRun.count", 1 do
        AutomationExecutor.execute(run)
      end
    end
    assert_equal 1, dispatched.length
    assert_equal "AiAgentTaskRun", dispatched.first.class.name

    run.reload
    # Run stays "running" until the agent task completes
    assert_equal "running", run.status
    assert_not_nil run.started_at
    assert_nil run.completed_at, "Should not be completed until task finishes"
    assert_not_nil run.ai_agent_task_run

    task_run = run.ai_agent_task_run
    assert_equal @ai_agent, task_run.ai_agent
    assert_equal "You were mentioned. Respond appropriately.", task_run.task
    assert_equal @user, task_run.initiated_by
    assert_equal rule, task_run.automation_rule
    assert task_run.triggered_by_automation?

    # Simulate task completion and verify run is now completed
    task_run.update!(status: "completed", completed_at: Time.current)
    task_run.notify_parent_automation_runs!

    run.reload
    assert_equal "completed", run.status
    assert_not_nil run.completed_at
  end

  test "renders template variables in task prompt" do
    rule = create_agent_rule(task: "{{event.actor.name}} mentioned you in {{subject.path}}. The note says: {{subject.text}}")
    note = Note.create!(
      tenant: @tenant,
      collective: @collective,
      created_by: @user,
      text: "Hey check this out"
    )
    event = Event.create!(
      tenant: @tenant,
      collective: @collective,
      event_type: "note.created",
      actor: @user,
      subject: note
    )
    run = create_automation_run(rule, event)

    AutomationExecutor.execute(run)

    task_run = run.reload.ai_agent_task_run
    assert_includes task_run.task, @user.display_name
    assert_includes task_run.task, note.path
    assert_includes task_run.task, "Hey check this out"
  end

  test "uses max_steps from rule configuration" do
    rule = create_agent_rule(task: "Do something", max_steps: 15)
    event = create_test_event
    run = create_automation_run(rule, event)

    AutomationExecutor.execute(run)

    task_run = run.reload.ai_agent_task_run
    assert_equal 15, task_run.max_steps
  end

  test "increments rule execution count" do
    rule = create_agent_rule(task: "Do something")
    event = create_test_event
    run = create_automation_run(rule, event)

    assert_equal 0, rule.execution_count

    AutomationExecutor.execute(run)

    rule.reload
    assert_equal 1, rule.execution_count
    assert_not_nil rule.last_executed_at
  end

  # === Status Transitions ===

  test "marks run as running then completed" do
    rule = create_agent_rule(task: "Do something")
    event = create_test_event
    run = create_automation_run(rule, event)

    assert run.pending?
    assert_nil run.started_at

    AutomationExecutor.execute(run)

    run.reload
    # Agent rules stay "running" until task completes
    assert run.running?
    assert_not_nil run.started_at
    assert_nil run.completed_at

    # Simulate task completion
    task_run = run.ai_agent_task_run
    task_run.update!(status: "completed", completed_at: Time.current)
    task_run.notify_parent_automation_runs!

    run.reload
    assert run.completed?
    assert_not_nil run.completed_at
  end

  test "records executed actions in run" do
    rule = create_agent_rule(task: "Do something")
    event = create_test_event
    run = create_automation_run(rule, event)

    AutomationExecutor.execute(run)

    run.reload
    assert_equal 1, run.actions_executed.size
    assert_equal "trigger_agent", run.actions_executed.first["type"]
    assert_not_nil run.actions_executed.first["task_run_id"]
  end

  # === Error Handling ===

  test "uses rule creator as initiated_by when event has no actor" do
    rule = create_agent_rule(task: "Do something")

    # Create event without an actor
    note = Note.create!(
      tenant: @tenant,
      collective: @collective,
      created_by: @user,
      text: "Test note"
    )
    event = Event.create!(
      tenant: @tenant,
      collective: @collective,
      event_type: "note.created",
      actor: nil,
      subject: note
    )
    run = create_automation_run(rule, event)

    AutomationExecutor.execute(run)

    task_run = run.reload.ai_agent_task_run
    # When event has no actor, fall back to rule creator
    assert_equal @user, task_run.initiated_by
  end

  test "fails and records error for general rule with invalid actions" do
    # Create a rule that will cause an execution error
    rule = AutomationRule.create!(
      tenant: @tenant,
      collective: @collective,
      created_by: @user,
      name: "Invalid actions rule",
      trigger_type: "event",
      trigger_config: { "event_type" => "note.created" },
      actions: "not an array", # This will cause validation to fail
      enabled: true
    )

    event = create_test_event
    run = create_automation_run(rule, event)

    AutomationExecutor.execute(run)

    run.reload
    assert run.failed?
    assert_equal "Actions must be an array", run.error_message
  end

  # === Scheduled Triggers (without event) ===

  test "executes scheduled rule without event" do
    rule = AutomationRule.create!(
      tenant: @tenant,
      ai_agent: @ai_agent,
      created_by: @user,
      name: "Daily summary",
      trigger_type: "schedule",
      trigger_config: { "cron" => "0 9 * * *" },
      actions: { "task" => "Generate a daily summary of activity." },
      enabled: true
    )

    run = AutomationRuleRun.create!(
      tenant: @tenant,
      automation_rule: rule,
      trigger_source: "schedule",
      status: "pending"
    )

    assert_difference "AiAgentTaskRun.count", 1 do
      AutomationExecutor.execute(run)
    end

    task_run = run.reload.ai_agent_task_run
    assert_equal "Generate a daily summary of activity.", task_run.task
    # For scheduled triggers, initiated_by should be the rule creator
    assert_equal @user, task_run.initiated_by
  end

  # === Webhook Triggers (with payload templating) ===

  test "renders webhook payload in task template" do
    rule = AutomationRule.create!(
      tenant: @tenant,
      ai_agent: @ai_agent,
      created_by: @user,
      name: "Webhook triggered task",
      trigger_type: "webhook",
      trigger_config: {},
      actions: { "task" => "Process {{payload.event}} from {{webhook.source_ip}}: {{payload.data.message}}" },
      enabled: true
    )

    run = AutomationRuleRun.create!(
      tenant: @tenant,
      automation_rule: rule,
      trigger_source: "webhook",
      trigger_data: {
        "webhook_path" => rule.webhook_path,
        "payload" => { "event" => "deploy", "data" => { "message" => "Production deploy started" } },
        "received_at" => Time.current.iso8601,
        "source_ip" => "192.168.1.100",
      },
      status: "pending"
    )

    assert_difference "AiAgentTaskRun.count", 1 do
      AutomationExecutor.execute(run)
    end

    task_run = run.reload.ai_agent_task_run
    assert_equal "Process deploy from 192.168.1.100: Production deploy started", task_run.task
  end

  test "renders webhook payload in general rule params" do
    other_agent = create_ai_agent(parent: @user, name: "Webhook Handler")
    @tenant.add_user!(other_agent)

    rule = AutomationRule.create!(
      tenant: @tenant,
      collective: @collective,
      created_by: @user,
      name: "Webhook orchestrator",
      trigger_type: "webhook",
      trigger_config: {},
      actions: [
        { "type" => "trigger_agent", "agent_id" => other_agent.id, "task" => "Handle {{payload.type}} event: {{payload.details}}" },
      ],
      enabled: true
    )

    run = AutomationRuleRun.create!(
      tenant: @tenant,
      collective: @collective,
      automation_rule: rule,
      trigger_source: "webhook",
      trigger_data: {
        "webhook_path" => rule.webhook_path,
        "payload" => { "type" => "user.signup", "details" => "New user registered" },
        "received_at" => Time.current.iso8601,
        "source_ip" => "10.0.0.1",
      },
      status: "pending"
    )

    assert_difference "AiAgentTaskRun.count", 1 do
      AutomationExecutor.execute(run)
    end

    task_run = AiAgentTaskRun.last
    assert_equal "Handle user.signup event: New user registered", task_run.task
  end

  # === General Rules (non-agent) ===

  test "executes general rule with internal_action" do
    rule = AutomationRule.create!(
      tenant: @tenant,
      collective: @collective,
      created_by: @user,
      name: "Create celebration note",
      trigger_type: "event",
      trigger_config: { "event_type" => "commitment.critical_mass" },
      actions: [
        { "type" => "internal_action", "action" => "create_note", "params" => { "text" => "Celebration!" } },
      ],
      enabled: true
    )

    event = create_test_event
    run = create_automation_run(rule, event)

    assert_difference "Note.count", 1 do
      AutomationExecutor.execute(run)
    end

    run.reload
    assert run.completed?
    assert_equal 1, run.actions_executed.size
    assert_equal "internal_action", run.actions_executed.first["type"]
    assert_equal "success", run.actions_executed.first["result"]["status"]
  end

  test "executes general rule with trigger_agent action" do
    other_agent = create_ai_agent(parent: @user, name: "Helper Agent")
    @tenant.add_user!(other_agent)

    rule = AutomationRule.create!(
      tenant: @tenant,
      collective: @collective,
      created_by: @user,
      name: "Orchestrate agents",
      trigger_type: "event",
      trigger_config: { "event_type" => "note.created" },
      actions: [
        { "type" => "trigger_agent", "agent_id" => other_agent.id, "task" => "Assist with {{subject.text}}", "max_steps" => 10 },
      ],
      enabled: true
    )

    note = Note.create!(
      tenant: @tenant,
      collective: @collective,
      created_by: @user,
      text: "Help me with this"
    )
    event = Event.create!(
      tenant: @tenant,
      collective: @collective,
      event_type: "note.created",
      actor: @user,
      subject: note
    )
    run = create_automation_run(rule, event)

    assert_difference "AiAgentTaskRun.count", 1 do
      AutomationExecutor.execute(run)
    end

    run.reload
    # Run stays "running" until agent task completes
    assert run.running?
    assert_equal "trigger_agent", run.actions_executed.first["type"]
    assert_equal "success", run.actions_executed.first["result"]["status"]

    task_run = AiAgentTaskRun.last
    assert_equal other_agent, task_run.ai_agent
    assert_includes task_run.task, "Help me with this"
    assert_equal 10, task_run.max_steps
    assert_equal rule, task_run.automation_rule
    assert task_run.triggered_by_automation?

    # Simulate agent task completion
    task_run.update!(status: "completed", completed_at: Time.current)
    task_run.notify_parent_automation_runs!

    run.reload
    assert run.completed?
  end

  test "executes general rule with webhook action" do
    stub_request(:post, "https://example.com/webhook")
      .to_return(status: 200, body: '{"ok": true}')

    rule = AutomationRule.create!(
      tenant: @tenant,
      collective: @collective,
      created_by: @user,
      name: "Send webhook",
      trigger_type: "event",
      trigger_config: { "event_type" => "note.created" },
      actions: [
        {
          "type" => "webhook",
          "url" => "https://example.com/webhook",
          "body" => { "event" => "{{event.type}}", "text" => "{{subject.text}}" },
        },
      ],
      enabled: true
    )

    note = Note.create!(
      tenant: @tenant,
      collective: @collective,
      created_by: @user,
      text: "Test webhook note"
    )
    event = Event.create!(
      tenant: @tenant,
      collective: @collective,
      event_type: "note.created",
      actor: @user,
      subject: note
    )
    run = create_automation_run(rule, event)

    AutomationExecutor.execute(run)

    run.reload
    # Run stays "running" until webhook is delivered
    assert run.running?
    assert_equal "webhook", run.actions_executed.first["type"]
    assert_equal "success", run.actions_executed.first["result"]["status"]
    assert run.actions_executed.first["result"]["delivery_id"].present?

    # Verify WebhookDelivery was created with correct data
    delivery = WebhookDelivery.find(run.actions_executed.first["result"]["delivery_id"])
    assert_equal "https://example.com/webhook", delivery.url
    assert_equal run, delivery.automation_rule_run
    body = JSON.parse(delivery.request_body)
    assert_equal "note.created", body["event"]
    assert_equal "Test webhook note", body["text"]

    # Execute the job to deliver the webhook
    perform_enqueued_jobs

    assert_requested(:post, "https://example.com/webhook") do |req|
      body = JSON.parse(req.body)
      body["event"] == "note.created" && body["text"] == "Test webhook note"
    end

    # Run should now be completed after webhook succeeded
    run.reload
    assert run.completed?
  end

  test "creates webhook delivery for later execution" do
    rule = AutomationRule.create!(
      tenant: @tenant,
      collective: @collective,
      created_by: @user,
      name: "Queued webhook",
      trigger_type: "event",
      trigger_config: { "event_type" => "note.created" },
      actions: [
        { "type" => "webhook", "url" => "https://example.com/webhook", "body" => {} },
      ],
      enabled: true
    )

    event = create_test_event
    run = create_automation_run(rule, event)

    assert_difference "WebhookDelivery.count", 1 do
      AutomationExecutor.execute(run)
    end

    run.reload
    delivery = run.webhook_deliveries.first
    assert_equal "pending", delivery.status
    assert_equal "https://example.com/webhook", delivery.url
    assert_equal rule.webhook_secret, delivery.secret
  end

  test "webhook action includes HMAC signature headers when delivered" do
    captured_headers = {}
    captured_body = nil

    stub_request(:post, "https://example.com/webhook")
      .to_return(status: 200, body: '{"ok": true}')
      .with { |req|
        captured_headers = req.headers
        captured_body = req.body
        true
      }

    rule = AutomationRule.create!(
      tenant: @tenant,
      collective: @collective,
      created_by: @user,
      name: "Signed webhook",
      trigger_type: "event",
      trigger_config: { "event_type" => "note.created" },
      actions: [
        { "type" => "webhook", "url" => "https://example.com/webhook", "body" => { "test" => "data" } },
      ],
      enabled: true
    )

    event = create_test_event
    run = create_automation_run(rule, event)

    AutomationExecutor.execute(run)

    # Execute the job to actually send the webhook
    perform_enqueued_jobs

    # Verify HMAC signature headers are present
    assert captured_headers["X-Harmonic-Signature"].present?, "Should include signature header"
    assert captured_headers["X-Harmonic-Timestamp"].present?, "Should include timestamp header"

    # Verify the signature can be validated with the rule's secret
    assert WebhookDeliveryService.verify_signature(
      captured_body,
      captured_headers["X-Harmonic-Timestamp"],
      captured_headers["X-Harmonic-Signature"],
      rule.webhook_secret
    ), "Signature should be verifiable with rule's secret"
  end

  test "webhook action accepts payload key as alias for body" do
    stub_request(:post, "https://example.com/webhook")
      .to_return(status: 200, body: '{"ok": true}')

    rule = AutomationRule.create!(
      tenant: @tenant,
      collective: @collective,
      created_by: @user,
      name: "Webhook with payload key",
      trigger_type: "event",
      trigger_config: { "event_type" => "note.created" },
      actions: [
        { "type" => "webhook", "url" => "https://example.com/webhook", "payload" => { "message" => "hello" } },
      ],
      enabled: true
    )

    event = create_test_event
    run = create_automation_run(rule, event)

    AutomationExecutor.execute(run)
    perform_enqueued_jobs

    run.reload
    assert run.completed?

    # Verify the payload was sent correctly
    delivery = run.webhook_deliveries.first
    body = JSON.parse(delivery.request_body)
    assert_equal "hello", body["message"], "Payload should be sent when using 'payload' key"
  end

  test "fails trigger_agent action when agent not found" do
    rule = AutomationRule.create!(
      tenant: @tenant,
      collective: @collective,
      created_by: @user,
      name: "Trigger missing agent",
      trigger_type: "event",
      trigger_config: { "event_type" => "note.created" },
      actions: [
        { "type" => "trigger_agent", "agent_id" => SecureRandom.uuid, "task" => "Do something" },
      ],
      enabled: true
    )

    event = create_test_event
    run = create_automation_run(rule, event)

    AutomationExecutor.execute(run)

    run.reload
    assert run.completed?
    assert_equal "failed", run.actions_executed.first["result"]["status"]
    assert_includes run.actions_executed.first["result"]["error"], "not found"
  end

  # === Stripe billing tests ===

  test "fails agent rule run when stripe_billing enabled and agent has no billing customer" do
    enable_stripe_billing_flag!(@tenant)

    rule = create_agent_rule(task: "Run this task")
    event = create_test_event
    run = create_automation_run(rule, event)

    assert_no_difference "AiAgentTaskRun.count" do
      AutomationExecutor.execute(run)
    end

    run.reload
    assert_equal "failed", run.status
    assert_includes run.error_message, "billing"
  end

  test "fails trigger_agent action when stripe_billing enabled and agent has no billing customer" do
    enable_stripe_billing_flag!(@tenant)

    other_agent = create_ai_agent(parent: @user, name: "Unbilled Agent")
    @tenant.add_user!(other_agent)

    rule = AutomationRule.create!(
      tenant: @tenant,
      collective: @collective,
      created_by: @user,
      name: "Billing gate trigger test",
      trigger_type: "event",
      trigger_config: { "event_type" => "note.created" },
      actions: [
        { "type" => "trigger_agent", "agent_id" => other_agent.id, "task" => "Do something" },
      ],
      enabled: true
    )

    event = create_test_event
    run = create_automation_run(rule, event)

    AutomationExecutor.execute(run)

    run.reload
    result = run.actions_executed.first["result"]
    assert_equal "failed", result["status"]
    assert_includes result["error"], "illing"
  end

  test "system agent (e.g., Trio) skips billing gate even when stripe_billing is enabled" do
    enable_stripe_billing_flag!(@tenant)

    # Build a Trio-shaped system agent: ai_agent with system_role: "trio" and
    # no billing_customer. The executor's billing gate must skip it.
    system_agent = User.create!(
      name: "Trio",
      email: "trio-test-#{SecureRandom.hex(4)}@system.harmonic.local",
      user_type: "ai_agent",
      system_role: "trio",
    )
    @tenant.add_user!(system_agent)
    @collective.add_user!(system_agent)

    rule = AutomationRule.create!(
      tenant: @tenant,
      ai_agent: system_agent,
      created_by: system_agent,
      name: "System agent rule",
      trigger_type: "event",
      trigger_config: { "event_type" => "note.created" },
      actions: { "task" => "Respond" },
      enabled: true,
    )
    event = create_test_event
    run = create_automation_run(rule, event)

    dispatched = []
    AgentRunnerDispatchService.stub :dispatch, ->(tr) { dispatched << tr } do
      assert_difference "AiAgentTaskRun.count", 1 do
        AutomationExecutor.execute(run)
      end
    end

    run.reload
    assert_not_equal "failed", run.status, "system agent should not fail the billing gate: #{run.error_message}"
    assert_equal 1, dispatched.length
  end

  # === External-only rollout scenario ===
  # When internal_ai_agents is off but external_ai_agents is on, the Task
  # Runner shouldn't fire. trigger_agent actions and agent-owned rules must
  # fail with a clear error rather than silently queueing.

  test "external-only rollout: agent-owned rule fails clearly when internal_ai_agents is disabled" do
    @tenant.disable_feature_flag!("internal_ai_agents")
    rule = create_agent_rule(task: "Run this task")
    event = create_test_event
    run = create_automation_run(rule, event)

    dispatched = []
    AgentRunnerDispatchService.stub :dispatch, ->(tr) { dispatched << tr } do
      assert_no_difference "AiAgentTaskRun.count" do
        AutomationExecutor.execute(run)
      end
    end
    assert_equal 0, dispatched.length, "should not dispatch to runner"

    run.reload
    assert_equal "failed", run.status
    assert_match(/Internal AI Agents are not enabled/, run.error_message)
  end

  test "external-only rollout: trigger_agent action fails clearly when internal_ai_agents is disabled" do
    @tenant.disable_feature_flag!("internal_ai_agents")
    target_agent = create_ai_agent(parent: @user, name: "Target Internal Agent")
    @tenant.add_user!(target_agent)

    rule = AutomationRule.create!(
      tenant: @tenant,
      collective: @collective,
      created_by: @user,
      name: "External-only trigger_agent test",
      trigger_type: "event",
      trigger_config: { "event_type" => "note.created" },
      actions: [
        { "type" => "trigger_agent", "agent_id" => target_agent.id, "task" => "Do something" },
      ],
      enabled: true,
    )

    event = create_test_event
    run = create_automation_run(rule, event)

    assert_no_difference "AiAgentTaskRun.count" do
      AutomationExecutor.execute(run)
    end

    run.reload
    result = run.actions_executed.first["result"]
    assert_equal "failed", result["status"]
    assert_match(/Internal AI Agents are not enabled/, result["error"])
  end

  test "external-only rollout: trigger_agent fails for external-mode target agent even when internal flag is on" do
    external_target = create_ai_agent(
      parent: @user,
      name: "External Target",
      agent_configuration: { "mode" => "external" },
    )
    @tenant.add_user!(external_target)

    rule = AutomationRule.create!(
      tenant: @tenant,
      collective: @collective,
      created_by: @user,
      name: "External agent target test",
      trigger_type: "event",
      trigger_config: { "event_type" => "note.created" },
      actions: [
        { "type" => "trigger_agent", "agent_id" => external_target.id, "task" => "Do something" },
      ],
      enabled: true,
    )

    event = create_test_event
    run = create_automation_run(rule, event)

    assert_no_difference "AiAgentTaskRun.count" do
      AutomationExecutor.execute(run)
    end

    run.reload
    result = run.actions_executed.first["result"]
    assert_equal "failed", result["status"]
    assert_match(/external|internal-mode agent/i, result["error"])
  end

  test "external-only rollout: webhook automations still fire when internal_ai_agents is disabled" do
    @tenant.disable_feature_flag!("internal_ai_agents")
    rule = AutomationRule.create!(
      tenant: @tenant,
      collective: @collective,
      created_by: @user,
      name: "Webhook automation in external-only rollout",
      trigger_type: "event",
      trigger_config: { "event_type" => "note.created" },
      actions: [
        { "type" => "webhook", "url" => "https://example.invalid/hook", "method" => "POST" },
      ],
      enabled: true,
    )
    event = create_test_event
    run = create_automation_run(rule, event)

    AutomationExecutor.execute(run)

    run.reload
    # The webhook execute path returns "failed" only on actual network errors;
    # in test it produces a delivery. Either way, the run must not be blocked
    # by the internal flag.
    refute_match(/Internal AI Agents are not enabled/, run.error_message.to_s,
      "webhook automations must not be gated by internal_ai_agents flag")
  end

  test "agent rule runs normally when stripe_billing flag disabled" do
    # stripe_billing NOT enabled — should work as before
    rule = create_agent_rule(task: "Run this task")
    event = create_test_event
    run = create_automation_run(rule, event)

    dispatched = []
    AgentRunnerDispatchService.stub :dispatch, ->(tr) { dispatched << tr } do
      assert_difference "AiAgentTaskRun.count", 1 do
        AutomationExecutor.execute(run)
      end
    end
    assert_equal 1, dispatched.length

    run.reload
    assert_equal "running", run.status
  end

  private

  def enable_stripe_billing_flag!(tenant)
    FeatureFlagService.config["stripe_billing"] ||= {}
    FeatureFlagService.config["stripe_billing"]["app_enabled"] = true
    tenant.enable_feature_flag!("stripe_billing")
  end

  # === External agent rule (webhook delivery) ===

  test "external-agent rule creates a WebhookDelivery and queues delivery job" do
    external_agent = create_ai_agent(parent: @user, name: "External Agent #{SecureRandom.hex(2)}", agent_configuration: { "mode" => "external" })
    @tenant.add_user!(external_agent)

    rule = AutomationRule.create!(
      tenant: @tenant,
      ai_agent: external_agent,
      created_by: @user,
      name: "External webhook rule",
      trigger_type: "event",
      trigger_config: { "event_type" => "note.created", "mention_filter" => "self" },
      actions: {
        "webhook_url" => "https://parent.example.com/hook",
        "payload_template" => { "event" => "{{event.type}}" },
      },
      enabled: true
    )

    event = create_test_event
    run = create_automation_run(rule, event)

    assert_difference "WebhookDelivery.count", 1 do
      assert_no_difference "AiAgentTaskRun.count" do
        AutomationExecutor.execute(run)
      end
    end

    delivery = WebhookDelivery.last
    assert_equal "https://parent.example.com/hook", delivery.url
    assert_equal "pending", delivery.status
    assert_equal rule.webhook_secret, delivery.secret

    run.reload
    assert_equal 1, run.actions_executed.size
    assert_equal "webhook", run.actions_executed.first["type"]
    assert_equal delivery.id, run.actions_executed.first["delivery_id"]
  end

  test "external-agent rule does not require internal_ai_agents flag" do
    external_agent = create_ai_agent(parent: @user, name: "External Agent #{SecureRandom.hex(2)}", agent_configuration: { "mode" => "external" })
    @tenant.add_user!(external_agent)
    @tenant.set_feature_flag!("internal_ai_agents", false)

    rule = AutomationRule.create!(
      tenant: @tenant,
      ai_agent: external_agent,
      created_by: @user,
      name: "External webhook rule",
      trigger_type: "event",
      trigger_config: { "event_type" => "note.created", "mention_filter" => "self" },
      actions: { "webhook_url" => "https://parent.example.com/hook" },
      enabled: true
    )

    event = create_test_event
    run = create_automation_run(rule, event)

    AutomationExecutor.execute(run)

    assert_equal "pending", WebhookDelivery.last.status
    run.reload
    assert_not run.failed?, "Should not have failed: #{run.error_message}"
  end

  # === User-owned notification webhook rules ===

  test "user-owned notification webhook rule creates a WebhookDelivery" do
    rule = AutomationRule.create!(
      tenant: @tenant,
      user: @user,
      created_by: @user,
      name: "My webhook",
      trigger_type: "event",
      trigger_config: { "event_types" => ["notifications.delivered"] },
      actions: { "webhook_url" => "https://my-server.example.com/hook" },
      enabled: true
    )

    event = create_test_event
    run = create_automation_run(rule, event)

    assert_difference "WebhookDelivery.count", 1 do
      AutomationExecutor.execute(run)
    end

    delivery = WebhookDelivery.last
    assert_equal "https://my-server.example.com/hook", delivery.url
    assert_equal "pending", delivery.status
  end

  test "user-owned webhook rule fails when user's tenant_user is archived" do
    rule = AutomationRule.create!(
      tenant: @tenant,
      user: @user,
      created_by: @user,
      name: "My webhook",
      trigger_type: "event",
      trigger_config: { "event_types" => ["notifications.delivered"] },
      actions: { "webhook_url" => "https://my-server.example.com/hook" },
      enabled: true
    )

    @user.tenant_users.find_by(tenant_id: @tenant.id)&.update!(archived_at: Time.current)

    event = create_test_event
    run = create_automation_run(rule, event)

    assert_no_difference "WebhookDelivery.count" do
      AutomationExecutor.execute(run)
    end

    run.reload
    assert run.failed?
    assert_match(/no longer active/i, run.error_message)
  end

  test "external-agent rule fails when agent is suspended" do
    external_agent = create_ai_agent(parent: @user, name: "External Agent #{SecureRandom.hex(2)}", agent_configuration: { "mode" => "external" })
    @tenant.add_user!(external_agent)

    rule = AutomationRule.create!(
      tenant: @tenant,
      ai_agent: external_agent,
      created_by: @user,
      name: "External webhook rule",
      trigger_type: "event",
      trigger_config: { "event_type" => "note.created" },
      actions: { "webhook_url" => "https://parent.example.com/hook" },
      enabled: true
    )

    external_agent.update!(suspended_at: Time.current)

    event = create_test_event
    run = create_automation_run(rule, event)

    assert_no_difference "WebhookDelivery.count" do
      AutomationExecutor.execute(run)
    end

    run.reload
    assert run.failed?
    assert_match(/suspended/i, run.error_message)
  end

  test "external-agent rule fails when agent's tenant_user is archived" do
    external_agent = create_ai_agent(parent: @user, name: "External Agent #{SecureRandom.hex(2)}", agent_configuration: { "mode" => "external" })
    @tenant.add_user!(external_agent)

    rule = AutomationRule.create!(
      tenant: @tenant,
      ai_agent: external_agent,
      created_by: @user,
      name: "External webhook rule",
      trigger_type: "event",
      trigger_config: { "event_type" => "note.created" },
      actions: { "webhook_url" => "https://parent.example.com/hook" },
      enabled: true
    )

    external_agent.tenant_users.find_by(tenant_id: @tenant.id)&.update!(archived_at: Time.current)

    event = create_test_event
    run = create_automation_run(rule, event)

    assert_no_difference "WebhookDelivery.count" do
      AutomationExecutor.execute(run)
    end

    run.reload
    assert run.failed?
    assert_match(/no longer active/i, run.error_message)
  end

  def create_agent_rule(task:, max_steps: nil)
    trigger_config = { "event_type" => "note.created" }
    trigger_config["max_steps"] = max_steps if max_steps

    AutomationRule.create!(
      tenant: @tenant,
      ai_agent: @ai_agent,
      created_by: @user,
      name: "Test Rule",
      trigger_type: "event",
      trigger_config: trigger_config,
      actions: { "task" => task },
      enabled: true
    )
  end

  def create_test_event
    note = Note.create!(
      tenant: @tenant,
      collective: @collective,
      created_by: @user,
      text: "Test note"
    )

    Event.create!(
      tenant: @tenant,
      collective: @collective,
      event_type: "note.created",
      actor: @user,
      subject: note
    )
  end

  def create_automation_run(rule, event)
    AutomationRuleRun.create!(
      tenant: @tenant,
      automation_rule: rule,
      triggered_by_event: event,
      trigger_source: "event",
      status: "pending"
    )
  end
end
