require "test_helper"

# Tests for the MCP (Model Context Protocol) endpoint at POST /mcp.
#
# Covers the Streamable HTTP transport from spec revision 2025-11-25:
# https://modelcontextprotocol.io/specification/2025-11-25/basic/transports
#
# Exercises the JSON-RPC envelope (initialize, tools/list, tools/call,
# notifications), Bearer auth, Origin header policy, MCP-Protocol-Version
# header policy, and the fetch_page tool.
class Mcp::EndpointControllerTest < ActionDispatch::IntegrationTest # rubocop:disable Style/ClassAndModuleChildren
  SUPPORTED_PROTOCOL_VERSION = "2025-11-25".freeze

  def setup
    @tenant = @global_tenant
    @tenant.enable_api!
    @collective = @global_collective
    @collective.enable_api!
    @user = @global_user
    @api_token = ApiToken.create!(
      tenant: @tenant,
      user: @user,
      scopes: ApiToken.valid_scopes
    )
    @plaintext_token = @api_token.plaintext_token
    host! "#{@tenant.subdomain}.#{ENV.fetch("HOSTNAME", nil)}"
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
  end

  def auth_headers(token: @plaintext_token, origin: nil, protocol_version: SUPPORTED_PROTOCOL_VERSION)
    headers = {
      "Authorization" => "Bearer #{token}",
      "Content-Type" => "application/json",
      "Accept" => "application/json, text/event-stream",
    }
    headers["Origin"] = origin if origin
    headers["MCP-Protocol-Version"] = protocol_version if protocol_version
    headers
  end

  def post_jsonrpc(body, headers: auth_headers)
    post "/mcp", params: body.to_json, headers: headers
  end

  # ====================
  # Auth
  # ====================

  test "POST /mcp without Authorization returns 401 with WWW-Authenticate" do
    post "/mcp",
         params: { jsonrpc: "2.0", id: 1, method: "initialize", params: {} }.to_json,
         headers: { "Content-Type" => "application/json", "MCP-Protocol-Version" => SUPPORTED_PROTOCOL_VERSION }

    assert_response :unauthorized
    assert_match(/Bearer/, response.headers["WWW-Authenticate"].to_s)
    assert_match(/resource_metadata=/, response.headers["WWW-Authenticate"].to_s)
  end

  test "POST /mcp with invalid Bearer returns 401" do
    post_jsonrpc(
      { jsonrpc: "2.0", id: 1, method: "initialize", params: {} },
      headers: auth_headers(token: "not-a-real-token")
    )

    assert_response :unauthorized
  end

  # ====================
  # Origin header policy
  # ====================

  test "POST /mcp with missing Origin is allowed (desktop client)" do
    post_jsonrpc({ jsonrpc: "2.0", id: 1, method: "initialize", params: {} })
    assert_response :success
  end

  test "POST /mcp with valid Origin (own host) is allowed" do
    post_jsonrpc(
      { jsonrpc: "2.0", id: 1, method: "initialize", params: {} },
      headers: auth_headers(origin: "https://#{@tenant.subdomain}.#{ENV.fetch("HOSTNAME", nil)}")
    )
    assert_response :success
  end

  test "POST /mcp with foreign Origin returns 403" do
    post_jsonrpc(
      { jsonrpc: "2.0", id: 1, method: "initialize", params: {} },
      headers: auth_headers(origin: "https://evil.example.com")
    )
    assert_response :forbidden
  end

  # ====================
  # Protocol version header
  # ====================

  test "POST /mcp with unsupported MCP-Protocol-Version returns 400" do
    post_jsonrpc(
      { jsonrpc: "2.0", id: 1, method: "initialize", params: {} },
      headers: auth_headers(protocol_version: "1999-01-01")
    )
    assert_response :bad_request
  end

  test "POST /mcp without MCP-Protocol-Version header is allowed" do
    post_jsonrpc(
      { jsonrpc: "2.0", id: 1, method: "initialize", params: {} },
      headers: auth_headers(protocol_version: nil)
    )
    assert_response :success
  end

  # ====================
  # initialize
  # ====================

  test "initialize returns server info, protocol version, and capabilities" do
    post_jsonrpc({ jsonrpc: "2.0", id: 1, method: "initialize", params: {} })

    assert_response :success
    body = response.parsed_body
    assert_equal "2.0", body["jsonrpc"]
    assert_equal 1, body["id"]

    result = body["result"]
    assert_equal SUPPORTED_PROTOCOL_VERSION, result["protocolVersion"]
    assert result.dig("serverInfo", "name").present?
    assert result.dig("serverInfo", "version").present?

    capabilities = result["capabilities"]
    assert capabilities.key?("tools"), "should advertise tools capability"
    assert capabilities.key?("resources"), "should advertise resources capability"
    assert_not capabilities.key?("prompts"), "should not advertise prompts capability"
    assert_not capabilities.key?("logging"), "should not advertise logging capability"
    assert_not capabilities.key?("sampling"), "should not advertise sampling capability"
  end

  test "initialize response does NOT include MCP-Session-Id header" do
    post_jsonrpc({ jsonrpc: "2.0", id: 1, method: "initialize", params: {} })
    assert_response :success
    assert_nil response.headers["MCP-Session-Id"]
  end

  # ====================
  # notifications/initialized
  # ====================

  test "notifications/initialized returns 202 with no body" do
    post_jsonrpc({ jsonrpc: "2.0", method: "notifications/initialized" })
    assert_response :accepted
    assert response.body.empty?
  end

  # ====================
  # tools/list
  # ====================

  test "tools/list returns all expected tools with descriptions and input schemas" do
    post_jsonrpc({ jsonrpc: "2.0", id: 2, method: "tools/list" })

    assert_response :success
    body = response.parsed_body
    tool_names = body.dig("result", "tools").map { |t| t["name"] }

    ["fetch_page", "execute_action", "search"].each do |name|
      assert_includes tool_names, name, "tools/list missing #{name}"
      tool = body["result"]["tools"].find { |t| t["name"] == name }
      assert tool["description"].is_a?(String) && tool["description"].present?, "#{name} missing description"
      assert tool["inputSchema"].is_a?(Hash), "#{name} missing inputSchema"
    end

    fetch_page = body["result"]["tools"].find { |t| t["name"] == "fetch_page" }
    assert_includes fetch_page["inputSchema"]["required"], "path"

    execute_action = body["result"]["tools"].find { |t| t["name"] == "execute_action" }
    assert_includes execute_action["inputSchema"]["required"], "path"
    assert_includes execute_action["inputSchema"]["required"], "action"

    search = body["result"]["tools"].find { |t| t["name"] == "search" }
    assert_includes search["inputSchema"]["required"], "query"
  end

  # ====================
  # tools/call
  # ====================

  test "tools/call fetch_page with valid path returns markdown content" do
    post_jsonrpc({
                   jsonrpc: "2.0",
                   id: 3,
                   method: "tools/call",
                   params: { name: "fetch_page", arguments: { path: "/whoami" } },
                 })

    assert_response :success
    body = response.parsed_body
    assert_equal "2.0", body["jsonrpc"]
    assert_equal 3, body["id"]

    content = body.dig("result", "content")
    assert content.is_a?(Array) && content.any?
    assert_equal "text", content.first["type"]
    assert content.first["text"].include?("Who Am I?"), "should contain rendered whoami markdown"
  end

  test "tools/call with unknown tool returns isError content (not JSON-RPC error)" do
    post_jsonrpc({
                   jsonrpc: "2.0",
                   id: 4,
                   method: "tools/call",
                   params: { name: "does_not_exist", arguments: {} },
                 })

    assert_response :success
    body = response.parsed_body
    # Tool execution errors are returned as result.isError, not as JSON-RPC error
    assert body["result"]["isError"]
    assert_not body.key?("error")
  end

  # ====================
  # Unknown method / malformed body
  # ====================

  test "unknown method returns JSON-RPC method-not-found error" do
    post_jsonrpc({ jsonrpc: "2.0", id: 5, method: "totally/made/up" })

    assert_response :success
    body = response.parsed_body
    assert_equal(-32_601, body["error"]["code"])
  end

  test "JSON-RPC array body (batch) returns 400" do
    post_jsonrpc([
                   { jsonrpc: "2.0", id: 1, method: "ping" },
                   { jsonrpc: "2.0", id: 2, method: "ping" },
                 ])
    assert_response :bad_request
  end

  test "malformed JSON body returns JSON-RPC parse error" do
    post "/mcp",
         params: "not json",
         headers: auth_headers

    body = response.parsed_body
    assert_equal(-32_700, body["error"]["code"])
  end

  test "scalar JSON body returns invalid-request error" do
    post_jsonrpc(42)
    assert_response :bad_request
    body = response.parsed_body
    assert_equal(-32_600, body["error"]["code"])
  end

  test "empty JSON object is treated as a notification and returns 202" do
    post_jsonrpc({})
    assert_response :accepted
  end

  test "tools/call with non-Hash params returns invalid-params error" do
    post_jsonrpc({ jsonrpc: "2.0", id: 30, method: "tools/call", params: [1, 2, 3] })
    assert_response :success
    body = response.parsed_body
    assert_equal(-32_602, body["error"]["code"])
  end

  test "request with notifications/* method but with id is treated as request (gets response)" do
    # Per JSON-RPC: presence of `id` makes it a request regardless of method
    # name. Server MUST respond.
    post_jsonrpc({ jsonrpc: "2.0", id: 31, method: "notifications/initialized" })
    assert_response :success
    body = response.parsed_body
    # method is unknown as a request, so method-not-found is fine here —
    # the point is that we DO respond instead of silently 202'ing
    assert_equal 31, body["id"]
    assert body.key?("error")
  end

  test "lowercase 'bearer' scheme is accepted (RFC 7235 case-insensitive)" do
    post "/mcp",
         params: { jsonrpc: "2.0", id: 1, method: "initialize", params: {} }.to_json,
         headers: {
           "Authorization" => "bearer #{@plaintext_token}",
           "Content-Type" => "application/json",
           "MCP-Protocol-Version" => SUPPORTED_PROTOCOL_VERSION,
         }
    assert_response :success
  end

  test "fetch_page rejects absolute URL" do
    post_jsonrpc({
                   jsonrpc: "2.0",
                   id: 40,
                   method: "tools/call",
                   params: { name: "fetch_page", arguments: { path: "https://evil.example.com/exfiltrate" } },
                 })
    assert_response :success
    body = response.parsed_body
    assert body["result"]["isError"]
    assert_match(/Invalid path/, body["result"]["content"].first["text"])
  end

  test "fetch_page rejects protocol-relative path" do
    post_jsonrpc({
                   jsonrpc: "2.0",
                   id: 41,
                   method: "tools/call",
                   params: { name: "fetch_page", arguments: { path: "//evil.example.com/x" } },
                 })
    assert_response :success
    body = response.parsed_body
    assert body["result"]["isError"]
    assert_match(/Invalid path/, body["result"]["content"].first["text"])
  end

  test "fetch_page rejects path without leading slash" do
    post_jsonrpc({
                   jsonrpc: "2.0",
                   id: 42,
                   method: "tools/call",
                   params: { name: "fetch_page", arguments: { path: "whoami" } },
                 })
    assert_response :success
    body = response.parsed_body
    assert body["result"]["isError"]
    assert_match(/Invalid path/, body["result"]["content"].first["text"])
  end

  # ====================
  # execute_action
  # ====================

  test "execute_action create_note posts to action endpoint and returns markdown result" do
    post_jsonrpc({
                   jsonrpc: "2.0",
                   id: 60,
                   method: "tools/call",
                   params: {
                     name: "execute_action",
                     arguments: {
                       path: "/collectives/#{@collective.handle}/note",
                       action: "create_note",
                       params: { text: "Hello from MCP test" },
                     },
                   },
                 })

    assert_response :success
    body = response.parsed_body
    assert_not body["result"]["isError"], "should succeed"
    assert Note.exists?(text: "Hello from MCP test", created_by: @user)
  end

  test "execute_action without path returns tool error" do
    post_jsonrpc({
                   jsonrpc: "2.0",
                   id: 61,
                   method: "tools/call",
                   params: { name: "execute_action", arguments: { action: "create_note", params: {} } },
                 })
    assert_response :success
    body = response.parsed_body
    assert body["result"]["isError"]
    assert_match(/path/, body["result"]["content"].first["text"])
  end

  test "execute_action without action returns tool error" do
    post_jsonrpc({
                   jsonrpc: "2.0",
                   id: 62,
                   method: "tools/call",
                   params: { name: "execute_action", arguments: { path: "/collectives/#{@collective.handle}", params: {} } },
                 })
    assert_response :success
    body = response.parsed_body
    assert body["result"]["isError"]
    assert_match(/action/, body["result"]["content"].first["text"])
  end

  test "execute_action with non-Hash params returns tool error" do
    post_jsonrpc({
                   jsonrpc: "2.0",
                   id: 63,
                   method: "tools/call",
                   params: { name: "execute_action", arguments: { path: "/x", action: "y", params: [1, 2, 3] } },
                 })
    assert_response :success
    body = response.parsed_body
    assert body["result"]["isError"]
    assert_match(/params/, body["result"]["content"].first["text"])
  end

  test "execute_action strips a pasted /actions/<name> suffix from path" do
    # Agents often paste the full action URL they see in fetch_page output.
    # The trailing /actions/<name> should be stripped so we POST to the
    # right place, not to /collectives/.../note/actions/create_note/actions/create_note.
    post_jsonrpc({
                   jsonrpc: "2.0",
                   id: 64,
                   method: "tools/call",
                   params: {
                     name: "execute_action",
                     arguments: {
                       path: "/collectives/#{@collective.handle}/note/actions/create_note",
                       action: "create_note",
                       params: { text: "Stripped suffix path" },
                     },
                   },
                 })
    assert_response :success
    body = response.parsed_body
    assert_not body["result"]["isError"], "should succeed after stripping suffix"
    assert Note.exists?(text: "Stripped suffix path", created_by: @user)
  end

  test "execute_action strips query string from path" do
    post_jsonrpc({
                   jsonrpc: "2.0",
                   id: 65,
                   method: "tools/call",
                   params: {
                     name: "execute_action",
                     arguments: {
                       path: "/collectives/#{@collective.handle}/note?some=garbage",
                       action: "create_note",
                       params: { text: "Stripped query path" },
                     },
                   },
                 })
    assert_response :success
    body = response.parsed_body
    assert_not body["result"]["isError"], "should succeed after stripping query string"
    assert Note.exists?(text: "Stripped query path", created_by: @user)
  end

  test "execute_action rejects absolute URL" do
    post_jsonrpc({
                   jsonrpc: "2.0",
                   id: 66,
                   method: "tools/call",
                   params: {
                     name: "execute_action",
                     arguments: {
                       path: "https://evil.example.com/exfiltrate",
                       action: "create_note",
                       params: { text: "should not exist" },
                     },
                   },
                 })
    assert_response :success
    body = response.parsed_body
    assert body["result"]["isError"]
    assert_match(/Invalid path/, body["result"]["content"].first["text"])
    assert_not Note.exists?(text: "should not exist")
  end

  test "execute_action capability-denied surfaces the inner-dispatch error body to the agent" do
    # AI agents without the capability for the action get 403'd by the
    # inner controllers. The agent needs to see WHY it failed so it can
    # adjust — not just a generic "Access denied".
    ai_agent = create_ai_agent(parent: @user, name: "Capability Test Agent")
    @tenant.add_user!(ai_agent)
    @collective.add_user!(ai_agent)
    ai_agent.update_columns(agent_configuration: { "capabilities" => [] })
    agent_token = ApiToken.create!(
      tenant: @tenant,
      user: ai_agent,
      scopes: ApiToken.valid_scopes
    )

    post_jsonrpc(
      {
        jsonrpc: "2.0",
        id: 67,
        method: "tools/call",
        params: {
          name: "execute_action",
          arguments: {
            path: "/collectives/#{@collective.handle}/note",
            action: "create_note",
            params: { text: "should not exist" },
          },
        },
      },
      headers: auth_headers(token: agent_token.plaintext_token)
    )

    assert_response :success
    body = response.parsed_body
    assert body["result"]["isError"]
    # Inner controller's 403 body explains which capability is missing —
    # that body should reach the agent so it can act on the information.
    text = body["result"]["content"].first["text"]
    assert_match(/create_note/, text, "expected the action name in the error body so the agent knows what's blocked")
    assert_not Note.exists?(text: "should not exist")
  end

  # ====================
  # search
  # ====================

  test "search with a query returns markdown content" do
    # Create a note we can find
    create_note(tenant: @tenant, collective: @collective, created_by: @user, text: "unique-mcp-search-marker", title: "Search Target")

    post_jsonrpc({
                   jsonrpc: "2.0",
                   id: 70,
                   method: "tools/call",
                   params: { name: "search", arguments: { query: "unique-mcp-search-marker" } },
                 })

    assert_response :success
    body = response.parsed_body
    assert_not body["result"]["isError"]
    text = body["result"]["content"].first["text"]
    assert_match(/unique-mcp-search-marker/, text, "search results should include the matching note")
  end

  test "search without query returns tool error" do
    post_jsonrpc({
                   jsonrpc: "2.0",
                   id: 71,
                   method: "tools/call",
                   params: { name: "search", arguments: {} },
                 })
    assert_response :success
    body = response.parsed_body
    assert body["result"]["isError"]
    assert_match(/query/, body["result"]["content"].first["text"])
  end

  test "search with non-String query returns tool error" do
    post_jsonrpc({
                   jsonrpc: "2.0",
                   id: 72,
                   method: "tools/call",
                   params: { name: "search", arguments: { query: [1, 2, 3] } },
                 })
    assert_response :success
    body = response.parsed_body
    assert body["result"]["isError"]
    assert_match(/query/, body["result"]["content"].first["text"])
  end

  test "search URL-encodes the query" do
    # A query with characters that have URL-special meaning (& = ? #) must be
    # encoded so they reach /search?q=... as the literal query, not as URL
    # delimiters that change the meaning of the request.
    post_jsonrpc({
                   jsonrpc: "2.0",
                   id: 73,
                   method: "tools/call",
                   params: { name: "search", arguments: { query: "foo & bar = baz #qux" } },
                 })

    assert_response :success
    body = response.parsed_body
    # Whether anything matches isn't the point — the point is that the call
    # completes without an inner-dispatch error caused by mangled URL.
    assert_not body["result"]["isError"], "encoded special characters should not break the dispatch"
  end

  # ====================
  # ping
  # ====================

  test "ping returns empty result" do
    post_jsonrpc({ jsonrpc: "2.0", id: 99, method: "ping" })

    assert_response :success
    body = response.parsed_body
    assert_equal({}, body["result"])
    assert_equal 99, body["id"]
  end

  # ====================
  # Inner-dispatch security
  #
  # The MCP endpoint authenticates the Bearer at its own layer for the spec's
  # WWW-Authenticate response, but it's *not* the authoritative gate.
  # MarkdownUiService dispatches every tool call through the full Rails stack,
  # where ApplicationController's filter chain (api_authorize!,
  # check_capability_for_action, etc.) runs as it would for a direct HTTP
  # request with the same Bearer. These tests pin that contract so a future
  # refactor can't accidentally bypass it.
  # ====================

  test "fetch_page surfaces a tool error when tenant API is disabled" do
    @tenant.set_feature_flag!("api", false)

    post_jsonrpc({
                   jsonrpc: "2.0",
                   id: 10,
                   method: "tools/call",
                   params: { name: "fetch_page", arguments: { path: "/collectives/#{@collective.handle}" } },
                 })

    assert_response :success
    body = response.parsed_body
    # api_authorize! renders an "API not enabled" JSON error which MarkdownUiService
    # surfaces as a navigation error → wrapped as a tool isError.
    assert body["result"]["isError"], "tool should report inner-dispatch rejection"
  end

  test "fetch_page surfaces a tool error when collective API is disabled" do
    @collective.disable_feature_flag!("api")

    post_jsonrpc({
                   jsonrpc: "2.0",
                   id: 11,
                   method: "tools/call",
                   params: { name: "fetch_page", arguments: { path: "/collectives/#{@collective.handle}" } },
                 })

    assert_response :success
    body = response.parsed_body
    assert body["result"]["isError"], "tool should report inner-dispatch rejection"
  end

  # ====================
  # Unhandled exception → JSON-RPC internal error (not HTML 500)
  # ====================

  test "unhandled exception in handler returns JSON-RPC internal-error envelope, not HTML" do
    # Stub MarkdownUiService.new to raise — simulates an unforeseen crash
    # somewhere below the controller. Without rescue_from this would render
    # Rails' default HTML error page; with rescue_from we expect a JSON-RPC
    # envelope.
    raising = ->(**) { raise StandardError, "boom" }
    MarkdownUiService.stub(:new, raising) do
      post_jsonrpc({
                     jsonrpc: "2.0",
                     id: 50,
                     method: "tools/call",
                     params: { name: "fetch_page", arguments: { path: "/whoami" } },
                   })
    end

    assert_response :internal_server_error
    body = response.parsed_body
    assert_equal "2.0", body["jsonrpc"]
    assert_equal(-32_603, body["error"]["code"])
    # Don't leak the raw exception message to the client.
    assert_no_match(/boom/, body["error"]["message"])
  end
end
