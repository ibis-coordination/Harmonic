# typed: false
require "test_helper"

class AgentSessionStepTest < ActiveSupport::TestCase
  setup do
    @tenant, @collective, @user = create_tenant_collective_user
    @tenant.enable_feature_flag!("ai_agents")
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)

    @ai_agent = User.create!(
      name: "Test Agent",
      email: "agent-#{SecureRandom.hex(4)}@not-real.com",
      user_type: "ai_agent",
      parent_id: @user.id,
    )

    @task_run = AiAgentTaskRun.create!(
      tenant: @tenant,
      ai_agent: @ai_agent,
      initiated_by: @user,
      task: "Test task",
      max_steps: 10,
      status: "running",
      started_at: Time.current,
    )
  end

  test "valid step with required fields" do
    step = AgentSessionStep.new(
      ai_agent_task_run: @task_run,
      position: 0,
      step_type: "navigate",
      detail: { path: "/home" },
    )
    assert step.valid?
  end

  test "requires position" do
    step = AgentSessionStep.new(
      ai_agent_task_run: @task_run,
      step_type: "navigate",
    )
    assert_not step.valid?
    assert_includes step.errors[:position], "can't be blank"
  end

  test "requires step_type" do
    step = AgentSessionStep.new(
      ai_agent_task_run: @task_run,
      position: 0,
    )
    assert_not step.valid?
    assert_includes step.errors[:step_type], "can't be blank"
  end

  test "rejects invalid step_type" do
    step = AgentSessionStep.new(
      ai_agent_task_run: @task_run,
      position: 0,
      step_type: "invalid_type",
    )
    assert_not step.valid?
    assert_includes step.errors[:step_type], "is not included in the list"
  end

  test "all defined step types are valid" do
    AgentSessionStep::STEP_TYPES.each do |type|
      step = AgentSessionStep.new(
        ai_agent_task_run: @task_run,
        position: 0,
        step_type: type,
        detail: {},
      )
      assert step.valid?, "Expected step_type '#{type}' to be valid, got errors: #{step.errors.full_messages}"
    end
  end

  test "message is not a valid step type" do
    step = AgentSessionStep.new(
      ai_agent_task_run: @task_run,
      position: 0,
      step_type: "message",
      detail: {},
    )
    assert_not step.valid?
    assert_includes step.errors[:step_type], "is not included in the list"
  end

  test "non-message step does not require sender" do
    step = AgentSessionStep.new(
      ai_agent_task_run: @task_run,
      position: 0,
      step_type: "navigate",
      detail: { path: "/home" },
    )
    assert step.valid?
    assert_nil step.sender_id
  end

  test "position uniqueness within a task run" do
    AgentSessionStep.create!(
      ai_agent_task_run: @task_run,
      position: 0,
      step_type: "navigate",
      detail: {},
    )

    duplicate = AgentSessionStep.new(
      ai_agent_task_run: @task_run,
      position: 0,
      step_type: "think",
      detail: {},
    )
    assert_raises(ActiveRecord::RecordNotUnique) { duplicate.save! }
  end

  test "to_step_hash returns expected format" do
    step = AgentSessionStep.create!(
      ai_agent_task_run: @task_run,
      position: 0,
      step_type: "navigate",
      detail: { "path" => "/home", "available_actions" => ["create_note"] },
    )

    hash = step.to_step_hash
    assert_equal "navigate", hash["type"]
    assert_equal({ "path" => "/home", "available_actions" => ["create_note"] }, hash["detail"])
    assert_kind_of String, hash["timestamp"]
  end

  test "to_step_hash with empty detail" do
    step = AgentSessionStep.create!(
      ai_agent_task_run: @task_run,
      position: 0,
      step_type: "done",
      detail: {},
    )

    hash = step.to_step_hash
    assert_equal({}, hash["detail"])
  end

  test "chronological scope orders by position" do
    AgentSessionStep.create!(ai_agent_task_run: @task_run, position: 2, step_type: "done", detail: {})
    AgentSessionStep.create!(ai_agent_task_run: @task_run, position: 0, step_type: "navigate", detail: {})
    AgentSessionStep.create!(ai_agent_task_run: @task_run, position: 1, step_type: "think", detail: {})

    steps = @task_run.agent_session_steps.chronological
    assert_equal [0, 1, 2], steps.map(&:position)
  end

  test "task run association with dependent destroy" do
    AgentSessionStep.create!(ai_agent_task_run: @task_run, position: 0, step_type: "navigate", detail: {})
    AgentSessionStep.create!(ai_agent_task_run: @task_run, position: 1, step_type: "done", detail: {})

    assert_equal 2, AgentSessionStep.where(ai_agent_task_run_id: @task_run.id).count

    @task_run.destroy!

    assert_equal 0, AgentSessionStep.where(ai_agent_task_run_id: @task_run.id).count
  end
end
