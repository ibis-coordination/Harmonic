# typed: false
require "test_helper"

class ChatsControllerTest < ActionDispatch::IntegrationTest
  include ActionCable::TestHelper

  setup do
    @tenant = @global_tenant
    @user = @global_user
    @tenant.enable_feature_flag!("ai_agents")
    @collective = @tenant.main_collective

    @ai_agent = create_ai_agent(parent: @user)
    @ai_agent.update!(agent_configuration: { "mode" => "internal" })
    @tenant.add_user!(@ai_agent)
    @collective.add_user!(@ai_agent)
    @agent_handle = TenantUser.tenant_scoped_only(@tenant.id).find_by(user: @ai_agent).handle

    sign_in_as(@user, tenant: @tenant)
  end

  private

  def with_tenant_scope
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    yield
  ensure
    Tenant.clear_thread_scope
    Collective.clear_thread_scope
  end

  # Set thread context to a chat session's collective for creating messages.
  def with_chat_scope(session)
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.set_thread_context(session.collective)
    yield
  ensure
    Tenant.clear_thread_scope
    Collective.clear_thread_scope
  end

  def create_chat_session
    with_tenant_scope do
      ChatSession.find_or_create_between(user_a: @ai_agent, user_b: @user, tenant: @tenant)
    end
  end

  public

  # --- index ---

  test "index renders empty state" do
    get "/chat"
    assert_response :success
    assert_match(/Select an agent/, response.body)
  end

  test "index requires authentication" do
    delete "/logout"
    get "/chat"
    assert_response :redirect
  end

  # --- show ---

  test "show renders chat and creates session on first visit" do
    get "/chat/#{@agent_handle}"
    assert_response :success

    with_tenant_scope do
      one, two = [@ai_agent.id, @user.id].sort
      session = ChatSession.tenant_scoped_only(@tenant.id).find_by(user_one_id: one, user_two_id: two)
      assert_not_nil session
      assert_equal "chat", session.collective.collective_type
    end
  end

  test "show reuses existing session on subsequent visits" do
    create_chat_session

    assert_no_difference "ChatSession.count" do
      get "/chat/#{@agent_handle}"
    end
    assert_response :success
  end

  test "show returns 404 for agent not owned by current user" do
    other_user = create_user(email: "other-owner-#{SecureRandom.hex(4)}@example.com")
    @tenant.add_user!(other_user)
    @collective.add_user!(other_user)

    other_agent = create_ai_agent(parent: other_user, name: "Other Agent #{SecureRandom.hex(4)}")
    @tenant.add_user!(other_agent)
    @collective.add_user!(other_agent)
    other_handle = TenantUser.tenant_scoped_only(@tenant.id).find_by(user: other_agent).handle

    get "/chat/#{other_handle}"
    assert_response :not_found
  end

  test "show paginates messages to last 50" do
    session = create_chat_session
    with_chat_scope(session) do
      60.times do |i|
        session.chat_messages.create!(
          sender: i.even? ? @user : @ai_agent,
          content: "Message #{i}",
          created_at: i.minutes.ago,
        )
      end
    end

    get "/chat/#{@agent_handle}"
    assert_response :success
    assert_match(/Load earlier messages/, response.body)
  end

  test "show displays most recent messages in chronological order" do
    session = create_chat_session
    with_chat_scope(session) do
      60.times do |i|
        session.chat_messages.create!(
          sender: @user,
          content: "Message #{i}",
          created_at: (60 - i).minutes.ago,
        )
      end
    end

    get "/chat/#{@agent_handle}"
    assert_response :success

    body = response.body

    # Old messages (0-9) should NOT appear — they're beyond the 50-message window
    assert_no_match(/Message 0</, body)
    assert_no_match(/Message 9</, body)

    # Recent messages (10-59) should appear
    assert_match(/Message 10/, body)
    assert_match(/Message 59/, body)

    # Messages should be in chronological order (oldest first, newest last)
    pos_50 = body.index("Message 50")
    pos_55 = body.index("Message 55")
    pos_59 = body.index("Message 59")
    assert pos_50 < pos_55, "Message 50 should appear before Message 55"
    assert pos_55 < pos_59, "Message 55 should appear before Message 59"
  end

  test "show does not show load earlier button when all messages fit" do
    session = create_chat_session
    with_chat_scope(session) do
      session.chat_messages.create!(sender: @user, content: "Hello")
    end

    get "/chat/#{@agent_handle}"
    assert_response :success
    assert_no_match(/Load earlier messages/, response.body)
  end

  # --- send_message ---

  test "send_message creates chat message and dispatches task" do
    session = create_chat_session

    assert_difference "ChatMessage.count", 1 do
      assert_difference "AiAgentTaskRun.count", 1 do
        post "/chat/#{@agent_handle}/message",
          params: { message: "Hello agent!" }
      end
    end

    msg = ChatMessage.last
    assert_equal @user.id, msg.sender_id
    assert_equal "Hello agent!", msg.content

    task_run = AiAgentTaskRun.last
    assert_equal "chat_turn", task_run.mode
    assert_equal session.id, task_run.chat_session_id
  end

  test "send_message does not create resource tracking for human messages" do
    create_chat_session

    post "/chat/#{@agent_handle}/message", params: { message: "Hello agent!" }
    assert_response :ok

    msg = ChatMessage.last
    resource = AiAgentTaskRunResource.find_by(resource_type: "ChatMessage", resource_id: msg.id)
    assert_nil resource, "Human-sent messages should not have resource tracking records"
  end

  test "send_message to external agent saves message but does not dispatch" do
    external_agent = create_ai_agent(parent: @user, name: "External Bot #{SecureRandom.hex(4)}")
    external_agent.update!(agent_configuration: { "mode" => "external" })
    @tenant.add_user!(external_agent)
    @collective.add_user!(external_agent)
    ext_handle = TenantUser.tenant_scoped_only(@tenant.id).find_by(user: external_agent).handle

    assert_difference "ChatMessage.count", 1 do
      assert_no_difference "AiAgentTaskRun.count" do
        post "/chat/#{ext_handle}/message", params: { message: "Hello" }
      end
    end
    assert_response :ok
  end

  test "send_message rejects empty message" do
    create_chat_session

    assert_no_difference "ChatMessage.count" do
      post "/chat/#{@agent_handle}/message", params: { message: "" }
    end
    assert_response :unprocessable_entity
  end

  test "send_message queues message when turn is running" do
    session = create_chat_session
    with_tenant_scope do
      AiAgentTaskRun.create!(
        tenant: @tenant, ai_agent: @ai_agent, initiated_by: @user,
        task: "Previous message", max_steps: 30, status: "running",
        mode: "chat_turn", chat_session: session,
        started_at: Time.current,
      )
    end

    assert_difference "ChatMessage.count", 1 do
      assert_no_difference "AiAgentTaskRun.count" do
        post "/chat/#{@agent_handle}/message",
          params: { message: "Follow-up" }
      end
    end
  end

  # --- poll_messages (new messages) ---

  test "poll_messages returns new messages after timestamp" do
    session = create_chat_session
    with_chat_scope(session) do
      session.chat_messages.create!(sender: @user, content: "Hello", created_at: 10.seconds.ago)
      session.chat_messages.create!(sender: @ai_agent, content: "Hi there!", created_at: 5.seconds.ago)
    end

    get "/chat/#{@agent_handle}/messages?after=#{8.seconds.ago.iso8601}"
    assert_response :success

    messages = response.parsed_body["messages"]
    assert_equal 1, messages.length
    assert_equal "Hi there!", messages[0]["content"]
  end

  # --- poll_messages (older messages / pagination) ---

  test "poll_messages with before param returns older messages" do
    session = create_chat_session
    with_chat_scope(session) do
      3.times do |i|
        session.chat_messages.create!(
          sender: @user,
          content: "Message #{i}",
          created_at: (30 - i).minutes.ago,
        )
      end
    end

    # Ask for messages before the most recent one
    get "/chat/#{@agent_handle}/messages?before=#{1.minute.ago.iso8601}"
    assert_response :success

    body = response.parsed_body
    assert body["messages"].length >= 2
    assert_equal false, body["has_more"]
  end

  test "poll_messages with before param signals has_more when more pages exist" do
    session = create_chat_session
    with_chat_scope(session) do
      55.times do |i|
        session.chat_messages.create!(
          sender: @user,
          content: "Message #{i}",
          created_at: (60 - i).minutes.ago,
        )
      end
    end

    get "/chat/#{@agent_handle}/messages?before=#{Time.current.iso8601}"
    assert_response :success

    body = response.parsed_body
    assert_equal 50, body["messages"].length
    assert_equal true, body["has_more"]
  end

  # --- non-human users ---

  test "agent cannot access chat via browser session" do
    sign_in_as(@ai_agent, tenant: @tenant)
    get "/chat"
    assert_response :redirect
  end

  # --- message truncation ---

  test "send_message truncates long messages" do
    create_chat_session

    long_message = "a" * 20_000
    post "/chat/#{@agent_handle}/message", params: { message: long_message }
    assert_response :ok

    msg = ChatMessage.last
    assert_equal ChatsController::MAX_MESSAGE_LENGTH, msg.content.length
  end

  # --- agent busy ---

  test "show displays busy indicator when agent has a running non-chat task" do
    create_chat_session
    with_tenant_scope do
      AiAgentTaskRun.create!(
        tenant: @tenant, ai_agent: @ai_agent, initiated_by: @user,
        task: "Working on something", max_steps: 30, status: "running",
        mode: "task",
        started_at: Time.current,
      )
    end

    get "/chat/#{@agent_handle}"
    assert_response :success
    assert_match(/currently working/, response.body)
  end

  test "show does not display busy indicator when agent is working in this session" do
    session = create_chat_session
    with_tenant_scope do
      AiAgentTaskRun.create!(
        tenant: @tenant, ai_agent: @ai_agent, initiated_by: @user,
        task: "Working here", max_steps: 30, status: "running",
        mode: "chat_turn", chat_session: session,
        started_at: Time.current,
      )
    end

    get "/chat/#{@agent_handle}"
    assert_response :success
    assert_no_match(/currently working/, response.body)
  end

  # --- turn status in poll response ---

  test "poll_messages returns running turn_status" do
    session = create_chat_session
    with_tenant_scope do
      AiAgentTaskRun.create!(
        tenant: @tenant, ai_agent: @ai_agent, initiated_by: @user,
        task: "Hello", max_steps: 30, status: "running",
        mode: "chat_turn", chat_session: session,
        started_at: Time.current,
      )
    end

    get "/chat/#{@agent_handle}/messages?after=#{1.minute.ago.iso8601}"
    assert_response :success
    assert_equal "running", response.parsed_body["turn_status"]
  end

  test "poll_messages returns failed turn_status with error" do
    session = create_chat_session
    with_tenant_scope do
      AiAgentTaskRun.create!(
        tenant: @tenant, ai_agent: @ai_agent, initiated_by: @user,
        task: "Hello", max_steps: 30, status: "failed",
        mode: "chat_turn", chat_session: session,
        error: "Something broke",
        completed_at: Time.current,
      )
    end

    get "/chat/#{@agent_handle}/messages?after=#{1.minute.ago.iso8601}"
    assert_response :success

    body = response.parsed_body
    assert_equal "failed", body["turn_status"]
    assert_equal "Something broke", body["turn_error"]
  end

  test "poll_messages returns null turn_status when no active turn" do
    create_chat_session

    get "/chat/#{@agent_handle}/messages?after=#{1.minute.ago.iso8601}"
    assert_response :success
    assert_nil response.parsed_body["turn_status"]
  end

  # --- markdown UI ---

  test "index renders markdown format" do
    get "/chat", headers: { "Accept" => "text/markdown" }
    assert_response :success
    assert_includes response.body, "# Chat"
  end

  test "show renders markdown format with messages" do
    session = create_chat_session
    with_chat_scope(session) do
      session.chat_messages.create!(sender: @user, content: "Hello!")
      session.chat_messages.create!(sender: @ai_agent, content: "Hi there!")
    end

    get "/chat/#{@agent_handle}", headers: { "Accept" => "text/markdown" }
    assert_response :success
    assert_includes response.body, "Hello!"
    assert_includes response.body, "Hi there!"
  end

  # --- actions ---

  test "actions_index lists send_message action" do
    create_chat_session
    get "/chat/#{@agent_handle}/actions", headers: { "Accept" => "text/markdown" }
    assert_response :success
    assert_includes response.body, "send_message"
  end

  test "describe_send_message shows action description" do
    create_chat_session
    get "/chat/#{@agent_handle}/actions/send_message", headers: { "Accept" => "text/markdown" }
    assert_response :success
    assert_includes response.body, "send_message"
    assert_includes response.body, "message"
  end

  test "execute_send_message creates message via action" do
    create_chat_session

    assert_difference "ChatMessage.count", 1 do
      post "/chat/#{@agent_handle}/actions/send_message",
        params: { message: "Hello via action!" },
        headers: { "Accept" => "text/markdown" }
    end
    assert_response :success
    assert_includes response.body, "Message sent"

    msg = ChatMessage.last
    assert_equal "Hello via action!", msg.content
  end

  test "execute_send_message rejects empty message" do
    create_chat_session

    assert_no_difference "ChatMessage.count" do
      post "/chat/#{@agent_handle}/actions/send_message",
        params: { message: "" },
        headers: { "Accept" => "text/markdown" }
    end
    assert_response :success
    assert_includes response.body, "cannot be empty"
  end

  # --- agent as sender (API token auth) ---

  test "agent can view chat via API token" do
    @tenant.enable_api!
    @collective.enable_api!

    session = create_chat_session
    with_chat_scope(session) do
      session.chat_messages.create!(sender: @user, content: "Hello agent!")
    end

    agent_token = with_tenant_scope do
      ApiToken.create!(tenant: @tenant, user: @ai_agent, scopes: ApiToken.valid_scopes)
    end
    user_handle = TenantUser.tenant_scoped_only(@tenant.id).find_by(user: @user).handle

    get "/chat/#{user_handle}",
      headers: { "Authorization" => "Bearer #{agent_token.plaintext_token}", "Accept" => "text/markdown" }
    assert_response :success
    assert_includes response.body, "Hello agent!"
  end

  test "agent can send message via API token" do
    @tenant.enable_api!
    @collective.enable_api!

    session = create_chat_session
    with_chat_scope(session) do
      session.chat_messages.create!(sender: @user, content: "Hello agent!")
    end

    agent_token = with_tenant_scope do
      ApiToken.create!(tenant: @tenant, user: @ai_agent, scopes: ApiToken.valid_scopes)
    end
    user_handle = TenantUser.tenant_scoped_only(@tenant.id).find_by(user: @user).handle

    # Clear browser session so API token auth is used
    reset!
    host! "#{@tenant.subdomain}.#{ENV['HOSTNAME']}"

    assert_difference "ChatMessage.count", 1 do
      post "/chat/#{user_handle}/actions/send_message",
        params: { message: "Hi human!" }.to_json,
        headers: { "Authorization" => "Bearer #{agent_token.plaintext_token}", "Accept" => "text/markdown", "Content-Type" => "application/json" }
    end
    assert_response :success

    msg = ChatMessage.order(created_at: :desc).find_by(content: "Hi human!")
    assert_not_nil msg, "Expected a ChatMessage with content 'Hi human!'"
    assert_equal @ai_agent.id, msg.sender_id
  end

  test "agent message does not dispatch a task run" do
    @tenant.enable_api!
    @collective.enable_api!

    session = create_chat_session
    with_chat_scope(session) do
      session.chat_messages.create!(sender: @user, content: "Hello!")
    end

    agent_token = with_tenant_scope do
      ApiToken.create!(tenant: @tenant, user: @ai_agent, scopes: ApiToken.valid_scopes)
    end
    user_handle = TenantUser.tenant_scoped_only(@tenant.id).find_by(user: @user).handle

    assert_no_difference "AiAgentTaskRun.count" do
      post "/chat/#{user_handle}/actions/send_message",
        params: { message: "Response" }.to_json,
        headers: { "Authorization" => "Bearer #{agent_token.plaintext_token}", "Accept" => "text/markdown", "Content-Type" => "application/json" }
    end
    assert_response :success
  end

  # --- ActionCable broadcast ---

  test "send_message broadcasts to ActionCable" do
    session = create_chat_session
    stream = ChatSessionChannel.broadcasting_for(session)

    assert_broadcasts(stream, 1) do
      post "/chat/#{@agent_handle}/message", params: { message: "Hello!" }
    end
    assert_response :ok
  end

  test "agent can start new chat with any tenant member" do
    @tenant.enable_api!
    @collective.enable_api!

    agent_token = with_tenant_scope do
      ApiToken.create!(tenant: @tenant, user: @ai_agent, scopes: ApiToken.valid_scopes)
    end
    other_user = create_user(email: "noconvo-#{SecureRandom.hex(4)}@example.com")
    @tenant.add_user!(other_user)
    other_handle = TenantUser.tenant_scoped_only(@tenant.id).find_by(user: other_user).handle

    get "/chat/#{other_handle}",
      headers: { "Authorization" => "Bearer #{agent_token.plaintext_token}", "Accept" => "text/markdown" }
    assert_response :success
  end

  # --- human-to-human chat ---

  test "human can start chat with another human" do
    other_human = create_user(email: "human2-#{SecureRandom.hex(4)}@example.com")
    @tenant.add_user!(other_human)
    @collective.add_user!(other_human)
    other_handle = TenantUser.tenant_scoped_only(@tenant.id).find_by(user: other_human).handle

    get "/chat/#{other_handle}"
    assert_response :success

    # Session should have been created
    with_tenant_scope do
      one, two = [@user.id, other_human.id].sort
      session = ChatSession.tenant_scoped_only(@tenant.id).find_by(user_one_id: one, user_two_id: two)
      assert_not_nil session
    end
  end

  test "human can send message to another human" do
    other_human = create_user(email: "human3-#{SecureRandom.hex(4)}@example.com")
    @tenant.add_user!(other_human)
    @collective.add_user!(other_human)
    other_handle = TenantUser.tenant_scoped_only(@tenant.id).find_by(user: other_human).handle

    assert_difference "ChatMessage.count", 1 do
      post "/chat/#{other_handle}/message", params: { message: "Hey there!" }
    end
    assert_response :ok

    msg = ChatMessage.order(created_at: :desc).find_by(content: "Hey there!")
    assert_equal @user.id, msg.sender_id
  end

  test "human-to-human message does not dispatch a task run" do
    other_human = create_user(email: "human4-#{SecureRandom.hex(4)}@example.com")
    @tenant.add_user!(other_human)
    @collective.add_user!(other_human)
    other_handle = TenantUser.tenant_scoped_only(@tenant.id).find_by(user: other_human).handle

    assert_no_difference "AiAgentTaskRun.count" do
      post "/chat/#{other_handle}/message", params: { message: "Hello!" }
    end
    assert_response :ok
  end

  # --- security ---

  test "cannot send message to another user's agent" do
    other_user = create_user(email: "other-owner2-#{SecureRandom.hex(4)}@example.com")
    @tenant.add_user!(other_user)
    @collective.add_user!(other_user)

    other_agent = create_ai_agent(parent: other_user, name: "Sealed Agent #{SecureRandom.hex(4)}")
    @tenant.add_user!(other_agent)
    @collective.add_user!(other_agent)
    other_handle = TenantUser.tenant_scoped_only(@tenant.id).find_by(user: other_agent).handle

    assert_no_difference "ChatMessage.count" do
      post "/chat/#{other_handle}/message", params: { message: "sneaky" }
    end
    assert_response :not_found
  end

  test "cannot access chat with user on another tenant" do
    other_tenant = create_tenant(subdomain: "sec-test-#{SecureRandom.hex(4)}", name: "Other Org")
    other_user = create_user(email: "cross-tenant-#{SecureRandom.hex(4)}@example.com")
    other_tenant.add_user!(other_user)

    # The user exists but has no tenant_user on our tenant, so lookup returns 404
    tu = TenantUser.unscoped.find_by(user: other_user, tenant: other_tenant)
    get "/chat/#{tu.handle}"
    assert_response :not_found
  end

  test "message sender_id is always the authenticated user" do
    other_human = create_user(email: "human5-#{SecureRandom.hex(4)}@example.com")
    @tenant.add_user!(other_human)
    @collective.add_user!(other_human)
    other_handle = TenantUser.tenant_scoped_only(@tenant.id).find_by(user: other_human).handle

    post "/chat/#{other_handle}/message", params: { message: "test auth" }
    assert_response :ok

    msg = ChatMessage.order(created_at: :desc).find_by(content: "test auth")
    assert_equal @user.id, msg.sender_id, "sender must be the authenticated user, not spoofable"
  end

  # --- chat notifications ---

  test "sending a message creates a notification for the recipient" do
    post "/chat/#{@agent_handle}/message", params: { message: "Hey agent" }
    assert_response :ok

    with_tenant_scope do
      recipients = NotificationRecipient.where(user: @ai_agent).in_app.unread
      assert_equal 1, recipients.count
      notif = recipients.first.notification
      assert_equal "chat_message", notif.notification_type
      assert_includes notif.url, "/chat/"
    end
  end

  test "multiple messages from the same sender create only one notification" do
    3.times do |i|
      post "/chat/#{@agent_handle}/message", params: { message: "Message #{i}" }
      assert_response :ok
    end

    with_tenant_scope do
      recipients = NotificationRecipient.where(user: @ai_agent).in_app.unread
      assert_equal 1, recipients.count, "should be one notification, not one per message"
    end
  end

  test "replying auto-dismisses the notification from the other participant" do
    other_human = create_user(email: "notif-test-#{SecureRandom.hex(4)}@example.com")
    @tenant.add_user!(other_human)
    @collective.add_user!(other_human)
    other_handle = TenantUser.tenant_scoped_only(@tenant.id).find_by(user: other_human).handle

    # Other human sends a message to current user
    sign_in_as(other_human, tenant: @tenant)
    my_handle = TenantUser.tenant_scoped_only(@tenant.id).find_by(user: @user).handle
    post "/chat/#{my_handle}/message", params: { message: "Hey!" }
    assert_response :ok

    # Current user should have a notification
    with_tenant_scope do
      assert_equal 1, NotificationRecipient.where(user: @user).in_app.unread.count
    end

    # Current user replies
    sign_in_as(@user, tenant: @tenant)
    post "/chat/#{other_handle}/message", params: { message: "Hey back!" }
    assert_response :ok

    # Notification from other_human should be dismissed
    with_tenant_scope do
      assert_equal 0, NotificationRecipient.where(user: @user).in_app.unread.count,
        "replying should auto-dismiss notification from the other participant"
    end
  end

  test "notification URL points to the sender's chat page" do
    post "/chat/#{@agent_handle}/message", params: { message: "Check URL" }
    assert_response :ok

    with_tenant_scope do
      my_handle = TenantUser.tenant_scoped_only(@tenant.id).find_by(user: @user).handle
      recipient = NotificationRecipient.where(user: @ai_agent).in_app.unread.first
      assert_equal "/chat/#{my_handle}", recipient.notification.url
    end
  end

  test "replying only dismisses notifications from that specific sender" do
    hex = SecureRandom.hex(4)
    alice = create_user(name: "Alice #{hex}", email: "alice-#{hex}@example.com")
    bob = create_user(name: "Bob #{hex}", email: "bob-#{hex}@example.com")
    @tenant.add_user!(alice)
    @tenant.add_user!(bob)
    @collective.add_user!(alice)
    @collective.add_user!(bob)
    alice_handle = TenantUser.tenant_scoped_only(@tenant.id).find_by(user: alice).handle
    bob_handle = TenantUser.tenant_scoped_only(@tenant.id).find_by(user: bob).handle
    my_handle = TenantUser.tenant_scoped_only(@tenant.id).find_by(user: @user).handle

    # Both Alice and Bob message the current user
    sign_in_as(alice, tenant: @tenant)
    post "/chat/#{my_handle}/message", params: { message: "Hi from Alice" }

    sign_in_as(bob, tenant: @tenant)
    post "/chat/#{my_handle}/message", params: { message: "Hi from Bob" }

    # Current user has two notifications
    with_tenant_scope do
      assert_equal 2, NotificationRecipient.where(user: @user).in_app.unread.count
    end

    # Reply only to Alice
    sign_in_as(@user, tenant: @tenant)
    post "/chat/#{alice_handle}/message", params: { message: "Hey Alice" }

    # Bob's notification should remain
    with_tenant_scope do
      remaining = NotificationRecipient.where(user: @user).in_app.unread
      assert_equal 1, remaining.count
      assert_equal "/chat/#{bob_handle}", remaining.first.notification.url
    end
  end

  test "agent sending via API creates notification for human" do
    @tenant.enable_api!
    @collective.enable_api!

    create_chat_session

    agent_token = with_tenant_scope do
      ApiToken.create!(tenant: @tenant, user: @ai_agent, scopes: ApiToken.valid_scopes)
    end
    user_handle = TenantUser.tenant_scoped_only(@tenant.id).find_by(user: @user).handle

    # Clear browser session so API token auth is used
    reset!
    host! "#{@tenant.subdomain}.#{ENV['HOSTNAME']}"

    post "/chat/#{user_handle}/actions/send_message",
      params: { message: "Agent here" }.to_json,
      headers: { "Authorization" => "Bearer #{agent_token.plaintext_token}", "Accept" => "text/markdown", "Content-Type" => "application/json" }
    assert_response :success

    with_tenant_scope do
      recipients = NotificationRecipient.where(user: @user).in_app.unread
      assert_equal 1, recipients.count
      assert_equal "chat_message", recipients.first.notification.notification_type
    end
  end

  # --- self-chat ---

  test "user can chat with themselves" do
    my_handle = TenantUser.tenant_scoped_only(@tenant.id).find_by(user: @user).handle

    get "/chat/#{my_handle}"
    assert_response :success

    assert_difference "ChatMessage.count", 1 do
      post "/chat/#{my_handle}/message", params: { message: "Note to self" }
    end
    assert_response :ok
  end

  test "self-chat does not create a notification" do
    my_handle = TenantUser.tenant_scoped_only(@tenant.id).find_by(user: @user).handle

    post "/chat/#{my_handle}/message", params: { message: "Reminder" }
    assert_response :ok

    with_tenant_scope do
      assert_equal 0, NotificationRecipient.where(user: @user).in_app.unread.count,
        "should not notify yourself"
    end
  end

  # --- sidebar unread badge ---

  test "sidebar shows unread dot for partner with pending notification" do
    other_human = create_user(name: "Unread Sender #{SecureRandom.hex(4)}", email: "unread-#{SecureRandom.hex(4)}@example.com")
    @tenant.add_user!(other_human)
    @collective.add_user!(other_human)
    other_handle = TenantUser.tenant_scoped_only(@tenant.id).find_by(user: other_human).handle
    my_handle = TenantUser.tenant_scoped_only(@tenant.id).find_by(user: @user).handle

    # Other human sends a message
    sign_in_as(other_human, tenant: @tenant)
    post "/chat/#{my_handle}/message", params: { message: "Read me!" }
    assert_response :ok

    # Current user views the chat index — sidebar should show unread indicator
    sign_in_as(@user, tenant: @tenant)
    get "/chat/#{other_handle}"
    assert_response :success
    assert_select "[data-unread-chat]", minimum: 1
  end

  test "sidebar does not show unread dot after replying" do
    other_human = create_user(name: "Reply Test #{SecureRandom.hex(4)}", email: "reply-#{SecureRandom.hex(4)}@example.com")
    @tenant.add_user!(other_human)
    @collective.add_user!(other_human)
    other_handle = TenantUser.tenant_scoped_only(@tenant.id).find_by(user: other_human).handle
    my_handle = TenantUser.tenant_scoped_only(@tenant.id).find_by(user: @user).handle

    # Other human sends a message
    sign_in_as(other_human, tenant: @tenant)
    post "/chat/#{my_handle}/message", params: { message: "Hey!" }

    # Current user replies
    sign_in_as(@user, tenant: @tenant)
    post "/chat/#{other_handle}/message", params: { message: "Hey back!" }

    # View the page — no unread dot
    get "/chat/#{other_handle}"
    assert_response :success
    assert_select "[data-unread-chat]", 0
  end

  # --- sidebar ordering ---

  test "sidebar sorts partners by most recent message" do
    hex = SecureRandom.hex(4)
    alice = create_user(name: "Alice Order #{hex}", email: "alice-order-#{hex}@example.com")
    bob = create_user(name: "Bob Order #{hex}", email: "bob-order-#{hex}@example.com")
    @tenant.add_user!(alice)
    @tenant.add_user!(bob)
    @collective.add_user!(alice)
    @collective.add_user!(bob)
    alice_handle = TenantUser.tenant_scoped_only(@tenant.id).find_by(user: alice).handle
    bob_handle = TenantUser.tenant_scoped_only(@tenant.id).find_by(user: bob).handle

    # Send messages: Alice first, then Bob (Bob is more recent)
    post "/chat/#{alice_handle}/message", params: { message: "Hi Alice" }
    post "/chat/#{bob_handle}/message", params: { message: "Hi Bob" }

    # View any chat page — Bob should be first (most recent), then Alice
    get "/chat/#{alice_handle}"
    assert_response :success
    links = css_select("a[href^='/chat/']").map { |a| a["href"] }
    alice_idx = links.index("/chat/#{alice_handle}")
    bob_idx = links.index("/chat/#{bob_handle}")
    assert_not_nil alice_idx, "Alice should appear in sidebar"
    assert_not_nil bob_idx, "Bob should appear in sidebar"
    assert bob_idx < alice_idx, "Bob (more recent message) should appear before Alice"

    # Order is stable regardless of which chat is active
    get "/chat/#{bob_handle}"
    assert_response :success
    links = css_select("a[href^='/chat/']").map { |a| a["href"] }
    alice_idx = links.index("/chat/#{alice_handle}")
    bob_idx = links.index("/chat/#{bob_handle}")
    assert bob_idx < alice_idx, "Order should be the same regardless of active chat"
  end

  # --- block enforcement ---

  test "blocked user sees chat in read-only mode with block banner" do
    other_human = create_user(email: "block-view-#{SecureRandom.hex(4)}@example.com", name: "BlockerPerson")
    @tenant.add_user!(other_human)
    @collective.add_user!(other_human)
    other_handle = TenantUser.tenant_scoped_only(@tenant.id).find_by(user: other_human).handle

    # Create a session first (chat existed before the block)
    post "/chat/#{other_handle}/message", params: { message: "Hi" }
    assert_response :ok

    with_tenant_scope do
      UserBlock.create!(blocker: other_human, blocked: @user, tenant: @tenant)
    end

    get "/chat/#{other_handle}"
    assert_response :success
    assert_match(/BlockerPerson has blocked you/, response.body)
    assert_no_match(/Type a message/, response.body)
  end

  test "blocker sees chat in read-only mode with block banner" do
    other_human = create_user(email: "block-view2-#{SecureRandom.hex(4)}@example.com", name: "BlockedPerson")
    @tenant.add_user!(other_human)
    @collective.add_user!(other_human)
    other_handle = TenantUser.tenant_scoped_only(@tenant.id).find_by(user: other_human).handle

    # Create a session first (chat existed before the block)
    post "/chat/#{other_handle}/message", params: { message: "Hi" }
    assert_response :ok

    with_tenant_scope do
      UserBlock.create!(blocker: @user, blocked: other_human, tenant: @tenant)
    end

    get "/chat/#{other_handle}"
    assert_response :success
    assert_match(/You have blocked BlockedPerson/, response.body)
    assert_match(/Manage blocks/, response.body)
    assert_no_match(/Type a message/, response.body)
  end

  test "blocked chat returns 403 when no prior session exists" do
    other_human = create_user(email: "block-nosession-#{SecureRandom.hex(4)}@example.com")
    @tenant.add_user!(other_human)
    @collective.add_user!(other_human)
    other_handle = TenantUser.tenant_scoped_only(@tenant.id).find_by(user: other_human).handle

    with_tenant_scope do
      UserBlock.create!(blocker: other_human, blocked: @user, tenant: @tenant)
    end

    get "/chat/#{other_handle}"
    assert_response :forbidden
  end

  test "blocked user cannot send message to blocker" do
    other_human = create_user(email: "block-send-#{SecureRandom.hex(4)}@example.com")
    @tenant.add_user!(other_human)
    @collective.add_user!(other_human)
    other_handle = TenantUser.tenant_scoped_only(@tenant.id).find_by(user: other_human).handle

    # Create session first, then block
    post "/chat/#{other_handle}/message", params: { message: "Before block" }
    assert_response :ok

    with_tenant_scope do
      UserBlock.create!(blocker: other_human, blocked: @user, tenant: @tenant)
    end

    assert_no_difference "ChatMessage.count" do
      post "/chat/#{other_handle}/message", params: { message: "After block" }
    end
    assert_response :forbidden
  end

  test "blocker cannot send message to blocked user" do
    other_human = create_user(email: "block-send2-#{SecureRandom.hex(4)}@example.com")
    @tenant.add_user!(other_human)
    @collective.add_user!(other_human)
    other_handle = TenantUser.tenant_scoped_only(@tenant.id).find_by(user: other_human).handle

    with_tenant_scope do
      UserBlock.create!(blocker: @user, blocked: other_human, tenant: @tenant)
    end

    assert_no_difference "ChatMessage.count" do
      post "/chat/#{other_handle}/message", params: { message: "After block" }
    end
    assert_response :forbidden
  end

  test "blocked users do not appear in chat partner list" do
    other_human = create_user(email: "block-list-#{SecureRandom.hex(4)}@example.com")
    @tenant.add_user!(other_human)
    @collective.add_user!(other_human)
    other_handle = TenantUser.tenant_scoped_only(@tenant.id).find_by(user: other_human).handle

    # Create a chat session so the user would normally appear
    post "/chat/#{other_handle}/message", params: { message: "Hi" }
    assert_response :ok

    # Now block them
    with_tenant_scope do
      UserBlock.create!(blocker: @user, blocked: other_human, tenant: @tenant)
    end

    get "/chat"
    assert_response :success
    assert_no_match(/#{other_handle}/, response.body)
  end

  test "block between users prevents chat with the other user's agent" do
    other_user = create_user(email: "block-agent-#{SecureRandom.hex(4)}@example.com")
    @tenant.add_user!(other_user)
    @collective.add_user!(other_user)

    other_agent = create_ai_agent(parent: other_user, name: "Other Agent #{SecureRandom.hex(4)}")
    other_agent.update!(agent_configuration: { "mode" => "external" })
    @tenant.add_user!(other_agent)
    @collective.add_user!(other_agent)

    with_tenant_scope do
      UserBlock.create!(blocker: @user, blocked: other_user, tenant: @tenant)
    end

    # The agent's owner is blocked, but the block is between humans.
    # The user can still access the agent (agent != owner).
    # Blocks only apply to the direct participants in the chat.
    other_agent_handle = TenantUser.tenant_scoped_only(@tenant.id).find_by(user: other_agent).handle

    # Agent not owned by current_user → 404 (existing authorization)
    get "/chat/#{other_agent_handle}"
    assert_response :not_found
  end

  # --- external agent chat ---

  test "sending message to external agent does not show thinking indicator" do
    external_agent = create_ai_agent(parent: @user, name: "External Agent #{SecureRandom.hex(4)}")
    external_agent.update!(agent_configuration: { "mode" => "external" })
    @tenant.add_user!(external_agent)
    @collective.add_user!(external_agent)
    ext_handle = TenantUser.tenant_scoped_only(@tenant.id).find_by(user: external_agent).handle

    get "/chat/#{ext_handle}"
    assert_response :success
    assert_select "[data-agent-chat-partner-is-agent-value='false']"
  end

  test "sending message to internal agent shows thinking indicator" do
    get "/chat/#{@agent_handle}"
    assert_response :success
    assert_select "[data-agent-chat-partner-is-agent-value='true']"
  end

end
