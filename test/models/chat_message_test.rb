# typed: false
require "test_helper"

class ChatMessageTest < ActiveSupport::TestCase
  setup do
    @tenant, @collective, @user = create_tenant_collective_user
    @tenant.enable_feature_flag!("ai_agents")
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)

    @ai_agent = User.create!(
      name: "Chat Agent",
      email: "chat-agent-#{SecureRandom.hex(4)}@not-real.com",
      user_type: "ai_agent",
      parent_id: @user.id,
      agent_configuration: { "mode" => "internal" },
    )

    @chat_session = ChatSession.create!(
      tenant: @tenant,
      ai_agent: @ai_agent,
      initiated_by: @user,
    )
  end

  test "valid chat message" do
    msg = ChatMessage.new(
      chat_session: @chat_session,
      sender: @user,
      content: "Hello!",
    )
    assert msg.valid?
  end

  test "auto-sets tenant_id from thread context" do
    msg = ChatMessage.new(
      chat_session: @chat_session,
      sender: @user,
      content: "Hello!",
    )
    assert msg.valid?
    assert_equal @tenant.id, msg.tenant_id
  end

  test "requires content" do
    msg = ChatMessage.new(
      chat_session: @chat_session,
      sender: @user,
      content: "",
    )
    assert_not msg.valid?
  end

  test "requires sender" do
    msg = ChatMessage.new(
      chat_session: @chat_session,
      content: "Hello!",
    )
    assert_not msg.valid?
  end

  test "requires chat_session" do
    msg = ChatMessage.new(
      sender: @user,
      content: "Hello!",
    )
    assert_not msg.valid?
  end

  test "belongs to chat_session" do
    ChatMessage.create!(
      chat_session: @chat_session,
      sender: @user,
      content: "Hello!",
    )
    ChatMessage.create!(
      chat_session: @chat_session,
      sender: @ai_agent,
      content: "Hi there!",
    )

    assert_equal 2, @chat_session.chat_messages.count
  end

  test "scoped to tenant" do
    ChatMessage.create!(
      chat_session: @chat_session,
      sender: @user,
      content: "Hello!",
    )

    other_user = create_user(email: "other-#{SecureRandom.hex(4)}@example.com")
    other_tenant = create_tenant(subdomain: "other-msg-#{SecureRandom.hex(4)}", name: "Other")
    other_tenant.add_user!(other_user)
    other_collective = create_collective(tenant: other_tenant, created_by: other_user, handle: "other-#{SecureRandom.hex(4)}")
    Collective.scope_thread_to_collective(subdomain: other_tenant.subdomain, handle: other_collective.handle)

    assert_equal 0, ChatMessage.count
  end
end
