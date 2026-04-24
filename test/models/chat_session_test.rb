# typed: false
require "test_helper"

class ChatSessionTest < ActiveSupport::TestCase
  setup do
    @tenant, @collective, @user = create_tenant_collective_user
    @tenant.enable_feature_flag!("ai_agents")
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)

    @ai_agent = User.create!(
      name: "Chat Agent",
      email: "chat-agent-#{SecureRandom.hex(4)}@not-real.com",
      user_type: "ai_agent",
      parent_id: @user.id,
    )
  end

  test "valid chat session with required fields" do
    session = ChatSession.new(
      tenant: @tenant,
      ai_agent: @ai_agent,
      initiated_by: @user,
    )
    assert session.valid?
  end

  test "auto-sets tenant_id from thread context" do
    session = ChatSession.new(
      ai_agent: @ai_agent,
      initiated_by: @user,
    )
    assert session.valid?
    assert_equal @tenant.id, session.tenant_id
  end

  test "requires ai_agent" do
    session = ChatSession.new(
      tenant: @tenant,
      initiated_by: @user,
    )
    assert_not session.valid?
  end

  test "requires initiated_by" do
    session = ChatSession.new(
      tenant: @tenant,
      ai_agent: @ai_agent,
    )
    assert_not session.valid?
  end

  test "has_many task_runs via chat_session_id" do
    session = ChatSession.create!(
      tenant: @tenant,

      ai_agent: @ai_agent,
      initiated_by: @user,
    )

    task_run = AiAgentTaskRun.create!(
      tenant: @tenant,
      ai_agent: @ai_agent,
      initiated_by: @user,
      task: "Hello",
      max_steps: 30,
      status: "queued",
      mode: "chat_turn",
      chat_session: session,
    )

    assert_equal 1, session.task_runs.count
    assert_equal task_run, session.task_runs.first
  end

  test "messages returns message steps across all turns" do
    session = ChatSession.create!(
      tenant: @tenant,

      ai_agent: @ai_agent,
      initiated_by: @user,
    )

    run1 = AiAgentTaskRun.create!(
      tenant: @tenant, ai_agent: @ai_agent, initiated_by: @user,
      task: "Hello", max_steps: 30, status: "completed",
      mode: "chat_turn", chat_session: session,
    )
    run1.agent_session_steps.create!(position: 0, step_type: "message", detail: { content: "Hello" }, sender: @user)
    run1.agent_session_steps.create!(position: 1, step_type: "navigate", detail: { path: "/home" })
    run1.agent_session_steps.create!(position: 2, step_type: "message", detail: { content: "Hi there!" }, sender: @ai_agent)

    run2 = AiAgentTaskRun.create!(
      tenant: @tenant, ai_agent: @ai_agent, initiated_by: @user,
      task: "What's new?", max_steps: 30, status: "completed",
      mode: "chat_turn", chat_session: session,
    )
    run2.agent_session_steps.create!(position: 0, step_type: "message", detail: { content: "What's new?" }, sender: @user)
    run2.agent_session_steps.create!(position: 1, step_type: "message", detail: { content: "Not much!" }, sender: @ai_agent)

    messages = session.messages
    assert_equal 4, messages.count
    assert messages.all? { |s| s.step_type == "message" }
  end

  test "current_state defaults to empty hash" do
    session = ChatSession.create!(
      tenant: @tenant,
      ai_agent: @ai_agent,
      initiated_by: @user,
    )
    assert_equal({}, session.current_state)
  end

  test "current_state persists navigation path" do
    session = ChatSession.create!(
      tenant: @tenant,
      ai_agent: @ai_agent,
      initiated_by: @user,
    )
    session.update!(current_state: { "current_path" => "/collectives/team/n/abc" })
    session.reload
    assert_equal "/collectives/team/n/abc", session.current_state["current_path"]
  end

  test "scoped to tenant" do
    ChatSession.create!(
      tenant: @tenant,

      ai_agent: @ai_agent,
      initiated_by: @user,
    )

    other_user = create_user(email: "other-#{SecureRandom.hex(4)}@example.com")
    other_tenant = create_tenant(subdomain: "other-chat-#{SecureRandom.hex(4)}", name: "Other")
    other_tenant.add_user!(other_user)
    other_collective = create_collective(tenant: other_tenant, created_by: other_user, handle: "other-#{SecureRandom.hex(4)}")
    Collective.scope_thread_to_collective(subdomain: other_tenant.subdomain, handle: other_collective.handle)

    assert_equal 0, ChatSession.count
  end
end
