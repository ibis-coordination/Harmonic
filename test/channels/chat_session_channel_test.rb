# typed: false
require "test_helper"

class ChatSessionChannelTest < ActionCable::Channel::TestCase
  setup do
    @tenant, @collective, @user = create_tenant_collective_user
    @tenant.enable_feature_flag!("ai_agents")
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)

    @ai_agent = User.create!(
      name: "Channel Agent",
      email: "channel-agent-#{SecureRandom.hex(4)}@not-real.com",
      user_type: "ai_agent",
      parent_id: @user.id,
    )

    @chat_session = ChatSession.create!(
      tenant: @tenant,
      ai_agent: @ai_agent,
      initiated_by: @user,
    )

    stub_connection(current_user: @user)
  end

  test "subscribes to own chat session" do
    subscribe(session_id: @chat_session.id)

    assert subscription.confirmed?
    assert_has_stream_for @chat_session
  end

  test "rejects subscription for another user's session" do
    other_user = create_user(email: "other-#{SecureRandom.hex(4)}@example.com")
    stub_connection(current_user: other_user)

    subscribe(session_id: @chat_session.id)

    assert subscription.rejected?
  end

  test "rejects subscription with nonexistent session_id" do
    subscribe(session_id: "nonexistent-uuid")

    assert subscription.rejected?
  end

  test "rejects subscription with nil session_id" do
    subscribe(session_id: nil)

    assert subscription.rejected?
  end
end
