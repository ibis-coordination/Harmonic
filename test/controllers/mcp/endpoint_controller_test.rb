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

  test "tools/list includes fetch_page tool" do
    post_jsonrpc({ jsonrpc: "2.0", id: 2, method: "tools/list" })

    assert_response :success
    body = response.parsed_body
    tool_names = body.dig("result", "tools").map { |t| t["name"] }
    assert_includes tool_names, "fetch_page"

    fetch_page = body["result"]["tools"].find { |t| t["name"] == "fetch_page" }
    assert fetch_page["description"].is_a?(String) && fetch_page["description"].present?
    assert fetch_page["inputSchema"].is_a?(Hash)
    assert_includes fetch_page["inputSchema"]["required"], "path"
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
