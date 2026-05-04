# typed: false
require "test_helper"

class Internal::AgentRunnerControllerTest < ActionDispatch::IntegrationTest
  include ActionCable::TestHelper

  setup do
    @tenant, @collective, @user = create_tenant_collective_user
    @tenant.enable_feature_flag!("ai_agents")
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)

    @ai_agent = create_ai_agent
    @task_run = AiAgentTaskRun.create!(
      tenant: @tenant,
      ai_agent: @ai_agent,
      initiated_by: @user,
      task: "Test task",
      max_steps: 10,
      status: "queued",
    )

    # Save and override the secret for this test's HMAC signatures.
    # test_helper sets a default; we restore it in teardown so other tests
    # that dispatch via AgentRunnerDispatchService don't see an empty value.
    @previous_secret = ENV["AGENT_RUNNER_SECRET"]
    @secret = "test-secret-for-hmac"
    ENV["AGENT_RUNNER_SECRET"] = @secret

    # Clear thread scope — the controller resolves tenant from the request subdomain
    Tenant.clear_thread_scope
    Collective.clear_thread_scope

    # Set the host so request.subdomain resolves the correct tenant
    host! "#{@tenant.subdomain}.#{ENV.fetch("HOSTNAME", "harmonic.local")}"
  end

  teardown do
    if @previous_secret.nil?
      ENV.delete("AGENT_RUNNER_SECRET")
    else
      ENV["AGENT_RUNNER_SECRET"] = @previous_secret
    end
  end

  # --- HMAC Verification ---

  test "rejects request without HMAC signature" do
    post claim_url, params: {}.to_json, headers: { "Content-Type" => "application/json" }
    assert_response :unauthorized
  end

  test "rejects request with invalid HMAC signature" do
    post claim_url,
      params: {}.to_json,
      headers: signed_headers({}.to_json).merge("X-Internal-Signature" => "sha256=invalid")
    assert_response :unauthorized
  end

  test "rejects request with expired timestamp" do
    body = {}.to_json
    old_timestamp = (Time.current - 10.minutes).to_i.to_s
    nonce = SecureRandom.uuid
    signature = "sha256=" + OpenSSL::HMAC.hexdigest("sha256", @secret, "#{nonce}.#{old_timestamp}.#{body}")

    post claim_url,
      params: body,
      headers: {
        "Content-Type" => "application/json",
        "X-Internal-Signature" => signature,
        "X-Internal-Timestamp" => old_timestamp,
        "X-Internal-Nonce" => nonce,
      }
    assert_response :unauthorized
  end

  test "rejects replayed nonce within signature window" do
    body = { steps: [{ type: "navigate", detail: "/x", timestamp: Time.current.iso8601 }] }.to_json
    headers = signed_headers(body)

    # First request should succeed...
    post "/internal/agent-runner/tasks/#{@task_run.id}/step", params: body, headers: headers
    assert_response :ok

    # ...replay with the same nonce must not.
    post "/internal/agent-runner/tasks/#{@task_run.id}/step", params: body, headers: headers
    assert_response :unauthorized
    assert_match(/[Rr]eplay/, response.body)
  end

  # --- Claim ---

  test "claim transitions queued task to running" do
    post claim_url, params: {}.to_json, headers: signed_headers({}.to_json)
    assert_response :success

    @task_run.reload
    assert_equal "running", @task_run.status
    assert_not_nil @task_run.started_at
  end

  test "claim rejects already running task" do
    @task_run.update!(status: "running", started_at: Time.current)

    post claim_url, params: {}.to_json, headers: signed_headers({}.to_json)
    assert_response :conflict
  end

  # --- Step ---

  test "step creates agent_session_step rows" do
    @task_run.update!(status: "running", started_at: Time.current)

    body = {
      steps: [
        { type: "navigate", detail: { path: "/notifications" }, timestamp: Time.current.iso8601 },
      ],
    }.to_json

    post step_url, params: body, headers: signed_headers(body)
    assert_response :success

    @task_run.reload
    assert_equal 1, @task_run.steps_count
    assert_equal 1, @task_run.agent_session_steps.count
    step_row = @task_run.agent_session_steps.first
    assert_equal 0, step_row.position
    assert_equal "navigate", step_row.step_type
    assert_equal({ "path" => "/notifications" }, step_row.detail)
  end

  test "step assigns sequential positions across multiple calls" do
    @task_run.update!(status: "running", started_at: Time.current)

    # First step call
    body1 = {
      steps: [
        { type: "navigate", detail: { path: "/a" }, timestamp: Time.current.iso8601 },
      ],
    }.to_json
    post step_url, params: body1, headers: signed_headers(body1)
    assert_response :success

    # Second step call with two steps
    body2 = {
      steps: [
        { type: "think", detail: { step_number: 0 }, timestamp: Time.current.iso8601 },
        { type: "execute", detail: { action: "create_note" }, timestamp: Time.current.iso8601 },
      ],
    }.to_json
    post step_url, params: body2, headers: signed_headers(body2)
    assert_response :success

    @task_run.reload
    assert_equal 3, @task_run.agent_session_steps.count
    positions = @task_run.agent_session_steps.pluck(:position)
    assert_equal [0, 1, 2], positions
  end

  test "step creates ChatMessage for message type in chat mode" do
    cs = with_tenant_scope do
      ChatSession.find_or_create_between(user_a: @ai_agent, user_b: @user, tenant: @tenant)
    end
    @task_run.update!(status: "running", started_at: Time.current, mode: "chat_turn", chat_session: cs)

    body = {
      steps: [
        { type: "message", detail: { content: "Hello from agent" }, timestamp: Time.current.iso8601, sender_id: @ai_agent.id },
      ],
    }.to_json

    assert_difference "ChatMessage.count", 1 do
      post step_url, params: body, headers: signed_headers(body)
    end
    assert_response :success

    msg = ChatMessage.last
    assert_equal @ai_agent.id, msg.sender_id
    assert_equal "Hello from agent", msg.content
    assert_equal cs.id, msg.chat_session_id

    # Verify resource tracking
    resource_record = AiAgentTaskRunResource.tenant_scoped_only(@tenant.id)
      .find_by(resource_type: "ChatMessage", resource_id: msg.id)
    assert_not_nil resource_record, "Expected AiAgentTaskRunResource to be created for ChatMessage"
    assert_equal @task_run.id, resource_record.ai_agent_task_run_id
    assert_equal "message", resource_record.action_type
    assert_equal msg.collective_id, resource_record.resource_collective_id
  end

  test "step skips message type for non-chat task runs" do
    @task_run.update!(status: "running", started_at: Time.current)

    body = {
      steps: [
        { type: "message", detail: { content: "Hello from agent" }, timestamp: Time.current.iso8601, sender_id: @ai_agent.id },
      ],
    }.to_json

    assert_no_difference ["ChatMessage.count", "AgentSessionStep.count"] do
      post step_url, params: body, headers: signed_headers(body)
    end
    assert_response :success
  end

  test "step broadcasts message steps via ActionCable for chat sessions" do
    with_tenant_scope do
      cs = ChatSession.find_or_create_between(user_a: @ai_agent, user_b: @user, tenant: @tenant)
      @task_run.update!(
        status: "running", started_at: Time.current,
        mode: "chat_turn", chat_session: cs,
      )
      cs
    end

    body = {
      steps: [
        { type: "message", detail: { content: "Agent response" }, timestamp: Time.current.iso8601, sender_id: @ai_agent.id },
      ],
    }.to_json

    # ActionCable broadcast should not raise
    assert_nothing_raised do
      post step_url, params: body, headers: signed_headers(body)
    end
    assert_response :success
  end

  test "step handles empty message content gracefully" do
    cs = with_tenant_scope do
      ChatSession.find_or_create_between(user_a: @ai_agent, user_b: @user, tenant: @tenant)
    end
    @task_run.update!(status: "running", started_at: Time.current, mode: "chat_turn", chat_session: cs)

    body = {
      steps: [
        { type: "message", detail: {}, timestamp: Time.current.iso8601, sender_id: @ai_agent.id },
      ],
    }.to_json

    assert_difference "ChatMessage.count", 1 do
      post step_url, params: body, headers: signed_headers(body)
    end
    assert_response :success

    msg = ChatMessage.last
    assert_equal "(empty)", msg.content
  end

  test "step broadcasts ChatMessage with correct format via ActionCable" do
    cs = with_tenant_scope do
      ChatSession.find_or_create_between(user_a: @ai_agent, user_b: @user, tenant: @tenant)
    end
    @task_run.update!(status: "running", started_at: Time.current, mode: "chat_turn", chat_session: cs)

    body = {
      steps: [
        { type: "message", detail: { content: "Hello!" }, timestamp: Time.current.iso8601, sender_id: @ai_agent.id },
      ],
    }.to_json

    stream = ChatSessionChannel.broadcasting_for(cs)

    assert_broadcasts(stream, 1) do
      post step_url, params: body, headers: signed_headers(body)
    end
    assert_response :success

    # Verify the broadcast payload shape matches what the frontend expects
    msg = ChatMessage.last
    broadcast = ActiveSupport::JSON.decode(broadcasts(stream).last)
    assert_equal "message", broadcast["type"]
    assert_equal msg.id, broadcast["id"]
    assert_equal @ai_agent.id, broadcast["sender_id"]
    assert_equal "Hello!", broadcast["content"]
    assert_equal true, broadcast["is_agent"]
    assert_not_nil broadcast["timestamp"]
  end

  test "step with mixed batch creates contiguous positions for non-message steps" do
    cs = with_tenant_scope do
      ChatSession.find_or_create_between(user_a: @ai_agent, user_b: @user, tenant: @tenant)
    end
    @task_run.update!(status: "running", started_at: Time.current, mode: "chat_turn", chat_session: cs)

    body = {
      steps: [
        { type: "navigate", detail: { path: "/home" }, timestamp: Time.current.iso8601 },
        { type: "message", detail: { content: "Done!" }, timestamp: Time.current.iso8601, sender_id: @ai_agent.id },
        { type: "execute", detail: { action: "create_note", success: true }, timestamp: Time.current.iso8601 },
      ],
    }.to_json

    post step_url, params: body, headers: signed_headers(body)
    assert_response :success

    # 2 AgentSessionSteps (navigate + execute), 1 ChatMessage
    assert_equal 2, @task_run.agent_session_steps.count
    assert_equal 1, ChatMessage.where(chat_session: cs).count

    # Positions should be contiguous (0, 1) with no gap from the skipped message
    positions = @task_run.agent_session_steps.order(:position).pluck(:position)
    assert_equal [0, 1], positions
  end

  test "step does not broadcast non-message steps" do
    with_tenant_scope do
      cs = ChatSession.find_or_create_between(user_a: @ai_agent, user_b: @user, tenant: @tenant)
      @task_run.update!(
        status: "running", started_at: Time.current,
        mode: "chat_turn", chat_session: cs,
      )
    end

    body = {
      steps: [
        { type: "navigate", detail: { path: "/home" }, timestamp: Time.current.iso8601 },
      ],
    }.to_json

    # Should succeed without broadcasting
    post step_url, params: body, headers: signed_headers(body)
    assert_response :success
  end

  # --- Complete ---

  test "complete marks task as completed with token counts" do
    @task_run.update!(status: "running", started_at: Time.current)

    token = ApiToken.create_internal_token(
      user: @ai_agent,
      tenant: @tenant,
      context: @task_run,
    )

    body = {
      success: true,
      final_message: "Done",
      input_tokens: 500,
      output_tokens: 200,
      total_tokens: 700,
    }.to_json

    post complete_url, params: body, headers: signed_headers(body)
    assert_response :success

    @task_run.reload
    assert_equal "completed", @task_run.status
    assert @task_run.success
    assert_equal "Done", @task_run.final_message
    assert_equal 500, @task_run.input_tokens
    assert_equal 200, @task_run.output_tokens
    assert_equal 700, @task_run.total_tokens
    assert_not_nil @task_run.completed_at

    # Token should be destroyed
    assert_nil ApiToken.unscope(where: :internal).find_by(id: token.id)
  end

  # --- Fail ---

  test "fail marks task as failed" do
    @task_run.update!(status: "running", started_at: Time.current)

    body = { error: "Something went wrong" }.to_json
    post fail_url, params: body, headers: signed_headers(body)
    assert_response :success

    @task_run.reload
    assert_equal "failed", @task_run.status
    assert_not @task_run.success
    assert_equal "Something went wrong", @task_run.error
  end

  # --- Scratchpad ---

  test "scratchpad updates agent configuration" do
    @task_run.update!(status: "running", started_at: Time.current)

    body = { scratchpad: "Remember: user prefers bullet points" }.to_json
    put scratchpad_url, params: body, headers: signed_headers(body)
    assert_response :success

    @ai_agent.reload
    assert_equal "Remember: user prefers bullet points", @ai_agent.agent_configuration["scratchpad"]
  end

  test "scratchpad sanitizes control characters and truncates" do
    @task_run.update!(status: "running", started_at: Time.current)

    content = "Clean text\x00\x01 with control chars"
    body = { scratchpad: content }.to_json
    put scratchpad_url, params: body, headers: signed_headers(body)
    assert_response :success

    @ai_agent.reload
    assert_equal "Clean text with control chars", @ai_agent.agent_configuration["scratchpad"]
  end

  # --- Status ---

  test "status returns current task status" do
    get status_url, headers: signed_headers("")
    assert_response :success
    assert_equal "queued", response.parsed_body["status"]
  end

  # --- Preflight ---

  test "preflight returns ok for active agent with billing" do
    body = {}.to_json
    post preflight_url, params: body, headers: signed_headers(body)
    assert_response :success
    assert_equal "ok", response.parsed_body["status"]
  end

  test "preflight fails for suspended agent" do
    @ai_agent.update!(suspended_at: Time.current)

    body = {}.to_json
    post preflight_url, params: body, headers: signed_headers(body)
    assert_response :success
    assert_equal "fail", response.parsed_body["status"]
    assert_includes response.parsed_body["reason"], "suspended"
  end

  # --- Tenant isolation ---

  test "request with a different tenant subdomain cannot access this task run" do
    other_tenant = create_tenant(subdomain: "other-tenant", name: "Other Tenant")
    url = claim_url
    host! "#{other_tenant.subdomain}.#{ENV.fetch("HOSTNAME", "harmonic.local")}"

    post url, params: {}.to_json, headers: signed_headers({}.to_json)
    assert_response :not_found

    @task_run.reload
    assert_equal "queued", @task_run.status
    assert_nil @task_run.started_at
  end

  test "request with unknown subdomain returns 404" do
    host! "nonexistent.#{ENV.fetch("HOSTNAME", "harmonic.local")}"

    post claim_url, params: {}.to_json, headers: signed_headers({}.to_json)
    assert_response :not_found
  end

  test "request with missing subdomain returns 400" do
    host! ENV.fetch("HOSTNAME", "harmonic.local")

    post claim_url, params: {}.to_json, headers: signed_headers({}.to_json)
    assert_response :bad_request
  end

  # --- Chat History ---

  test "chat_history returns messages for a chat session" do
    chat_session = with_tenant_scope do
      ChatSession.find_or_create_between(user_a: @ai_agent, user_b: @user, tenant: @tenant)
    end

    with_chat_scope(chat_session) do
      run1 = AiAgentTaskRun.create!(
        tenant: @tenant, ai_agent: @ai_agent, initiated_by: @user,
        task: "Hello", max_steps: 30, status: "completed",
        mode: "chat_turn", chat_session: chat_session,
      )
      chat_session.chat_messages.create!(sender: @user, content: "Hello", created_at: 3.minutes.ago)
      run1.agent_session_steps.create!(position: 0, step_type: "navigate", detail: { path: "/home" }, created_at: 2.minutes.ago)
      chat_session.chat_messages.create!(sender: @ai_agent, content: "Hi there!", created_at: 1.minute.ago)

      chat_session.chat_messages.create!(sender: @user, content: "What's new?", created_at: Time.current)
    end

    get chat_history_url(chat_session.id), headers: signed_headers("")
    assert_response :success

    body = response.parsed_body
    messages = body["messages"]
    # 4 entries: human message, action summary (navigate), agent message, human message
    assert_equal 4, messages.length
    assert_equal "Hello", messages[0]["content"]
    assert_equal "user", messages[0]["role"]
    assert_equal "system", messages[1]["role"] # action summary for navigate
    assert_includes messages[1]["content"], "navigated to /home"
    assert_equal "Hi there!", messages[2]["content"]
    assert_equal "assistant", messages[2]["role"]
    assert_equal "What's new?", messages[3]["content"]
    assert_equal "user", messages[3]["role"]
  end

  test "chat_history includes action summaries between messages" do
    chat_session = with_tenant_scope do
      ChatSession.find_or_create_between(user_a: @ai_agent, user_b: @user, tenant: @tenant)
    end

    with_chat_scope(chat_session) do
      run = AiAgentTaskRun.create!(
        tenant: @tenant, ai_agent: @ai_agent, initiated_by: @user,
        task: "Do stuff", max_steps: 30, status: "completed",
        mode: "chat_turn", chat_session: chat_session,
      )
      chat_session.chat_messages.create!(sender: @user, content: "Do stuff", created_at: 5.minutes.ago)
      run.agent_session_steps.create!(position: 0, step_type: "navigate", detail: { path: "/collectives/team" }, created_at: 4.minutes.ago)
      run.agent_session_steps.create!(position: 1, step_type: "execute", detail: { action: "create_note", success: true }, created_at: 3.minutes.ago)
      run.agent_session_steps.create!(position: 2, step_type: "navigate", detail: { path: "/collectives/team/n/abc" }, created_at: 2.minutes.ago)
      chat_session.chat_messages.create!(sender: @ai_agent, content: "Done! Created a note.", created_at: 1.minute.ago)
    end

    get chat_history_url(chat_session.id), headers: signed_headers("")
    assert_response :success

    messages = response.parsed_body["messages"]
    assert_equal 3, messages.length

    # Human message
    assert_equal "user", messages[0]["role"]
    # Action summary (2 navigates + 1 execute collapsed)
    assert_equal "system", messages[1]["role"]
    assert_includes messages[1]["content"], "navigated to /collectives/team"
    assert_includes messages[1]["content"], "create_note (success)"
    assert_includes messages[1]["content"], "navigated to /collectives/team/n/abc"
    # Agent message
    assert_equal "assistant", messages[2]["role"]
  end

  test "chat_history flushes trailing action buffer" do
    chat_session = with_tenant_scope do
      ChatSession.find_or_create_between(user_a: @ai_agent, user_b: @user, tenant: @tenant)
    end

    with_chat_scope(chat_session) do
      run = AiAgentTaskRun.create!(
        tenant: @tenant, ai_agent: @ai_agent, initiated_by: @user,
        task: "Navigate", max_steps: 30, status: "failed",
        mode: "chat_turn", chat_session: chat_session,
      )
      chat_session.chat_messages.create!(sender: @user, content: "Navigate somewhere", created_at: 2.minutes.ago)
      run.agent_session_steps.create!(position: 0, step_type: "navigate", detail: { path: "/collectives/team" }, created_at: 1.minute.ago)
      # No agent message — task failed mid-navigation
    end

    get chat_history_url(chat_session.id), headers: signed_headers("")
    assert_response :success

    messages = response.parsed_body["messages"]
    assert_equal 2, messages.length
    assert_equal "user", messages[0]["role"]
    assert_equal "system", messages[1]["role"]
    assert_includes messages[1]["content"], "navigated to /collectives/team"
  end

  test "chat_history returns 404 for nonexistent session" do
    get chat_history_url("nonexistent"), headers: signed_headers("")
    assert_response :not_found
  end

  # --- Chat turn completion auto-dispatch ---

  test "complete auto-dispatches next turn when queued human messages exist" do
    chat_session = with_tenant_scope do
      ChatSession.find_or_create_between(user_a: @ai_agent, user_b: @user, tenant: @tenant)
    end

    with_chat_scope(chat_session) do
      @task_run.update!(
        status: "running", started_at: Time.current,
        mode: "chat_turn", chat_session: chat_session,
      )
      # Agent's response
      chat_session.chat_messages.create!(sender: @ai_agent, content: "Here's what I found", created_at: 2.minutes.ago)
      # Human sent a follow-up while the turn was running
      chat_session.chat_messages.create!(sender: @user, content: "Also check the decisions", created_at: 1.minute.ago)
    end

    body = {
      success: true,
      final_message: "Done",
      input_tokens: 100,
      output_tokens: 50,
      total_tokens: 150,
    }.to_json

    assert_difference "AiAgentTaskRun.count", 1 do
      post complete_url, params: body, headers: signed_headers(body)
    end
    assert_response :success

    new_run = AiAgentTaskRun.order(created_at: :desc).first
    assert_equal "chat_turn", new_run.mode
    assert_equal chat_session.id, new_run.chat_session_id
    assert_equal "Also check the decisions", new_run.task
  end

  test "complete saves current_state for chat_turn tasks" do
    chat_session = with_tenant_scope do
      cs = ChatSession.find_or_create_between(user_a: @ai_agent, user_b: @user, tenant: @tenant)
      @task_run.update!(
        status: "running", started_at: Time.current,
        mode: "chat_turn", chat_session: cs,
      )
      cs
    end

    body = {
      success: true,
      final_message: "Done",
      input_tokens: 100,
      output_tokens: 50,
      total_tokens: 150,
      current_state: { current_path: "/collectives/chariot/n/abc123" },
    }.to_json

    post complete_url, params: body, headers: signed_headers(body)
    assert_response :success

    chat_session.reload
    assert_equal "/collectives/chariot/n/abc123", chat_session.current_state["current_path"]
  end

  test "complete does not save current_state for regular task mode" do
    @task_run.update!(status: "running", started_at: Time.current, mode: "task")

    body = {
      success: true,
      final_message: "Done",
      input_tokens: 100,
      output_tokens: 50,
      total_tokens: 150,
      current_state: { current_path: "/somewhere" },
    }.to_json

    post complete_url, params: body, headers: signed_headers(body)
    assert_response :success
    # No chat session to update
  end

  test "chat_history returns current_state" do
    chat_session = with_tenant_scope do
      ChatSession.find_or_create_between(user_a: @ai_agent, user_b: @user, tenant: @tenant)
    end

    with_chat_scope(chat_session) do
      chat_session.update!(current_state: { "current_path" => "/collectives/chariot" })
      AiAgentTaskRun.create!(
        tenant: @tenant, ai_agent: @ai_agent, initiated_by: @user,
        task: "Hello", max_steps: 30, status: "completed",
        mode: "chat_turn", chat_session: chat_session,
      )
      chat_session.chat_messages.create!(sender: @user, content: "Hello")
    end

    get chat_history_url(chat_session.id), headers: signed_headers("")
    assert_response :success

    body = response.parsed_body
    assert_equal "/collectives/chariot", body["current_state"]["current_path"]
  end

  test "complete does not auto-dispatch for regular task mode" do
    @task_run.update!(status: "running", started_at: Time.current, mode: "task")

    body = {
      success: true, final_message: "Done",
      input_tokens: 100, output_tokens: 50, total_tokens: 150,
    }.to_json

    assert_no_difference "AiAgentTaskRun.count" do
      post complete_url, params: body, headers: signed_headers(body)
    end
  end

  # --- Chat status broadcasts ---

  test "claim broadcasts working status for chat_turn tasks" do
    chat_session = with_tenant_scope do
      cs = ChatSession.find_or_create_between(user_a: @ai_agent, user_b: @user, tenant: @tenant)
      @task_run.update!(mode: "chat_turn", chat_session: cs)
      cs
    end

    stream = ChatSessionChannel.broadcasting_for(chat_session)

    assert_broadcasts(stream, 1) do
      post claim_url, params: {}.to_json, headers: signed_headers({}.to_json)
    end
    assert_response :success
  end

  test "claim does not broadcast for regular task mode" do
    post claim_url, params: {}.to_json, headers: signed_headers({}.to_json)
    assert_response :success
    # No error = no broadcast attempted for non-chat task
  end

  test "step does not broadcast activity during setup (before first think step)" do
    chat_session = with_tenant_scope do
      cs = ChatSession.find_or_create_between(user_a: @ai_agent, user_b: @user, tenant: @tenant)
      @task_run.update!(
        status: "running", started_at: Time.current,
        mode: "chat_turn", chat_session: cs,
      )
      cs
    end

    body = {
      steps: [
        { type: "navigate", detail: { path: "/whoami" }, timestamp: Time.current.iso8601 },
      ],
    }.to_json

    stream = ChatSessionChannel.broadcasting_for(chat_session)

    assert_broadcasts(stream, 0) do
      post step_url, params: body, headers: signed_headers(body)
    end
    assert_response :success
  end

  test "step broadcasts activity for navigate steps after setup" do
    chat_session = with_tenant_scope do
      cs = ChatSession.find_or_create_between(user_a: @ai_agent, user_b: @user, tenant: @tenant)
      @task_run.update!(
        status: "running", started_at: Time.current,
        mode: "chat_turn", chat_session: cs,
      )
      # Simulate setup already complete (think step exists)
      @task_run.agent_session_steps.create!(position: 0, step_type: "navigate", detail: { path: "/whoami" })
      @task_run.agent_session_steps.create!(position: 1, step_type: "think", detail: { step_number: 0 })
      cs
    end

    body = {
      steps: [
        { type: "navigate", detail: { path: "/collectives/team" }, timestamp: Time.current.iso8601 },
      ],
    }.to_json

    stream = ChatSessionChannel.broadcasting_for(chat_session)

    assert_broadcasts(stream, 1) do
      post step_url, params: body, headers: signed_headers(body)
    end
    assert_response :success
  end

  test "step broadcasts activity for execute steps after setup" do
    chat_session = with_tenant_scope do
      cs = ChatSession.find_or_create_between(user_a: @ai_agent, user_b: @user, tenant: @tenant)
      @task_run.update!(
        status: "running", started_at: Time.current,
        mode: "chat_turn", chat_session: cs,
      )
      @task_run.agent_session_steps.create!(position: 0, step_type: "think", detail: { step_number: 0 })
      cs
    end

    body = {
      steps: [
        { type: "execute", detail: { action: "create_note", success: true }, timestamp: Time.current.iso8601 },
      ],
    }.to_json

    stream = ChatSessionChannel.broadcasting_for(chat_session)

    assert_broadcasts(stream, 1) do
      post step_url, params: body, headers: signed_headers(body)
    end
    assert_response :success
  end

  test "complete broadcasts completed status for chat_turn tasks" do
    chat_session = with_tenant_scope do
      cs = ChatSession.find_or_create_between(user_a: @ai_agent, user_b: @user, tenant: @tenant)
      @task_run.update!(
        status: "running", started_at: Time.current,
        mode: "chat_turn", chat_session: cs,
      )
      cs
    end

    body = {
      success: true, final_message: "Done",
      input_tokens: 100, output_tokens: 50, total_tokens: 150,
    }.to_json

    stream = ChatSessionChannel.broadcasting_for(chat_session)

    assert_broadcasts(stream, 1) do
      post complete_url, params: body, headers: signed_headers(body)
    end
    assert_response :success
  end

  test "complete broadcasts error status when task failed for chat_turn" do
    chat_session = with_tenant_scope do
      cs = ChatSession.find_or_create_between(user_a: @ai_agent, user_b: @user, tenant: @tenant)
      @task_run.update!(
        status: "running", started_at: Time.current,
        mode: "chat_turn", chat_session: cs,
      )
      cs
    end

    body = {
      success: false, error: "LLM API error",
      input_tokens: 100, output_tokens: 0, total_tokens: 100,
    }.to_json

    stream = ChatSessionChannel.broadcasting_for(chat_session)

    assert_broadcasts(stream, 1) do
      post complete_url, params: body, headers: signed_headers(body)
    end
    assert_response :success
  end

  test "fail_task broadcasts error status for chat_turn tasks" do
    chat_session = with_tenant_scope do
      cs = ChatSession.find_or_create_between(user_a: @ai_agent, user_b: @user, tenant: @tenant)
      @task_run.update!(
        status: "running", started_at: Time.current,
        mode: "chat_turn", chat_session: cs,
      )
      cs
    end

    body = { error: "Agent crashed" }.to_json

    stream = ChatSessionChannel.broadcasting_for(chat_session)

    assert_broadcasts(stream, 1) do
      post fail_url, params: body, headers: signed_headers(body)
    end
    assert_response :success
  end

  test "fail_task broadcasts error for queued chat_turn (preflight failure)" do
    chat_session = with_tenant_scope do
      cs = ChatSession.find_or_create_between(user_a: @ai_agent, user_b: @user, tenant: @tenant)
      @task_run.update!(
        status: "queued",
        mode: "chat_turn", chat_session: cs,
      )
      cs
    end

    body = { error: "Billing is not set up" }.to_json

    stream = ChatSessionChannel.broadcasting_for(chat_session)

    assert_broadcast_on(stream, {
      "type" => "status",
      "status" => "error",
      "error" => "Billing is not set up",
      "task_run_id" => @task_run.id,
    }) do
      post fail_url, params: body, headers: signed_headers(body)
    end
    assert_response :success

    @task_run.reload
    assert_equal "failed", @task_run.status
    assert_equal "Billing is not set up", @task_run.error
  end

  test "complete does not auto-dispatch when no queued human messages" do
    chat_session = with_tenant_scope do
      ChatSession.find_or_create_between(user_a: @ai_agent, user_b: @user, tenant: @tenant)
    end

    with_chat_scope(chat_session) do
      @task_run.update!(
        status: "running", started_at: Time.current,
        mode: "chat_turn", chat_session: chat_session,
      )
      chat_session.chat_messages.create!(sender: @ai_agent, content: "Done")
    end

    body = {
      success: true,
      final_message: "Done",
      input_tokens: 100,
      output_tokens: 50,
      total_tokens: 150,
    }.to_json

    assert_no_difference "AiAgentTaskRun.count" do
      post complete_url, params: body, headers: signed_headers(body)
    end
  end

  private

  def claim_url
    "/internal/agent-runner/tasks/#{@task_run.id}/claim"
  end

  def step_url
    "/internal/agent-runner/tasks/#{@task_run.id}/step"
  end

  def complete_url
    "/internal/agent-runner/tasks/#{@task_run.id}/complete"
  end

  def fail_url
    "/internal/agent-runner/tasks/#{@task_run.id}/fail"
  end

  def scratchpad_url
    "/internal/agent-runner/tasks/#{@task_run.id}/scratchpad"
  end

  def chat_history_url(chat_session_id)
    "/internal/agent-runner/chat/#{chat_session_id}/history"
  end

  def with_tenant_scope
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    yield
  ensure
    Tenant.clear_thread_scope
    Collective.clear_thread_scope
  end

  def with_chat_scope(session)
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.set_thread_context(session.collective)
    yield
  ensure
    Tenant.clear_thread_scope
    Collective.clear_thread_scope
  end

  def status_url
    "/internal/agent-runner/tasks/#{@task_run.id}/status"
  end

  def preflight_url
    "/internal/agent-runner/tasks/#{@task_run.id}/preflight"
  end

  def signed_headers(body)
    timestamp = Time.current.to_i.to_s
    nonce = SecureRandom.uuid
    signature = "sha256=" + OpenSSL::HMAC.hexdigest("sha256", @secret, "#{nonce}.#{timestamp}.#{body}")
    {
      "Content-Type" => "application/json",
      "X-Internal-Signature" => signature,
      "X-Internal-Timestamp" => timestamp,
      "X-Internal-Nonce" => nonce,
    }
  end

  def create_ai_agent
    ai_agent = User.create!(
      name: "Test Agent",
      email: "test-agent-#{SecureRandom.hex(4)}@not-real.com",
      user_type: "ai_agent",
      parent_id: @user.id,
    )
    tu = @tenant.add_user!(ai_agent)
    ai_agent.tenant_user = tu
    CollectiveMember.create!(collective: @collective, user: ai_agent)
    ai_agent
  end
end
