# typed: false
require "test_helper"

class OrphanedTaskSweepJobTest < ActiveJob::TestCase
  setup do
    @tenant, @collective, @user = create_tenant_collective_user
    @tenant.enable_feature_flag!("ai_agents")
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    @ai_agent = create_ai_agent(parent: @user)
  end

  teardown do
    Collective.clear_thread_scope
  end

  test "marks running tasks older than 15 minutes as failed" do
    task_run = AiAgentTaskRun.create!(
      tenant: @tenant,
      ai_agent: @ai_agent,
      initiated_by: @user,
      task: "Stuck task",
      max_steps: 10,
      status: "running",
      started_at: 20.minutes.ago,
    )

    Collective.clear_thread_scope
    OrphanedTaskSweepJob.perform_now
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)

    task_run.reload
    assert_equal "failed", task_run.status
    assert_equal false, task_run.success
    assert_equal "orphaned_timeout", task_run.error
    assert_not_nil task_run.completed_at
  end

  test "does not touch running tasks that started recently" do
    task_run = AiAgentTaskRun.create!(
      tenant: @tenant,
      ai_agent: @ai_agent,
      initiated_by: @user,
      task: "Active task",
      max_steps: 10,
      status: "running",
      started_at: 5.minutes.ago,
    )

    Collective.clear_thread_scope
    OrphanedTaskSweepJob.perform_now
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)

    task_run.reload
    assert_equal "running", task_run.status
  end

  test "does not touch completed or failed tasks" do
    completed = AiAgentTaskRun.create!(
      tenant: @tenant,
      ai_agent: @ai_agent,
      initiated_by: @user,
      task: "Done task",
      max_steps: 10,
      status: "completed",
      success: true,
      started_at: 30.minutes.ago,
      completed_at: 25.minutes.ago,
    )

    failed = AiAgentTaskRun.create!(
      tenant: @tenant,
      ai_agent: @ai_agent,
      initiated_by: @user,
      task: "Failed task",
      max_steps: 10,
      status: "failed",
      success: false,
      started_at: 30.minutes.ago,
      completed_at: 25.minutes.ago,
    )

    Collective.clear_thread_scope
    OrphanedTaskSweepJob.perform_now
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)

    completed.reload
    failed.reload
    assert_equal "completed", completed.status
    assert_equal "failed", failed.status
  end
end
