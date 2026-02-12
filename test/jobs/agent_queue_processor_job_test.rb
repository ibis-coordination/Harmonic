# typed: false
require "test_helper"

class AgentQueueProcessorJobTest < ActiveJob::TestCase
  # Mock navigator class for testing
  class MockNavigator
    attr_accessor :mock_result

    def initialize(user:, tenant:, superagent:, model: nil)
      @user = user
      @tenant = tenant
      @superagent = superagent
      @model = model
    end

    def run(task:, max_steps:)
      mock_result || OpenStruct.new(
        success: true,
        steps: [],
        final_message: "Mock completed",
        error: nil,
        input_tokens: 0,
        output_tokens: 0
      )
    end

    class << self
      attr_accessor :mock_result
    end

    def self.new(user:, tenant:, superagent:, model: nil)
      instance = allocate
      instance.send(:initialize, user: user, tenant: tenant, superagent: superagent, model: model)
      instance.mock_result = @mock_result
      instance
    end
  end

  setup do
    @original_navigator_class = AgentQueueProcessorJob.navigator_class
  end

  teardown do
    AgentQueueProcessorJob.navigator_class = @original_navigator_class
    MockNavigator.mock_result = nil
  end

  test "claims and runs oldest queued task" do
    tenant, superagent, user = create_tenant_superagent_user
    tenant.enable_feature_flag!("ai_agents")
    Superagent.scope_thread_to_superagent(subdomain: tenant.subdomain, handle: superagent.handle)

    ai_agent = create_ai_agent(user, tenant, superagent)

    # Create queued task
    task_run = AiAgentTaskRun.create!(
      tenant: tenant,
      ai_agent: ai_agent,
      initiated_by: user,
      task: "Test task",
      max_steps: AiAgentTaskRun::DEFAULT_MAX_STEPS,
      status: "queued"
    )

    # Use mock navigator
    MockNavigator.mock_result = OpenStruct.new(
      success: true,
      steps: [],
      final_message: "Task completed",
      error: nil,
      input_tokens: 100,
      output_tokens: 50
    )
    AgentQueueProcessorJob.navigator_class = MockNavigator

    AgentQueueProcessorJob.perform_now(
      ai_agent_id: ai_agent.id,
      tenant_id: tenant.id
    )

    task_run.reload
    assert_equal "completed", task_run.status
    assert task_run.success
    assert_not_nil task_run.started_at
    assert_not_nil task_run.completed_at
  end

  test "skips when another task is already running" do
    tenant, superagent, user = create_tenant_superagent_user
    tenant.enable_feature_flag!("ai_agents")
    Superagent.scope_thread_to_superagent(subdomain: tenant.subdomain, handle: superagent.handle)

    ai_agent = create_ai_agent(user, tenant, superagent)

    # Create a running task
    AiAgentTaskRun.create!(
      tenant: tenant,
      ai_agent: ai_agent,
      initiated_by: user,
      task: "Running task",
      max_steps: AiAgentTaskRun::DEFAULT_MAX_STEPS,
      status: "running",
      started_at: Time.current
    )

    # Create a queued task
    queued_task = AiAgentTaskRun.create!(
      tenant: tenant,
      ai_agent: ai_agent,
      initiated_by: user,
      task: "Queued task",
      max_steps: AiAgentTaskRun::DEFAULT_MAX_STEPS,
      status: "queued"
    )

    AgentQueueProcessorJob.navigator_class = MockNavigator

    AgentQueueProcessorJob.perform_now(
      ai_agent_id: ai_agent.id,
      tenant_id: tenant.id
    )

    # Queued task should still be queued
    queued_task.reload
    assert_equal "queued", queued_task.status
  end

  test "processes tasks in FIFO order" do
    tenant, superagent, user = create_tenant_superagent_user
    tenant.enable_feature_flag!("ai_agents")
    Superagent.scope_thread_to_superagent(subdomain: tenant.subdomain, handle: superagent.handle)

    ai_agent = create_ai_agent(user, tenant, superagent)

    # Create two queued tasks with different timestamps
    older_task = AiAgentTaskRun.create!(
      tenant: tenant,
      ai_agent: ai_agent,
      initiated_by: user,
      task: "Older task",
      max_steps: AiAgentTaskRun::DEFAULT_MAX_STEPS,
      status: "queued",
      created_at: 2.minutes.ago
    )

    newer_task = AiAgentTaskRun.create!(
      tenant: tenant,
      ai_agent: ai_agent,
      initiated_by: user,
      task: "Newer task",
      max_steps: AiAgentTaskRun::DEFAULT_MAX_STEPS,
      status: "queued",
      created_at: 1.minute.ago
    )

    MockNavigator.mock_result = OpenStruct.new(
      success: true,
      steps: [],
      final_message: "Done",
      error: nil,
      input_tokens: 100,
      output_tokens: 50
    )
    AgentQueueProcessorJob.navigator_class = MockNavigator

    # Run once - should pick up older task
    AgentQueueProcessorJob.perform_now(
      ai_agent_id: ai_agent.id,
      tenant_id: tenant.id
    )

    older_task.reload
    newer_task.reload

    assert_equal "completed", older_task.status
    assert_equal "queued", newer_task.status
  end

  test "records failed task run when agent fails" do
    tenant, superagent, user = create_tenant_superagent_user
    tenant.enable_feature_flag!("ai_agents")
    Superagent.scope_thread_to_superagent(subdomain: tenant.subdomain, handle: superagent.handle)

    ai_agent = create_ai_agent(user, tenant, superagent)

    task_run = AiAgentTaskRun.create!(
      tenant: tenant,
      ai_agent: ai_agent,
      initiated_by: user,
      task: "Test task",
      max_steps: AiAgentTaskRun::DEFAULT_MAX_STEPS,
      status: "queued"
    )

    # Use mock navigator with failure
    MockNavigator.mock_result = OpenStruct.new(
      success: false,
      steps: [],
      final_message: nil,
      error: "Something went wrong",
      input_tokens: 50,
      output_tokens: 25
    )
    AgentQueueProcessorJob.navigator_class = MockNavigator

    AgentQueueProcessorJob.perform_now(
      ai_agent_id: ai_agent.id,
      tenant_id: tenant.id
    )

    task_run.reload
    assert_equal "failed", task_run.status
    assert_not task_run.success
    assert_equal "Something went wrong", task_run.error
  end

  test "enqueues next processor job after completion" do
    tenant, superagent, user = create_tenant_superagent_user
    tenant.enable_feature_flag!("ai_agents")
    Superagent.scope_thread_to_superagent(subdomain: tenant.subdomain, handle: superagent.handle)

    ai_agent = create_ai_agent(user, tenant, superagent)

    AiAgentTaskRun.create!(
      tenant: tenant,
      ai_agent: ai_agent,
      initiated_by: user,
      task: "Test task",
      max_steps: AiAgentTaskRun::DEFAULT_MAX_STEPS,
      status: "queued"
    )

    MockNavigator.mock_result = OpenStruct.new(
      success: true,
      steps: [],
      final_message: "Done",
      error: nil,
      input_tokens: 100,
      output_tokens: 50
    )
    AgentQueueProcessorJob.navigator_class = MockNavigator

    assert_enqueued_with(job: AgentQueueProcessorJob) do
      AgentQueueProcessorJob.perform_now(
        ai_agent_id: ai_agent.id,
        tenant_id: tenant.id
      )
    end
  end

  test "skips when ai_agents feature not enabled" do
    tenant, superagent, user = create_tenant_superagent_user
    # Note: feature flag NOT enabled
    Superagent.scope_thread_to_superagent(subdomain: tenant.subdomain, handle: superagent.handle)

    ai_agent = create_ai_agent(user, tenant, superagent)

    task_run = AiAgentTaskRun.create!(
      tenant: tenant,
      ai_agent: ai_agent,
      initiated_by: user,
      task: "Test task",
      max_steps: AiAgentTaskRun::DEFAULT_MAX_STEPS,
      status: "queued"
    )

    AgentQueueProcessorJob.perform_now(
      ai_agent_id: ai_agent.id,
      tenant_id: tenant.id
    )

    # Task should still be queued (not processed)
    task_run.reload
    assert_equal "queued", task_run.status
  end

  test "skips when user is not a ai_agent" do
    tenant, superagent, user = create_tenant_superagent_user
    tenant.enable_feature_flag!("ai_agents")
    Superagent.scope_thread_to_superagent(subdomain: tenant.subdomain, handle: superagent.handle)

    # Use regular user (not a ai_agent)
    AgentQueueProcessorJob.perform_now(
      ai_agent_id: user.id,
      tenant_id: tenant.id
    )

    # No errors should occur, job just exits early
  end

  test "skips when tenant not found" do
    tenant, superagent, user = create_tenant_superagent_user
    tenant.enable_feature_flag!("ai_agents")
    Superagent.scope_thread_to_superagent(subdomain: tenant.subdomain, handle: superagent.handle)

    ai_agent = create_ai_agent(user, tenant, superagent)

    # Should not raise - just exit gracefully
    AgentQueueProcessorJob.perform_now(
      ai_agent_id: ai_agent.id,
      tenant_id: "nonexistent-id"
    )
  end

  test "skips when no queued tasks exist" do
    tenant, superagent, user = create_tenant_superagent_user
    tenant.enable_feature_flag!("ai_agents")
    Superagent.scope_thread_to_superagent(subdomain: tenant.subdomain, handle: superagent.handle)

    ai_agent = create_ai_agent(user, tenant, superagent)

    # No tasks queued - should not enqueue another processor
    assert_no_enqueued_jobs(only: AgentQueueProcessorJob) do
      AgentQueueProcessorJob.perform_now(
        ai_agent_id: ai_agent.id,
        tenant_id: tenant.id
      )
    end
  end

  private

  def create_ai_agent(user, tenant, superagent)
    ai_agent = User.create!(
      name: "Test Agent",
      email: "test-agent-#{SecureRandom.hex(4)}@not-real.com",
      user_type: "ai_agent",
      parent_id: user.id
    )
    tu = tenant.add_user!(ai_agent)
    ai_agent.tenant_user = tu
    SuperagentMember.create!(superagent: superagent, user: ai_agent)
    ai_agent
  end
end
