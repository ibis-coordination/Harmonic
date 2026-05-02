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

  test "messages returns chat messages in chronological order" do
    session = ChatSession.create!(
      tenant: @tenant,
      ai_agent: @ai_agent,
      initiated_by: @user,
    )

    session.chat_messages.create!(sender: @user, content: "Hello", created_at: 3.minutes.ago)
    session.chat_messages.create!(sender: @ai_agent, content: "Hi there!", created_at: 2.minutes.ago)
    session.chat_messages.create!(sender: @user, content: "What's new?", created_at: 1.minute.ago)
    session.chat_messages.create!(sender: @ai_agent, content: "Not much!", created_at: Time.current)

    messages = session.messages
    assert_equal 4, messages.count
    assert messages.all? { |m| m.is_a?(ChatMessage) }
    assert_equal "Hello", messages.first.content
    assert_equal "Not much!", messages.last.content
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

  test "find_or_create_for creates session on first call" do
    session = ChatSession.find_or_create_for(agent: @ai_agent, user: @user, tenant: @tenant)
    assert_not_nil session
    assert_equal @ai_agent.id, session.ai_agent_id
    assert_equal @user.id, session.initiated_by_id
    assert_equal @tenant.id, session.tenant_id
  end

  test "find_or_create_for returns existing session on second call" do
    session1 = ChatSession.find_or_create_for(agent: @ai_agent, user: @user, tenant: @tenant)
    session2 = ChatSession.find_or_create_for(agent: @ai_agent, user: @user, tenant: @tenant)
    assert_equal session1.id, session2.id
  end

  test "uniqueness constraint prevents duplicate sessions" do
    ChatSession.create!(tenant: @tenant, ai_agent: @ai_agent, initiated_by: @user)
    assert_raises(ActiveRecord::RecordInvalid) do
      ChatSession.create!(tenant: @tenant, ai_agent: @ai_agent, initiated_by: @user)
    end
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
