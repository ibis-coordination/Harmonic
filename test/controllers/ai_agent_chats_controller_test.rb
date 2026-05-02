# typed: false
require "test_helper"

class AiAgentChatsControllerTest < ActionDispatch::IntegrationTest
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
      ChatSession.create!(tenant: @tenant, ai_agent: @ai_agent, initiated_by: @user)
    end
  end

  public

  # --- index ---

  test "index renders chat sessions list" do
    get "/ai-agents/#{@agent_handle}/chat"
    assert_response :success
  end

  test "index requires authentication" do
    delete "/logout"
    get "/ai-agents/#{@agent_handle}/chat"
    assert_response :redirect
  end

  test "index returns 404 for agent not owned by current user" do
    other_user = create_user(email: "other-owner-#{SecureRandom.hex(4)}@example.com")
    @tenant.add_user!(other_user)
    @collective.add_user!(other_user)

    other_agent = create_ai_agent(parent: other_user, name: "Other Agent #{SecureRandom.hex(4)}")
    @tenant.add_user!(other_agent)
    @collective.add_user!(other_agent)
    other_handle = TenantUser.tenant_scoped_only(@tenant.id).find_by(user: other_agent).handle

    get "/ai-agents/#{other_handle}/chat"
    assert_response :not_found
  end

  test "index rejects non-human users" do
    # AI agent users can't establish a session — they get redirected to login,
    # which is the first line of defense. require_human_user is defense-in-depth.
    sign_in_as(@ai_agent, tenant: @tenant)
    get "/ai-agents/#{@agent_handle}/chat"
    assert_response :redirect
  end

  # --- create ---

  test "create starts a new chat session and redirects to it" do
    assert_difference "ChatSession.count", 1 do
      post "/ai-agents/#{@agent_handle}/chat"
    end

    session = ChatSession.tenant_scoped_only(@tenant.id).order(created_at: :desc).first
    assert_equal @ai_agent.id, session.ai_agent_id
    assert_equal @user.id, session.initiated_by_id
    assert_redirected_to "/ai-agents/#{@agent_handle}/chat/#{session.id}"
  end

  test "create enforces one session per agent-user pair" do
    session1 = create_chat_session

    assert_raises(ActiveRecord::RecordInvalid) do
      with_tenant_scope do
        ChatSession.create!(tenant: @tenant, ai_agent: @ai_agent, initiated_by: @user)
      end
    end
  end

  # --- show ---

  test "show renders chat session with messages" do
    session = create_chat_session
    with_tenant_scope do
      session.chat_messages.create!(sender: @user, content: "Hello")
      session.chat_messages.create!(sender: @ai_agent, content: "Hi!")
    end

    get "/ai-agents/#{@agent_handle}/chat/#{session.id}"
    assert_response :success
  end

  test "show returns 404 for other user's session" do
    session = create_chat_session
    other_user = create_user(email: "other-#{SecureRandom.hex(4)}@example.com")
    @tenant.add_user!(other_user)
    sign_in_as(other_user, tenant: @tenant)

    get "/ai-agents/#{@agent_handle}/chat/#{session.id}"
    assert_response :not_found
  end

  # --- send_message ---

  test "send_message creates chat message and dispatches task" do
    session = create_chat_session

    assert_difference "ChatMessage.count", 1 do
      assert_difference "AiAgentTaskRun.count", 1 do
        post "/ai-agents/#{@agent_handle}/chat/#{session.id}/message",
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

  test "send_message returns 404 for other user's session" do
    session = create_chat_session
    other_user = create_user(email: "other-send-#{SecureRandom.hex(4)}@example.com")
    @tenant.add_user!(other_user)
    sign_in_as(other_user, tenant: @tenant)

    assert_no_difference "ChatMessage.count" do
      post "/ai-agents/#{@agent_handle}/chat/#{session.id}/message",
        params: { message: "Injected message" }
    end
    assert_response :not_found
  end

  test "send_message rejects empty message" do
    session = create_chat_session

    assert_no_difference "ChatMessage.count" do
      post "/ai-agents/#{@agent_handle}/chat/#{session.id}/message", params: { message: "" }
    end
    assert_response :unprocessable_entity
  end

  test "send_message truncates long messages" do
    session = create_chat_session

    long_message = "a" * 20_000
    post "/ai-agents/#{@agent_handle}/chat/#{session.id}/message", params: { message: long_message }
    assert_response :ok

    msg = ChatMessage.last
    assert_equal AiAgentChatsController::MAX_MESSAGE_LENGTH, msg.content.length
  end

  test "send_message skips dispatch if a turn is already running" do
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
        post "/ai-agents/#{@agent_handle}/chat/#{session.id}/message",
          params: { message: "Follow-up" }
      end
    end
  end

  # --- poll_messages ---

  test "poll_messages returns new messages after timestamp" do
    session = with_tenant_scope do
      cs = ChatSession.create!(tenant: @tenant, ai_agent: @ai_agent, initiated_by: @user)
      cs.chat_messages.create!(sender: @user, content: "Hello", created_at: 10.seconds.ago)
      cs.chat_messages.create!(sender: @ai_agent, content: "Hi there!", created_at: 5.seconds.ago)
      cs
    end

    get "/ai-agents/#{@agent_handle}/chat/#{session.id}/messages?after=#{8.seconds.ago.iso8601}"
    assert_response :success

    messages = response.parsed_body["messages"]
    assert_equal 1, messages.length
    assert_equal "Hi there!", messages[0]["content"]
    assert_equal true, messages[0]["is_agent"]
  end

  test "poll_messages returns 404 for other user's session" do
    session = create_chat_session
    other_user = create_user(email: "other-poll-#{SecureRandom.hex(4)}@example.com")
    @tenant.add_user!(other_user)
    sign_in_as(other_user, tenant: @tenant)

    get "/ai-agents/#{@agent_handle}/chat/#{session.id}/messages?after=#{1.minute.ago.iso8601}"
    assert_response :not_found
  end

  test "poll_messages returns turn_status when a turn is running" do
    session = create_chat_session
    with_tenant_scope do
      AiAgentTaskRun.create!(
        tenant: @tenant, ai_agent: @ai_agent, initiated_by: @user,
        task: "Hello", max_steps: 30, status: "running",
        mode: "chat_turn", chat_session: session,
        started_at: Time.current,
      )
    end

    get "/ai-agents/#{@agent_handle}/chat/#{session.id}/messages?after=#{1.minute.ago.iso8601}"
    assert_response :success

    body = response.parsed_body
    assert_equal "running", body["turn_status"]
  end

  test "poll_messages returns turn_status failed with error" do
    session = create_chat_session
    with_tenant_scope do
      AiAgentTaskRun.create!(
        tenant: @tenant, ai_agent: @ai_agent, initiated_by: @user,
        task: "Hello", max_steps: 30, status: "failed",
        mode: "chat_turn", chat_session: session,
        error: "LLM API error",
        completed_at: Time.current,
      )
    end

    get "/ai-agents/#{@agent_handle}/chat/#{session.id}/messages?after=#{1.minute.ago.iso8601}"
    assert_response :success

    body = response.parsed_body
    assert_equal "failed", body["turn_status"]
    assert_equal "LLM API error", body["turn_error"]
  end

  test "poll_messages returns null turn_status when no active turn" do
    session = create_chat_session

    get "/ai-agents/#{@agent_handle}/chat/#{session.id}/messages?after=#{1.minute.ago.iso8601}"
    assert_response :success

    body = response.parsed_body
    assert_nil body["turn_status"]
  end

  test "poll_messages returns latest activity for running turn" do
    session = create_chat_session
    with_tenant_scope do
      session.chat_messages.create!(sender: @user, content: "Hello")
      run = AiAgentTaskRun.create!(
        tenant: @tenant, ai_agent: @ai_agent, initiated_by: @user,
        task: "Hello", max_steps: 30, status: "running",
        mode: "chat_turn", chat_session: session,
        started_at: Time.current,
      )
      run.agent_session_steps.create!(
        position: 0, step_type: "think",
        detail: { step_number: 0 },
      )
      run.agent_session_steps.create!(
        position: 1, step_type: "navigate",
        detail: { path: "/collectives/team" },
      )
    end

    get "/ai-agents/#{@agent_handle}/chat/#{session.id}/messages?after=#{1.minute.ago.iso8601}"
    assert_response :success

    body = response.parsed_body
    assert_equal "Navigating to /collectives/team", body["activity"]
  end

  # --- busy agent ---

  test "show sets agent_busy when agent has running non-chat task" do
    session = create_chat_session
    with_tenant_scope do
      AiAgentTaskRun.create!(
        tenant: @tenant, ai_agent: @ai_agent, initiated_by: @user,
        task: "Working on something", max_steps: 30, status: "running",
        mode: "task",
        started_at: Time.current,
      )
    end

    get "/ai-agents/#{@agent_handle}/chat/#{session.id}"
    assert_response :success
    assert_match(/currently working/, response.body)
  end

  test "show does not show busy indicator when agent is working in this session" do
    session = create_chat_session
    with_tenant_scope do
      AiAgentTaskRun.create!(
        tenant: @tenant, ai_agent: @ai_agent, initiated_by: @user,
        task: "Working here", max_steps: 30, status: "running",
        mode: "chat_turn", chat_session: session,
        started_at: Time.current,
      )
    end

    get "/ai-agents/#{@agent_handle}/chat/#{session.id}"
    assert_response :success
    assert_no_match(/currently working/, response.body)
  end

  test "poll_messages returns empty array when no new messages" do
    session = with_tenant_scope do
      cs = ChatSession.create!(tenant: @tenant, ai_agent: @ai_agent, initiated_by: @user)
      cs.chat_messages.create!(sender: @user, content: "Hello")
      cs
    end

    get "/ai-agents/#{@agent_handle}/chat/#{session.id}/messages?after=#{1.minute.from_now.iso8601}"
    assert_response :success
    assert_equal 0, response.parsed_body["messages"].length
  end

end
