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

    @other_user = User.create!(
      name: "Other Human",
      email: "other-human-#{SecureRandom.hex(4)}@example.com",
    )
  end

  test "valid chat session with required fields" do
    one, two = [@ai_agent.id, @user.id].sort
    session = ChatSession.new(
      tenant: @tenant,
      user_one_id: one,
      user_two_id: two,
    )
    assert session.valid?
  end

  test "auto-sets tenant_id and collective_id from thread context" do
    one, two = [@ai_agent.id, @user.id].sort
    session = ChatSession.new(user_one_id: one, user_two_id: two)
    assert session.valid?
    assert_equal @tenant.id, session.tenant_id
    assert_equal @collective.id, session.collective_id
  end

  test "requires user_one" do
    session = ChatSession.new(tenant: @tenant, user_two_id: @user.id)
    assert_not session.valid?
  end

  test "requires user_two" do
    session = ChatSession.new(tenant: @tenant, user_one_id: @ai_agent.id)
    assert_not session.valid?
  end

  test "find_or_create_between creates session on first call" do
    session = ChatSession.find_or_create_between(user_a: @ai_agent, user_b: @user, tenant: @tenant)
    assert_not_nil session
    assert session.participant?(@ai_agent)
    assert session.participant?(@user)
    assert_equal @tenant.id, session.tenant_id
  end

  test "find_or_create_between returns existing session on second call" do
    session1 = ChatSession.find_or_create_between(user_a: @ai_agent, user_b: @user, tenant: @tenant)
    session2 = ChatSession.find_or_create_between(user_a: @ai_agent, user_b: @user, tenant: @tenant)
    assert_equal session1.id, session2.id
  end

  test "find_or_create_between returns same session regardless of argument order" do
    session1 = ChatSession.find_or_create_between(user_a: @user, user_b: @ai_agent, tenant: @tenant)
    session2 = ChatSession.find_or_create_between(user_a: @ai_agent, user_b: @user, tenant: @tenant)
    assert_equal session1.id, session2.id
  end

  test "find_or_create_between works for two humans" do
    session = ChatSession.find_or_create_between(user_a: @user, user_b: @other_user, tenant: @tenant)
    assert_not_nil session
    assert session.participant?(@user)
    assert session.participant?(@other_user)
  end

  test "other_participant returns the other user" do
    session = ChatSession.find_or_create_between(user_a: @ai_agent, user_b: @user, tenant: @tenant)
    assert_equal @user, session.other_participant(@ai_agent)
    assert_equal @ai_agent, session.other_participant(@user)
  end

  test "participant? returns true for participants and false for non-participants" do
    session = ChatSession.find_or_create_between(user_a: @ai_agent, user_b: @user, tenant: @tenant)
    assert session.participant?(@ai_agent)
    assert session.participant?(@user)
    assert_not session.participant?(@other_user)
  end

  test "uniqueness constraint prevents duplicate sessions" do
    ChatSession.find_or_create_between(user_a: @ai_agent, user_b: @user, tenant: @tenant)
    one, two = [@ai_agent.id, @user.id].sort
    assert_raises(ActiveRecord::RecordInvalid) do
      ChatSession.create!(tenant: @tenant, user_one_id: one, user_two_id: two)
    end
  end

  test "has_many task_runs via chat_session_id" do
    session = ChatSession.find_or_create_between(user_a: @ai_agent, user_b: @user, tenant: @tenant)

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
    session = ChatSession.find_or_create_between(user_a: @ai_agent, user_b: @user, tenant: @tenant)

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
    session = ChatSession.find_or_create_between(user_a: @ai_agent, user_b: @user, tenant: @tenant)
    assert_equal({}, session.current_state)
  end

  test "current_state persists navigation path" do
    session = ChatSession.find_or_create_between(user_a: @ai_agent, user_b: @user, tenant: @tenant)
    session.update!(current_state: { "current_path" => "/collectives/team/n/abc" })
    session.reload
    assert_equal "/collectives/team/n/abc", session.current_state["current_path"]
  end

  test "scoped to tenant" do
    ChatSession.find_or_create_between(user_a: @ai_agent, user_b: @user, tenant: @tenant)

    other_user = create_user(email: "other-#{SecureRandom.hex(4)}@example.com")
    other_tenant = create_tenant(subdomain: "other-chat-#{SecureRandom.hex(4)}", name: "Other")
    other_tenant.add_user!(other_user)
    other_collective = create_collective(tenant: other_tenant, created_by: other_user, handle: "other-#{SecureRandom.hex(4)}")
    Collective.scope_thread_to_collective(subdomain: other_tenant.subdomain, handle: other_collective.handle)

    assert_equal 0, ChatSession.count
  end
end
