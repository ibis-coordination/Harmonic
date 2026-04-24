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
      # message type requires sender
      step.sender = @user if type == "message"
      assert step.valid?, "Expected step_type '#{type}' to be valid, got errors: #{step.errors.full_messages}"
    end
  end

  test "message step requires sender" do
    step = AgentSessionStep.new(
      ai_agent_task_run: @task_run,
      position: 0,
      step_type: "message",
      detail: { content: "Hello" },
    )
    assert_not step.valid?
    assert_includes step.errors[:sender], "can't be blank"
  end

  test "message step is valid with sender" do
    step = AgentSessionStep.new(
      ai_agent_task_run: @task_run,
      position: 0,
      step_type: "message",
      detail: { content: "Hello" },
      sender: @user,
    )
    assert step.valid?
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

  test "message_step? returns true for message type" do
    step = AgentSessionStep.new(step_type: "message")
    assert step.message_step?
  end

  test "message_step? returns false for other types" do
    step = AgentSessionStep.new(step_type: "navigate")
    assert_not step.message_step?
  end

  test "chronological scope orders by position" do
    AgentSessionStep.create!(ai_agent_task_run: @task_run, position: 2, step_type: "done", detail: {})
    AgentSessionStep.create!(ai_agent_task_run: @task_run, position: 0, step_type: "navigate", detail: {})
    AgentSessionStep.create!(ai_agent_task_run: @task_run, position: 1, step_type: "think", detail: {})

    steps = @task_run.agent_session_steps.chronological
    assert_equal [0, 1, 2], steps.map(&:position)
  end

  test "messages scope returns only message steps" do
    AgentSessionStep.create!(ai_agent_task_run: @task_run, position: 0, step_type: "navigate", detail: {})
    AgentSessionStep.create!(ai_agent_task_run: @task_run, position: 1, step_type: "message", detail: { content: "Hi" }, sender: @user)
    AgentSessionStep.create!(ai_agent_task_run: @task_run, position: 2, step_type: "think", detail: {})
    AgentSessionStep.create!(ai_agent_task_run: @task_run, position: 3, step_type: "message", detail: { content: "Done" }, sender: @ai_agent)

    messages = @task_run.agent_session_steps.messages
    assert_equal 2, messages.count
    assert messages.all? { |s| s.step_type == "message" }
  end

  test "task run association with dependent destroy" do
    AgentSessionStep.create!(ai_agent_task_run: @task_run, position: 0, step_type: "navigate", detail: {})
    AgentSessionStep.create!(ai_agent_task_run: @task_run, position: 1, step_type: "done", detail: {})

    assert_equal 2, AgentSessionStep.where(ai_agent_task_run_id: @task_run.id).count

    @task_run.destroy!

    assert_equal 0, AgentSessionStep.where(ai_agent_task_run_id: @task_run.id).count
  end
end
