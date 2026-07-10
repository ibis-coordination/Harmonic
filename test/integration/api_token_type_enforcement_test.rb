require "test_helper"

# Every ApiToken has exactly one type, and each surface accepts exactly its
# own: rest → REST/markdown, mcp → /mcp, llm_gateway → the LLM gateway.
# For mcp tokens this makes "every action lands in McpToolCallLog" structural
# rather than honor-system; for llm_gateway tokens it makes "spend credential
# has zero data access" structural.
class ApiTokenTypeEnforcementTest < ActionDispatch::IntegrationTest
  def setup
    @tenant = @global_tenant
    @tenant.enable_api!
    @collective = @global_collective
    @collective.enable_api!
    @parent = @global_user
    @tenant.enable_feature_flag!("internal_ai_agents")
    @tenant.enable_feature_flag!("external_ai_agents")

    @ai_agent = create_ai_agent(parent: @parent, name: "Token Type Test Agent",
                                agent_configuration: { "mode" => "external" })
    @tenant.add_user!(@ai_agent)
    @collective.add_user!(@ai_agent)

    host! "#{@tenant.subdomain}.#{ENV.fetch("HOSTNAME", nil)}"
  end

  def make_token(user:, token_type:)
    ApiToken.create!(
      user: user,
      tenant: @tenant,
      name: "Token",
      scopes: ApiToken.read_scopes + ApiToken.write_scopes,
      expires_at: 1.year.from_now,
      token_type: token_type,
    )
  end

  def auth_headers(token)
    { "Authorization" => "Bearer #{token.plaintext_token}", "Accept" => "text/markdown" }
  end

  def mcp_call(token, path: "/whoami")
    post "/mcp",
         params: {
           jsonrpc: "2.0", id: 1, method: "tools/call",
           params: { name: "fetch_page", arguments: { path: path } },
         }.to_json,
         headers: {
           "Authorization" => "Bearer #{token.plaintext_token}",
           "Content-Type" => "application/json",
           "Accept" => "application/json",
           "MCP-Protocol-Version" => "2025-11-25",
         }
  end

  # ====================
  # REST/markdown surface: rest tokens only
  # ====================

  test "mcp agent token cannot POST directly" do
    token = make_token(user: @ai_agent, token_type: "mcp")

    assert_no_difference -> { Note.count } do
      post "/collectives/#{@collective.handle}/actions/create_note",
           params: { title: "Should not exist", text: "blocked" }.to_json,
           headers: auth_headers(token).merge("Content-Type" => "application/json")
    end

    assert_response :forbidden
    body = response.parsed_body
    assert_match(%r{/help/mcp}, body["error"].to_s + body["message"].to_s)
  end

  test "mcp agent token cannot GET directly" do
    token = make_token(user: @ai_agent, token_type: "mcp")

    get "/whoami", headers: auth_headers(token)

    assert_response :forbidden
  end

  test "llm_gateway agent token cannot reach REST/markdown" do
    token = make_token(user: @ai_agent, token_type: "llm_gateway")

    get "/whoami", headers: auth_headers(token)

    assert_response :forbidden
    assert_equal "llm_gateway_only", response.parsed_body["error"]
  end

  test "expired mcp agent token does not cause a double-render crash" do
    # Pins the api_authorize! short-circuit when current_token already rendered.
    token = make_token(user: @ai_agent, token_type: "mcp")
    token.update_columns(expires_at: 1.hour.ago)

    get "/whoami", headers: auth_headers(token)

    assert_includes [401, 403], response.status
  end

  test "rest agent token CAN call directly" do
    token = make_token(user: @ai_agent, token_type: "rest")

    get "/whoami", headers: auth_headers(token)
    assert_response :success
  end

  test "human rest tokens work via direct calls" do
    human_token = make_token(user: @parent, token_type: "rest")

    get "/whoami", headers: auth_headers(human_token)
    assert_response :success
  end

  test "error response body is JSON-shaped and references /help/mcp" do
    token = make_token(user: @ai_agent, token_type: "mcp")

    get "/whoami", headers: auth_headers(token)

    assert_response :forbidden
    body = response.parsed_body
    # The message must reference /help/mcp so the agent harness gets a
    # useful migration prompt the first time it hits this 403.
    full_message = "#{body["error"]} #{body["message"]}"
    assert_match(%r{/help/mcp}, full_message)
    assert_match(/MCP/, full_message)
  end

  # ====================
  # /mcp surface: mcp tokens only
  # ====================

  test "mcp agent token CAN make calls through /mcp" do
    token = make_token(user: @ai_agent, token_type: "mcp")

    mcp_call(token)

    assert_response :success
    body = response.parsed_body
    assert_not body["result"]["isError"], "expected success, got: #{body.inspect}"
  end

  test "rest agent token cannot use /mcp" do
    token = make_token(user: @ai_agent, token_type: "rest")

    mcp_call(token)

    assert_response :unauthorized
  end

  test "llm_gateway agent token cannot use /mcp" do
    token = make_token(user: @ai_agent, token_type: "llm_gateway")

    mcp_call(token)

    assert_response :unauthorized
  end

  # ====================
  # Type constraints at creation
  # ====================

  test "human tokens cannot be created with agent-only types" do
    ["mcp", "llm_gateway"].each do |type|
      token = ApiToken.new(
        user: @parent, tenant: @tenant, name: "Token",
        scopes: ApiToken.read_scopes, expires_at: 1.year.from_now,
        token_type: type,
      )
      assert_not token.valid?, "#{type} token on a human must be invalid"
      assert_includes token.errors[:token_type], "#{type} tokens can only belong to AI agents"
    end
  end

  # ====================
  # Defaults at token-creation paths
  # ====================

  test "ApiToken.create_internal_token defaults to the rest type" do
    # The default is conservative; the security boundary is enforced at the
    # call site. AgentRunnerDispatchService passes token_type: "mcp" explicitly
    # because its tokens flow through /mcp via the runner's McpClient;
    # MarkdownUiService's automation path omits the kwarg because automations
    # dispatch against direct action endpoints.
    task_run = AiAgentTaskRun.create!(
      tenant: @tenant,
      ai_agent: @ai_agent,
      initiated_by: @parent,
      task: "test",
    )
    token = ApiToken.create_internal_token(user: @ai_agent, tenant: @tenant, context: task_run)
    assert token.rest_type?
  end

  test "ApiToken.create_internal_token accepts token_type: mcp opt-in" do
    task_run = AiAgentTaskRun.create!(
      tenant: @tenant,
      ai_agent: @ai_agent,
      initiated_by: @parent,
      task: "test",
    )
    token = ApiToken.create_internal_token(
      user: @ai_agent, tenant: @tenant, context: task_run, token_type: "mcp",
    )
    assert token.mcp_type?
  end

  test "tokens default to the rest type when token_type is omitted" do
    token = ApiToken.create!(
      name: "legacy-style token",
      user: @ai_agent,
      tenant: @tenant,
      expires_at: 1.year.from_now,
      scopes: ApiToken.read_scopes,
    )
    assert token.rest_type?
  end
end
