# typed: false

require "test_helper"

class AutomationExecutorTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @tenant, @superagent, @user = create_tenant_studio_user
    @tenant.set_feature_flag!("ai_agents", true)
    @ai_agent = create_ai_agent(parent: @user)
    @tenant.add_user!(@ai_agent)
  end

  # === Agent Rule Execution ===

  test "executes agent rule and creates task run" do
    rule = create_agent_rule(task: "You were mentioned. Respond appropriately.")
    event = create_test_event
    run = create_automation_run(rule, event)

    assert_difference "AiAgentTaskRun.count", 1 do
      assert_enqueued_with(job: AgentQueueProcessorJob) do
        AutomationExecutor.execute(run)
      end
    end

    run.reload
    assert_equal "completed", run.status
    assert_not_nil run.completed_at
    assert_not_nil run.ai_agent_task_run

    task_run = run.ai_agent_task_run
    assert_equal @ai_agent, task_run.ai_agent
    assert_equal "You were mentioned. Respond appropriately.", task_run.task
    assert_equal @user, task_run.initiated_by
    assert_equal rule, task_run.automation_rule
    assert task_run.triggered_by_automation?
  end

  test "renders template variables in task prompt" do
    rule = create_agent_rule(task: "{{event.actor.name}} mentioned you in {{subject.path}}. The note says: {{subject.text}}")
    note = Note.create!(
      tenant: @tenant,
      superagent: @superagent,
      created_by: @user,
      text: "Hey check this out"
    )
    event = Event.create!(
      tenant: @tenant,
      superagent: @superagent,
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
    assert run.completed?
    assert_not_nil run.started_at
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
      superagent: @superagent,
      created_by: @user,
      text: "Test note"
    )
    event = Event.create!(
      tenant: @tenant,
      superagent: @superagent,
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

  test "fails when task prompt is empty" do
    rule = create_agent_rule(task: "")
    event = create_test_event
    run = create_automation_run(rule, event)

    AutomationExecutor.execute(run)

    run.reload
    assert run.failed?
    assert_equal "Task prompt is empty", run.error_message
  end

  test "fails and records error for general rule with invalid actions" do
    # Create a rule that will cause an execution error
    rule = AutomationRule.create!(
      tenant: @tenant,
      superagent: @superagent,
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

  # === General Rules (non-agent) ===

  test "executes general rule with internal_action (records but skips)" do
    rule = AutomationRule.create!(
      tenant: @tenant,
      superagent: @superagent,
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

    AutomationExecutor.execute(run)

    run.reload
    assert run.completed?
    assert_equal 1, run.actions_executed.size
    assert_equal "internal_action", run.actions_executed.first["type"]
    assert_includes run.actions_executed.first["result"]["status"], "skipped"
  end

  test "executes general rule with trigger_agent action" do
    other_agent = create_ai_agent(parent: @user, name: "Helper Agent")
    @tenant.add_user!(other_agent)

    rule = AutomationRule.create!(
      tenant: @tenant,
      superagent: @superagent,
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
      superagent: @superagent,
      created_by: @user,
      text: "Help me with this"
    )
    event = Event.create!(
      tenant: @tenant,
      superagent: @superagent,
      event_type: "note.created",
      actor: @user,
      subject: note
    )
    run = create_automation_run(rule, event)

    assert_difference "AiAgentTaskRun.count", 1 do
      AutomationExecutor.execute(run)
    end

    run.reload
    assert run.completed?
    assert_equal "trigger_agent", run.actions_executed.first["type"]
    assert_equal "success", run.actions_executed.first["result"]["status"]

    task_run = AiAgentTaskRun.last
    assert_equal other_agent, task_run.ai_agent
    assert_includes task_run.task, "Help me with this"
    assert_equal 10, task_run.max_steps
    assert_equal rule, task_run.automation_rule
    assert task_run.triggered_by_automation?
  end

  test "fails trigger_agent action when agent not found" do
    rule = AutomationRule.create!(
      tenant: @tenant,
      superagent: @superagent,
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

  private

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
      superagent: @superagent,
      created_by: @user,
      text: "Test note"
    )

    Event.create!(
      tenant: @tenant,
      superagent: @superagent,
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
