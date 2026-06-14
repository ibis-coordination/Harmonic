require "test_helper"

# `mcp_only` restricts an agent token to /mcp; direct REST/markdown returns 403.
# This makes "every action lands in McpToolCallLog" structural rather than
# honor-system.
class ApiTokenMcpOnlyTest < ActionDispatch::IntegrationTest
  def setup
    @tenant = @global_tenant
    @tenant.enable_api!
    @collective = @global_collective
    @collective.enable_api!
    @parent = @global_user
    @tenant.enable_feature_flag!("internal_ai_agents")
    @tenant.enable_feature_flag!("external_ai_agents")

    @ai_agent = create_ai_agent(parent: @parent, name: "Mcp-Only Test Agent",
                                agent_configuration: { "mode" => "external" })
    @tenant.add_user!(@ai_agent)
    @collective.add_user!(@ai_agent)

    host! "#{@tenant.subdomain}.#{ENV.fetch("HOSTNAME", nil)}"
  end

  def make_token(user:, mcp_only:)
    ApiToken.create!(
      user: user,
      tenant: @tenant,
      name: "Token",
      scopes: ApiToken.read_scopes + ApiToken.write_scopes,
      expires_at: 1.year.from_now,
      mcp_only: mcp_only,
    )
  end

  def auth_headers(token)
    { "Authorization" => "Bearer #{token.plaintext_token}", "Accept" => "text/markdown" }
  end

  test "mcp_only agent token cannot POST directly" do
    token = make_token(user: @ai_agent, mcp_only: true)

    assert_no_difference -> { Note.count } do
      post "/collectives/#{@collective.handle}/actions/create_note",
           params: { title: "Should not exist", text: "blocked" }.to_json,
           headers: auth_headers(token).merge("Content-Type" => "application/json")
    end

    assert_response :forbidden
    body = response.parsed_body
    assert_match(%r{/help/mcp}, body["error"].to_s + body["message"].to_s)
  end

  test "mcp_only agent token cannot GET directly" do
    token = make_token(user: @ai_agent, mcp_only: true)

    get "/whoami", headers: auth_headers(token)

    assert_response :forbidden
  end

  test "expired mcp_only agent token does not cause a double-render crash" do
    # Pins the api_authorize! short-circuit when current_token already rendered.
    token = make_token(user: @ai_agent, mcp_only: true)
    token.update_columns(expires_at: 1.hour.ago)

    get "/whoami", headers: auth_headers(token)

    assert_includes [401, 403], response.status
  end

  test "non-mcp_only agent token CAN call directly" do
    token = make_token(user: @ai_agent, mcp_only: false)

    get "/whoami", headers: auth_headers(token)
    assert_response :success
  end

  test "human tokens cannot be created with mcp_only=true" do
    token = ApiToken.new(
      user: @parent, tenant: @tenant, name: "Token",
      scopes: ApiToken.read_scopes, expires_at: 1.year.from_now,
      mcp_only: true,
    )
    refute token.valid?
    assert_includes token.errors[:mcp_only], "can only be set on AI agent tokens"
  end

  test "human tokens with mcp_only=false work via direct calls" do
    human_token = make_token(user: @parent, mcp_only: false)

    get "/whoami", headers: auth_headers(human_token)
    assert_response :success
  end

  test "mcp_only agent token CAN make calls through /mcp" do
    token = make_token(user: @ai_agent, mcp_only: true)

    post "/mcp",
         params: {
           jsonrpc: "2.0", id: 1, method: "tools/call",
           params: { name: "fetch_page", arguments: { path: "/whoami" } },
         }.to_json,
         headers: {
           "Authorization" => "Bearer #{token.plaintext_token}",
           "Content-Type" => "application/json",
           "Accept" => "application/json",
           "MCP-Protocol-Version" => "2025-11-25",
         }

    assert_response :success
    body = response.parsed_body
    refute body["result"]["isError"], "expected success, got: #{body.inspect}"
  end

  test "error response body is JSON-shaped and references /help/mcp" do
    token = make_token(user: @ai_agent, mcp_only: true)

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
  # Defaults at token-creation paths
  # ====================

  test "ApiToken.create_internal_token defaults mcp_only=false" do
    # Agent runner uses these tokens for direct HTTPS calls, not via /mcp.
    task_run = AiAgentTaskRun.create!(
      tenant: @tenant,
      ai_agent: @ai_agent,
      initiated_by: @parent,
      task: "test",
    )
    token = ApiToken.create_internal_token(user: @ai_agent, tenant: @tenant, context: task_run)
    refute token.mcp_only?
  end

  test "human tokens default mcp_only=false" do
    token = ApiToken.create!(
      name: "human token",
      user: @parent,
      tenant: @tenant,
      expires_at: 1.year.from_now,
      scopes: ApiToken.read_scopes,
    )
    refute token.mcp_only?
  end

  test "tokens default mcp_only=false when the kwarg is omitted" do
    token = ApiToken.create!(
      name: "legacy-style token",
      user: @ai_agent,
      tenant: @tenant,
      expires_at: 1.year.from_now,
      scopes: ApiToken.read_scopes,
    )
    refute token.mcp_only?
  end
end
