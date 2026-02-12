# typed: false

require "test_helper"

class AiAgentTaskRunTest < ActiveSupport::TestCase
  def setup
    @tenant = @global_tenant
    @superagent = @global_superagent
    @user = @global_user
    Superagent.scope_thread_to_superagent(
      subdomain: @tenant.subdomain,
      handle: @superagent.handle
    )

    @ai_agent = create_ai_agent(parent: @user, name: "Test AiAgent")
    @tenant.add_user!(@ai_agent)
    @superagent.add_user!(@ai_agent)
  end

  # === formatted_cost Tests ===

  test "formatted_cost returns nil when estimated_cost_usd is nil" do
    task_run = AiAgentTaskRun.create!(
      tenant: @tenant,
      ai_agent: @ai_agent,
      initiated_by: @user,
      task: "Test task",
      max_steps: 10,
      status: "completed",
      estimated_cost_usd: nil
    )

    assert_nil task_run.formatted_cost
  end

  test "formatted_cost returns nil when estimated_cost_usd is zero" do
    task_run = AiAgentTaskRun.create!(
      tenant: @tenant,
      ai_agent: @ai_agent,
      initiated_by: @user,
      task: "Test task",
      max_steps: 10,
      status: "completed",
      estimated_cost_usd: 0
    )

    assert_nil task_run.formatted_cost
  end

  test "formatted_cost returns '< $0.01' for costs under a cent" do
    task_run = AiAgentTaskRun.create!(
      tenant: @tenant,
      ai_agent: @ai_agent,
      initiated_by: @user,
      task: "Test task",
      max_steps: 10,
      status: "completed",
      estimated_cost_usd: 0.005
    )

    assert_equal "< $0.01", task_run.formatted_cost
  end

  test "formatted_cost formats costs at or above a cent" do
    task_run = AiAgentTaskRun.create!(
      tenant: @tenant,
      ai_agent: @ai_agent,
      initiated_by: @user,
      task: "Test task",
      max_steps: 10,
      status: "completed",
      estimated_cost_usd: 0.0123
    )

    assert_equal "$0.0123", task_run.formatted_cost
  end

  test "formatted_cost handles larger costs" do
    task_run = AiAgentTaskRun.create!(
      tenant: @tenant,
      ai_agent: @ai_agent,
      initiated_by: @user,
      task: "Test task",
      max_steps: 10,
      status: "completed",
      estimated_cost_usd: 1.2345
    )

    assert_equal "$1.2345", task_run.formatted_cost
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

  # === total_cost_for_period Tests ===

  test "total_cost_for_period sums costs for completed runs in date range" do
    start_date = 1.week.ago
    end_date = Time.current

    # Create completed runs with costs in the period
    AiAgentTaskRun.create!(
      tenant: @tenant,
      ai_agent: @ai_agent,
      initiated_by: @user,
      task: "Task 1",
      max_steps: 10,
      status: "completed",
      estimated_cost_usd: 0.50,
      completed_at: 3.days.ago
    )

    AiAgentTaskRun.create!(
      tenant: @tenant,
      ai_agent: @ai_agent,
      initiated_by: @user,
      task: "Task 2",
      max_steps: 10,
      status: "completed",
      estimated_cost_usd: 0.25,
      completed_at: 2.days.ago
    )

    # Create a failed run (should not be included)
    AiAgentTaskRun.create!(
      tenant: @tenant,
      ai_agent: @ai_agent,
      initiated_by: @user,
      task: "Failed task",
      max_steps: 10,
      status: "failed",
      estimated_cost_usd: 1.00,
      completed_at: 1.day.ago
    )

    # Create a completed run outside the period
    AiAgentTaskRun.create!(
      tenant: @tenant,
      ai_agent: @ai_agent,
      initiated_by: @user,
      task: "Old task",
      max_steps: 10,
      status: "completed",
      estimated_cost_usd: 2.00,
      completed_at: 2.weeks.ago
    )

    total_cost = AiAgentTaskRun.total_cost_for_period(start_date, end_date)
    assert_in_delta 0.75, total_cost.to_f, 0.0001
  end

  test "total_cost_for_period returns 0 when no matching runs" do
    start_date = 1.week.ago
    end_date = Time.current

    total_cost = AiAgentTaskRun.total_cost_for_period(start_date, end_date)
    assert_equal 0, total_cost.to_f
  end
end
