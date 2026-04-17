# typed: false
require "test_helper"

class Internal::AgentRunnerControllerTest < ActionDispatch::IntegrationTest
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

  test "step appends to steps_data" do
    @task_run.update!(status: "running", started_at: Time.current, steps_data: [])

    body = {
      steps: [
        { type: "navigate", detail: "/notifications", timestamp: Time.current.iso8601 },
      ],
    }.to_json

    post step_url, params: body, headers: signed_headers(body)
    assert_response :success

    @task_run.reload
    assert_equal 1, @task_run.steps_count
    assert_equal 1, @task_run.steps_data.length
    assert_equal "navigate", @task_run.steps_data.first["type"]
  end

  # --- Complete ---

  test "complete marks task as completed with token counts" do
    @task_run.update!(status: "running", started_at: Time.current)

    token = ApiToken.create_internal_token(
      user: @ai_agent,
      tenant: @tenant,
      ai_agent_task_run: @task_run,
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
