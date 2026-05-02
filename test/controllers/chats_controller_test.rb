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

  def create_chat_session
    with_tenant_scope do
      ChatSession.find_or_create_for(agent: @ai_agent, user: @user, tenant: @tenant)
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
      session = ChatSession.find_by(ai_agent: @ai_agent, initiated_by: @user)
      assert_not_nil session
    end
  end

  test "show reuses existing session on subsequent visits" do
    session = create_chat_session

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
    with_tenant_scope do
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
    with_tenant_scope do
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
    with_tenant_scope do
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
    with_tenant_scope do
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
    with_tenant_scope do
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
    with_tenant_scope do
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
    with_tenant_scope do
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
    with_tenant_scope do
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
    with_tenant_scope do
      session.chat_messages.create!(sender: @user, content: "Hello agent!")
    end

    agent_token = with_tenant_scope do
      ApiToken.create!(tenant: @tenant, user: @ai_agent, scopes: ApiToken.valid_scopes)
    end
    user_handle = TenantUser.tenant_scoped_only(@tenant.id).find_by(user: @user).handle

    assert_difference "ChatMessage.count", 1 do
      post "/chat/#{user_handle}/actions/send_message",
        params: { message: "Hi human!" }.to_json,
        headers: { "Authorization" => "Bearer #{agent_token.plaintext_token}", "Accept" => "text/markdown", "Content-Type" => "application/json" }
    end
    assert_response :success

    msg = ChatMessage.last
    assert_equal @ai_agent.id, msg.sender_id
    assert_equal "Hi human!", msg.content
  end

  test "agent message does not dispatch a task run" do
    @tenant.enable_api!
    @collective.enable_api!

    session = create_chat_session
    with_tenant_scope do
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

  test "agent returns 404 for nonexistent chat session" do
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
    assert_response :not_found
  end
end
