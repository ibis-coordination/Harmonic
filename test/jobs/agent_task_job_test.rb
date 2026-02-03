# typed: false
require "test_helper"

class AgentTaskJobTest < ActiveJob::TestCase
  # Mock navigator class for testing
  class MockNavigator
    attr_accessor :mock_result

    def initialize(user:, tenant:, superagent:)
      @user = user
      @tenant = tenant
      @superagent = superagent
    end

    def run(task:, max_steps:)
      mock_result || OpenStruct.new(
        success: true,
        steps: [],
        final_message: "Mock completed",
        error: nil
      )
    end

    class << self
      attr_accessor :mock_result
    end

    def self.new(user:, tenant:, superagent:)
      instance = allocate
      instance.send(:initialize, user: user, tenant: tenant, superagent: superagent)
      instance.mock_result = @mock_result
      instance
    end
  end

  setup do
    @original_navigator_class = AgentTaskJob.navigator_class
  end

  teardown do
    AgentTaskJob.navigator_class = @original_navigator_class
    MockNavigator.mock_result = nil
  end

  test "creates and runs task for mentioned subagent" do
    tenant, superagent, user = create_tenant_superagent_user
    tenant.enable_feature_flag!("subagents")
    Superagent.scope_thread_to_superagent(subdomain: tenant.subdomain, handle: superagent.handle)

    subagent = User.create!(
      name: "Test Agent",
      email: "test-agent-#{SecureRandom.hex(4)}@not-real.com",
      user_type: "subagent",
      parent_id: user.id
    )
    tu = tenant.add_user!(subagent)
    subagent.tenant_user = tu
    SuperagentMember.create!(superagent: superagent, user: subagent)

    # Use mock navigator
    MockNavigator.mock_result = OpenStruct.new(
      success: true,
      steps: [],
      final_message: "Task completed",
      error: nil
    )
    AgentTaskJob.navigator_class = MockNavigator

    assert_difference "SubagentTaskRun.count", 1 do
      AgentTaskJob.perform_now(
        subagent_id: subagent.id,
        tenant_id: tenant.id,
        superagent_id: superagent.id,
        initiated_by_id: user.id,
        trigger_context: { item_path: "/n/abc123", actor_name: "Test User" }
      )
    end

    task_run = SubagentTaskRun.last
    assert_equal "completed", task_run.status
    assert task_run.success
    assert_equal subagent.id, task_run.subagent_id
    assert_equal user.id, task_run.initiated_by_id
    assert_includes task_run.task, "Test User"
    assert_includes task_run.task, "/n/abc123"
  end

  test "records failed task run when agent fails" do
    tenant, superagent, user = create_tenant_superagent_user
    tenant.enable_feature_flag!("subagents")
    Superagent.scope_thread_to_superagent(subdomain: tenant.subdomain, handle: superagent.handle)

    subagent = User.create!(
      name: "Test Agent",
      email: "test-agent-#{SecureRandom.hex(4)}@not-real.com",
      user_type: "subagent",
      parent_id: user.id
    )
    tu = tenant.add_user!(subagent)
    subagent.tenant_user = tu
    SuperagentMember.create!(superagent: superagent, user: subagent)

    # Use mock navigator with failure
    MockNavigator.mock_result = OpenStruct.new(
      success: false,
      steps: [],
      final_message: nil,
      error: "Something went wrong"
    )
    AgentTaskJob.navigator_class = MockNavigator

    AgentTaskJob.perform_now(
      subagent_id: subagent.id,
      tenant_id: tenant.id,
      superagent_id: superagent.id,
      initiated_by_id: user.id,
      trigger_context: { item_path: "/n/abc123", actor_name: "Test User" }
    )

    task_run = SubagentTaskRun.last
    assert_equal "failed", task_run.status
    assert_not task_run.success
    assert_equal "Something went wrong", task_run.error
  end

  test "skips when subagents feature not enabled" do
    tenant, superagent, user = create_tenant_superagent_user
    # Note: feature flag NOT enabled
    Superagent.scope_thread_to_superagent(subdomain: tenant.subdomain, handle: superagent.handle)

    subagent = User.create!(
      name: "Test Agent",
      email: "test-agent-#{SecureRandom.hex(4)}@not-real.com",
      user_type: "subagent",
      parent_id: user.id
    )
    tu = tenant.add_user!(subagent)
    subagent.tenant_user = tu

    assert_no_difference "SubagentTaskRun.count" do
      AgentTaskJob.perform_now(
        subagent_id: subagent.id,
        tenant_id: tenant.id,
        superagent_id: superagent.id,
        initiated_by_id: user.id,
        trigger_context: {}
      )
    end
  end

  test "skips when user is not a subagent" do
    tenant, superagent, user = create_tenant_superagent_user
    tenant.enable_feature_flag!("subagents")
    Superagent.scope_thread_to_superagent(subdomain: tenant.subdomain, handle: superagent.handle)

    # Use a regular person user, not a subagent
    assert_no_difference "SubagentTaskRun.count" do
      AgentTaskJob.perform_now(
        subagent_id: user.id,
        tenant_id: tenant.id,
        superagent_id: superagent.id,
        initiated_by_id: user.id,
        trigger_context: {}
      )
    end
  end

  test "skips when tenant not found" do
    tenant, superagent, user = create_tenant_superagent_user
    tenant.enable_feature_flag!("subagents")

    subagent = User.create!(
      name: "Test Agent",
      email: "test-agent-#{SecureRandom.hex(4)}@not-real.com",
      user_type: "subagent",
      parent_id: user.id
    )
    tu = tenant.add_user!(subagent)
    subagent.tenant_user = tu

    assert_no_difference "SubagentTaskRun.count" do
      AgentTaskJob.perform_now(
        subagent_id: subagent.id,
        tenant_id: "nonexistent-id",
        superagent_id: superagent.id,
        initiated_by_id: user.id,
        trigger_context: {}
      )
    end
  end

  test "builds correct task prompt from trigger context" do
    tenant, superagent, user = create_tenant_superagent_user
    tenant.enable_feature_flag!("subagents")
    Superagent.scope_thread_to_superagent(subdomain: tenant.subdomain, handle: superagent.handle)

    subagent = User.create!(
      name: "Test Agent",
      email: "test-agent-#{SecureRandom.hex(4)}@not-real.com",
      user_type: "subagent",
      parent_id: user.id
    )
    tu = tenant.add_user!(subagent)
    subagent.tenant_user = tu
    SuperagentMember.create!(superagent: superagent, user: subagent)

    MockNavigator.mock_result = OpenStruct.new(
      success: true,
      steps: [],
      final_message: "Done",
      error: nil
    )
    AgentTaskJob.navigator_class = MockNavigator

    AgentTaskJob.perform_now(
      subagent_id: subagent.id,
      tenant_id: tenant.id,
      superagent_id: superagent.id,
      initiated_by_id: user.id,
      trigger_context: {
        item_path: "/studios/myteam/n/xyz789",
        actor_name: "Alice"
      }
    )

    task_run = SubagentTaskRun.last
    assert_includes task_run.task, "Alice"
    assert_includes task_run.task, "/studios/myteam/n/xyz789"
    assert_includes task_run.task, "respond appropriately"
    assert_includes task_run.task, "adding a comment"
  end
end
