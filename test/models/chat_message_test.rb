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

    @chat_session = ChatSession.find_or_create_between(user_a: @ai_agent, user_b: @user, tenant: @tenant)
    # Simulate what ChatsController does: switch to the chat collective
    Collective.set_thread_context(@chat_session.collective)
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

  test "creating a chat message fires a chat_message.created event" do
    assert_difference "Event.count", 1 do
      ChatMessage.create!(
        chat_session: @chat_session,
        sender: @user,
        content: "Hello!",
      )
    end

    event = Event.last
    assert_equal "chat_message.created", event.event_type
    assert_equal @user.id, event.actor_id
    assert_equal @chat_session.collective_id, event.collective_id
  end

  test "chat message event is scoped to chat collective not main collective" do
    ChatMessage.create!(
      chat_session: @chat_session,
      sender: @user,
      content: "Hello!",
    )

    event = Event.last
    refute_equal @collective.id, event.collective_id, "Event should not be in the main collective"
    assert_equal @chat_session.collective_id, event.collective_id, "Event should be in the chat collective"
  end

  test "collective_id must match chat_session collective_id" do
    msg = ChatMessage.new(
      chat_session: @chat_session,
      sender: @user,
      content: "Hello!",
      tenant: @tenant,
      collective: @collective, # main collective, not the chat collective
    )
    assert_not msg.valid?
    assert_includes msg.errors[:collective], "must match the chat session's collective"
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
