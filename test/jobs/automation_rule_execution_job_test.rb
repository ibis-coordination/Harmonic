# typed: false

require "test_helper"

class AutomationRuleExecutionJobTest < ActiveJob::TestCase
  setup do
    @tenant, @superagent, @user = create_tenant_studio_user
    @tenant.set_feature_flag!("ai_agents", true)
    @ai_agent = create_ai_agent(parent: @user)
    @tenant.add_user!(@ai_agent)
  end

  test "executes pending automation run" do
    rule = create_agent_rule
    run = create_pending_run(rule)

    assert run.pending?

    assert_difference "AiAgentTaskRun.count", 1 do
      AutomationRuleExecutionJob.perform_now(automation_rule_run_id: run.id)
    end

    run.reload
    assert run.completed?
    assert_not_nil run.ai_agent_task_run
  end

  test "skips run that is already completed" do
    rule = create_agent_rule
    run = create_pending_run(rule)
    run.update!(status: "completed", completed_at: Time.current)

    assert_no_difference "AiAgentTaskRun.count" do
      AutomationRuleExecutionJob.perform_now(automation_rule_run_id: run.id)
    end

    # Status should remain completed
    run.reload
    assert run.completed?
  end

  test "skips run that is already running" do
    rule = create_agent_rule
    run = create_pending_run(rule)
    run.update!(status: "running", started_at: Time.current)

    assert_no_difference "AiAgentTaskRun.count" do
      AutomationRuleExecutionJob.perform_now(automation_rule_run_id: run.id)
    end

    # Status should remain running
    run.reload
    assert run.running?
  end

  test "skips non-existent run" do
    assert_nothing_raised do
      AutomationRuleExecutionJob.perform_now(automation_rule_run_id: SecureRandom.uuid)
    end
  end

  test "marks run as failed on error" do
    rule = AutomationRule.create!(
      tenant: @tenant,
      superagent: @superagent,
      created_by: @user,
      name: "Bad rule",
      trigger_type: "event",
      trigger_config: { "event_type" => "note.created" },
      actions: "not an array", # Will cause executor to fail
      enabled: true
    )
    run = create_pending_run(rule)

    AutomationRuleExecutionJob.perform_now(automation_rule_run_id: run.id)

    run.reload
    assert run.failed?
    assert_equal "Actions must be an array", run.error_message
  end

  test "enqueues AgentQueueProcessorJob when executing agent rule" do
    rule = create_agent_rule
    run = create_pending_run(rule)

    assert_enqueued_with(job: AgentQueueProcessorJob) do
      AutomationRuleExecutionJob.perform_now(automation_rule_run_id: run.id)
    end
  end

  private

  def create_agent_rule
    AutomationRule.create!(
      tenant: @tenant,
      ai_agent: @ai_agent,
      created_by: @user,
      name: "Test Rule",
      trigger_type: "event",
      trigger_config: { "event_type" => "note.created" },
      actions: { "task" => "Do something useful" },
      enabled: true
    )
  end

  def create_pending_run(rule)
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
      automation_rule: rule,
      triggered_by_event: event,
      trigger_source: "event",
      status: "pending"
    )
  end
end
