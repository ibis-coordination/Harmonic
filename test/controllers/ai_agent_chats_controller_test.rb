# typed: false
require "test_helper"

class AiAgentChatsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = @global_tenant
    @user = @global_user
    @tenant.enable_feature_flag!("ai_agents")
    # Use main collective since that's what the request resolves to
    @collective = @tenant.main_collective

    @ai_agent = create_ai_agent(parent: @user)
    @tenant.add_user!(@ai_agent)
    @collective.add_user!(@ai_agent)
    @agent_handle = TenantUser.tenant_scoped_only(@tenant.id).find_by(user: @ai_agent).handle

    sign_in_as(@user, tenant: @tenant)
  end

  private

  # Set tenant/collective thread context for creating test records outside request context
  def with_tenant_scope(&block)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    yield
  ensure
    Tenant.clear_thread_scope
    Collective.clear_thread_scope
  end

  public

  # --- show ---

  test "show renders chat page with no active session" do
    get "/ai-agents/#{@agent_handle}/chat"
    assert_response :success
    assert_select "article" # chat container renders
  end

  test "show renders chat page with active session and messages" do
    with_tenant_scope do
      session = ChatSession.create!(
        tenant: @tenant,
               ai_agent: @ai_agent,
        initiated_by: @user,
      )
      run = AiAgentTaskRun.create!(
        tenant: @tenant, ai_agent: @ai_agent, initiated_by: @user,
        task: "Hello", max_steps: 30, status: "completed",
        mode: "chat_turn", chat_session: session,
      )
      run.agent_session_steps.create!(position: 0, step_type: "message", detail: { content: "Hello" }, sender: @user)
      run.agent_session_steps.create!(position: 1, step_type: "message", detail: { content: "Hi!" }, sender: @ai_agent)
    end

    get "/ai-agents/#{@agent_handle}/chat"
    assert_response :success
  end

  test "show requires authentication" do
    delete "/logout"
    get "/ai-agents/#{@agent_handle}/chat"
    assert_response :redirect
  end

  # --- create ---

  test "create starts a new chat session" do
    assert_difference "ChatSession.count", 1 do
      post "/ai-agents/#{@agent_handle}/chat"
    end

    session = ChatSession.last
    assert_equal @ai_agent.id, session.ai_agent_id
    assert_equal @user.id, session.initiated_by_id
    assert_equal "active", session.status
    assert_redirected_to "/ai-agents/#{@agent_handle}/chat"
  end

  test "create does not create duplicate active session" do
    with_tenant_scope do
      ChatSession.create!(
        tenant: @tenant,        ai_agent: @ai_agent, initiated_by: @user,
      )
    end

    assert_no_difference "ChatSession.count" do
      post "/ai-agents/#{@agent_handle}/chat"
    end
    assert_redirected_to "/ai-agents/#{@agent_handle}/chat"
  end

  # --- send_message ---

  test "send_message creates message step and dispatches task" do
    session = with_tenant_scope do
      ChatSession.create!(
        tenant: @tenant,        ai_agent: @ai_agent, initiated_by: @user,
      )
    end

    assert_difference "AgentSessionStep.count", 1 do
      assert_difference "AiAgentTaskRun.count", 1 do
        post "/ai-agents/#{@agent_handle}/chat/message",
          params: { message: "Hello agent!" }
      end
    end

    step = AgentSessionStep.last
    assert_equal "message", step.step_type
    assert_equal @user.id, step.sender_id
    assert_equal "Hello agent!", step.detail["content"]

    task_run = AiAgentTaskRun.last
    assert_equal "chat_turn", task_run.mode
    assert_equal session.id, task_run.chat_session_id
    assert_equal "Hello agent!", task_run.task
  end

  test "send_message rejects empty message" do
    with_tenant_scope do
      ChatSession.create!(
        tenant: @tenant,        ai_agent: @ai_agent, initiated_by: @user,
      )
    end

    assert_no_difference "AgentSessionStep.count" do
      post "/ai-agents/#{@agent_handle}/chat/message", params: { message: "" }
    end
    assert_response :unprocessable_entity
  end

  test "send_message truncates long messages" do
    with_tenant_scope do
      ChatSession.create!(
        tenant: @tenant,        ai_agent: @ai_agent, initiated_by: @user,
      )
    end

    long_message = "a" * 20_000
    post "/ai-agents/#{@agent_handle}/chat/message", params: { message: long_message }
    assert_response :ok

    step = AgentSessionStep.last
    assert_equal AiAgentChatsController::MAX_MESSAGE_LENGTH, step.detail["content"].length
  end

  test "send_message skips dispatch if a turn is already running" do
    with_tenant_scope do
      session = ChatSession.create!(
        tenant: @tenant,        ai_agent: @ai_agent, initiated_by: @user,
      )
      AiAgentTaskRun.create!(
        tenant: @tenant, ai_agent: @ai_agent, initiated_by: @user,
        task: "Previous message", max_steps: 30, status: "running",
        mode: "chat_turn", chat_session: session,
        started_at: Time.current,
      )
    end

    # Message should be saved but no new task dispatched
    assert_difference "AgentSessionStep.count", 1 do
      assert_no_difference "AiAgentTaskRun.count" do
        post "/ai-agents/#{@agent_handle}/chat/message",
          params: { message: "Follow-up" }
      end
    end
  end

  # --- poll_messages ---

  test "poll_messages returns new messages after timestamp" do
    session = with_tenant_scope do
      cs = ChatSession.create!(tenant: @tenant, ai_agent: @ai_agent, initiated_by: @user)
      run = AiAgentTaskRun.create!(
        tenant: @tenant, ai_agent: @ai_agent, initiated_by: @user,
        task: "Hello", max_steps: 30, status: "completed",
        mode: "chat_turn", chat_session: cs,
      )
      run.agent_session_steps.create!(
        position: 0, step_type: "message",
        detail: { content: "Hello" }, sender: @user,
        created_at: 10.seconds.ago,
      )
      run.agent_session_steps.create!(
        position: 1, step_type: "message",
        detail: { content: "Hi there!" }, sender: @ai_agent,
        created_at: 5.seconds.ago,
      )
      cs
    end

    # Ask for messages after the first one
    get "/ai-agents/#{@agent_handle}/chat/messages?after=#{8.seconds.ago.iso8601}"
    assert_response :success

    messages = response.parsed_body["messages"]
    assert_equal 1, messages.length
    assert_equal "Hi there!", messages[0]["content"]
    assert_equal true, messages[0]["is_agent"]
    assert_equal "message", messages[0]["type"]
  end

  test "poll_messages returns empty array when no new messages" do
    with_tenant_scope do
      cs = ChatSession.create!(tenant: @tenant, ai_agent: @ai_agent, initiated_by: @user)
      run = AiAgentTaskRun.create!(
        tenant: @tenant, ai_agent: @ai_agent, initiated_by: @user,
        task: "Hello", max_steps: 30, status: "completed",
        mode: "chat_turn", chat_session: cs,
      )
      run.agent_session_steps.create!(
        position: 0, step_type: "message",
        detail: { content: "Hello" }, sender: @user,
      )
    end

    get "/ai-agents/#{@agent_handle}/chat/messages?after=#{1.minute.from_now.iso8601}"
    assert_response :success
    assert_equal 0, response.parsed_body["messages"].length
  end

  test "poll_messages returns same format as ActionCable broadcast" do
    session = with_tenant_scope do
      cs = ChatSession.create!(tenant: @tenant, ai_agent: @ai_agent, initiated_by: @user)
      run = AiAgentTaskRun.create!(
        tenant: @tenant, ai_agent: @ai_agent, initiated_by: @user,
        task: "Test", max_steps: 30, status: "completed",
        mode: "chat_turn", chat_session: cs,
      )
      run.agent_session_steps.create!(
        position: 0, step_type: "message",
        detail: { content: "Agent says hi" }, sender: @ai_agent,
      )
      cs
    end

    get "/ai-agents/#{@agent_handle}/chat/messages?after=#{1.hour.ago.iso8601}"
    assert_response :success

    msg = response.parsed_body["messages"][0]
    # Verify all fields that ActionCable would send are present
    assert_equal "message", msg["type"]
    assert_not_nil msg["id"]
    assert_not_nil msg["sender_id"]
    assert_not_nil msg["sender_name"]
    assert_equal "Agent says hi", msg["content"]
    assert_not_nil msg["timestamp"]
    assert_equal true, msg["is_agent"]
  end

  # --- end_session ---

  test "end_session marks session as ended" do
    session = with_tenant_scope do
      ChatSession.create!(
        tenant: @tenant,        ai_agent: @ai_agent, initiated_by: @user,
      )
    end

    post "/ai-agents/#{@agent_handle}/chat/end"

    session.reload
    assert_equal "ended", session.status
    assert_redirected_to "/ai-agents/#{@agent_handle}/chat"
  end

  test "end_session cancels running task runs" do
    session = nil
    running_run = nil
    with_tenant_scope do
      session = ChatSession.create!(
        tenant: @tenant,        ai_agent: @ai_agent, initiated_by: @user,
      )
      running_run = AiAgentTaskRun.create!(
        tenant: @tenant, ai_agent: @ai_agent, initiated_by: @user,
        task: "Working on it", max_steps: 30, status: "running",
        mode: "chat_turn", chat_session: session,
        started_at: Time.current,
      )
    end

    post "/ai-agents/#{@agent_handle}/chat/end"

    running_run.reload
    assert_equal "cancelled", running_run.status
    assert_not_nil running_run.completed_at
  end

end
