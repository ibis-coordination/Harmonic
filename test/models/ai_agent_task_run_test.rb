# typed: false

require "test_helper"

class AiAgentTaskRunTest < ActiveSupport::TestCase
  def setup
    @tenant = @global_tenant
    @collective = @global_collective
    @user = @global_user
    Collective.scope_thread_to_collective(
      subdomain: @tenant.subdomain,
      handle: @collective.handle
    )

    @ai_agent = create_ai_agent(parent: @user, name: "Test AiAgent")
    @tenant.add_user!(@ai_agent)
    @collective.add_user!(@ai_agent)
  end

  # === formatted_tokens Tests ===

  test "formatted_tokens returns nil when total_tokens is nil" do
    task_run = AiAgentTaskRun.create!(
      tenant: @tenant,
      ai_agent: @ai_agent,
      initiated_by: @user,
      task: "Test task",
      max_steps: 10,
      status: "completed",
      total_tokens: nil
    )

    assert_nil task_run.formatted_tokens
  end

  test "formatted_tokens returns nil when total_tokens is zero" do
    task_run = AiAgentTaskRun.create!(
      tenant: @tenant,
      ai_agent: @ai_agent,
      initiated_by: @user,
      task: "Test task",
      max_steps: 10,
      status: "completed",
      total_tokens: 0
    )

    assert_nil task_run.formatted_tokens
  end

  test "formatted_tokens formats small numbers without commas" do
    task_run = AiAgentTaskRun.create!(
      tenant: @tenant,
      ai_agent: @ai_agent,
      initiated_by: @user,
      task: "Test task",
      max_steps: 10,
      status: "completed",
      total_tokens: 500
    )

    assert_equal "500", task_run.formatted_tokens
  end

  test "formatted_tokens formats thousands with commas" do
    task_run = AiAgentTaskRun.create!(
      tenant: @tenant,
      ai_agent: @ai_agent,
      initiated_by: @user,
      task: "Test task",
      max_steps: 10,
      status: "completed",
      total_tokens: 12_345
    )

    assert_equal "12,345", task_run.formatted_tokens
  end

  test "formatted_tokens formats millions with commas" do
    task_run = AiAgentTaskRun.create!(
      tenant: @tenant,
      ai_agent: @ai_agent,
      initiated_by: @user,
      task: "Test task",
      max_steps: 10,
      status: "completed",
      total_tokens: 1_234_567
    )

    assert_equal "1,234,567", task_run.formatted_tokens
  end

  # === Scope Tests ===

  test "with_usage scope excludes zero token runs" do
    # Create a run with tokens
    task_run_with_tokens = AiAgentTaskRun.create!(
      tenant: @tenant,
      ai_agent: @ai_agent,
      initiated_by: @user,
      task: "Task with tokens",
      max_steps: 10,
      status: "completed",
      total_tokens: 1000
    )

    # Create a run without tokens
    AiAgentTaskRun.create!(
      tenant: @tenant,
      ai_agent: @ai_agent,
      initiated_by: @user,
      task: "Task without tokens",
      max_steps: 10,
      status: "completed",
      total_tokens: 0
    )

    results = AiAgentTaskRun.with_usage
    assert_includes results, task_run_with_tokens
    assert_equal 1, results.count
  end

  test "in_period scope filters by completed_at date range" do
    start_date = 1.week.ago
    end_date = Time.current

    # Create a run within the period
    task_run_in_period = AiAgentTaskRun.create!(
      tenant: @tenant,
      ai_agent: @ai_agent,
      initiated_by: @user,
      task: "Task in period",
      max_steps: 10,
      status: "completed",
      completed_at: 3.days.ago
    )

    # Create a run outside the period
    AiAgentTaskRun.create!(
      tenant: @tenant,
      ai_agent: @ai_agent,
      initiated_by: @user,
      task: "Task outside period",
      max_steps: 10,
      status: "completed",
      completed_at: 2.weeks.ago
    )

    results = AiAgentTaskRun.in_period(start_date, end_date)
    assert_includes results, task_run_in_period
    assert_equal 1, results.count
  end

  # === Ledger cost Tests ===
  #
  # The gateway usage ledger (LLMUsageRecord.ai_agent_task_run_id) is the
  # source of truth for run cost — the runner reports token counts only.
  # Runs with no ledger rows (LiteLLM-routed, or failed before any call)
  # have unknown cost, not zero.

  def create_ledger_row(task_run, cents:, status: "completed")
    LLMUsageRecord.create!(
      selection_id: "sel_#{SecureRandom.uuid}",
      status: status,
      ai_agent_id: task_run.ai_agent_id,
      ai_agent_task_run_id: task_run.id,
      payer_stripe_customer_id: "cus_test",
      origin_tenant_id: @tenant.id,
      estimated_cost_cents: status == "completed" ? cents : nil,
      occurred_at: Time.current,
      completed_at: status == "completed" ? Time.current : nil,
    )
  end

  test "ledger_cost_cents sums completed ledger rows and ignores others" do
    task_run = create_task_run
    create_ledger_row(task_run, cents: 30)
    create_ledger_row(task_run, cents: 12.5)
    create_ledger_row(task_run, cents: nil, status: "pending")

    assert_in_delta 42.5, task_run.ledger_cost_cents, 0.0001
    assert_equal 1, task_run.ledger_pending_calls
  end

  test "ledger_cost_cents is nil for a run with no ledger rows" do
    task_run = create_task_run

    assert_nil task_run.ledger_cost_cents
    assert_nil task_run.formatted_cost
  end

  test "formatted_cost renders from the ledger" do
    task_run = create_task_run
    create_ledger_row(task_run, cents: 42)
    assert_equal "$0.4200", task_run.formatted_cost

    tiny_run = create_task_run
    create_ledger_row(tiny_run, cents: 0.5)
    assert_equal "< $0.01", tiny_run.formatted_cost
  end

  def create_task_run(status: "completed")
    AiAgentTaskRun.create!(
      tenant: @tenant, ai_agent: @ai_agent, initiated_by: @user,
      task: "Test task", max_steps: 10, status: status
    )
  end

  # === Automation Rule Tracking Tests ===

  test "triggered_by_automation? returns false when automation_rule is nil" do
    task_run = AiAgentTaskRun.create!(
      tenant: @tenant,
      ai_agent: @ai_agent,
      initiated_by: @user,
      task: "Manual task",
      max_steps: 10,
      status: "queued"
    )

    assert_not task_run.triggered_by_automation?
  end

  test "triggered_by_automation? returns true when automation_rule is set" do
    @tenant.set_feature_flag!("internal_ai_agents", true)
    @tenant.set_feature_flag!("external_ai_agents", true)

    automation_rule = AutomationRule.create!(
      tenant: @tenant,
      ai_agent: @ai_agent,
      created_by: @user,
      name: "Test automation",
      trigger_type: "event",
      trigger_config: { "event_type" => "note.created" },
      actions: { "task" => "Do something" },
      enabled: true
    )

    task_run = AiAgentTaskRun.create!(
      tenant: @tenant,
      ai_agent: @ai_agent,
      initiated_by: @user,
      task: "Automated task",
      max_steps: 10,
      status: "queued",
      automation_rule: automation_rule
    )

    assert task_run.triggered_by_automation?
    assert_equal automation_rule, task_run.automation_rule
  end

  test "create_queued accepts automation_rule parameter" do
    @tenant.set_feature_flag!("internal_ai_agents", true)
    @tenant.set_feature_flag!("external_ai_agents", true)

    automation_rule = AutomationRule.create!(
      tenant: @tenant,
      ai_agent: @ai_agent,
      created_by: @user,
      name: "Test automation",
      trigger_type: "event",
      trigger_config: { "event_type" => "note.created" },
      actions: { "task" => "Do something" },
      enabled: true
    )

    task_run = AiAgentTaskRun.create_queued(
      ai_agent: @ai_agent,
      tenant: @tenant,
      initiated_by: @user,
      task: "Test task",
      automation_rule: automation_rule
    )

    assert_equal automation_rule, task_run.automation_rule
    assert task_run.triggered_by_automation?
  end
end
