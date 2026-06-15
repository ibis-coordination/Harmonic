require "test_helper"

# Tests for the MCP (Model Context Protocol) endpoint at POST /mcp.
#
# Covers the Streamable HTTP transport from spec revision 2025-11-25:
# https://modelcontextprotocol.io/specification/2025-11-25/basic/transports
#
# Exercises the JSON-RPC envelope (initialize, ping, tools/list, tools/call,
# resources/list, resources/read, notifications), Bearer auth, the Origin
# / Accept / MCP-Protocol-Version header policies, the four tools
# (fetch_page, execute_action, search, get_help), the harmonic://context
# resource, the inner-dispatch security contract, and the rescue_from
# fallback that turns unhandled exceptions into JSON-RPC envelopes.
class Mcp::EndpointControllerTest < ActionDispatch::IntegrationTest # rubocop:disable Style/ClassAndModuleChildren,Metrics/ClassLength
  SUPPORTED_PROTOCOL_VERSION = "2025-11-25".freeze

  def setup
    @tenant = @global_tenant
    @tenant.enable_api!
    @collective = @global_collective
    @collective.enable_api!
    @user = @global_user

    # MCP tokens must belong to an AI agent identity, not a human. Create
    # an external-mode agent (the mode that actually has API tokens).
    @agent = create_ai_agent(parent: @user, name: "MCP Test Agent", agent_configuration: { "mode" => "external" })
    @tenant.add_user!(@agent)
    @collective.add_user!(@agent)

    @api_token = ApiToken.create!(
      tenant: @tenant,
      user: @agent,
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

  test "POST /mcp with a human-user token returns 403 with a pointer to /help/mcp" do
    # MCP is for AI agent identities only. A human-owned token is a valid
    # token but isn't permitted via this endpoint — letting an LLM
    # authenticate as a human would record activity under the human's name
    # and break attribution.
    human_token = ApiToken.create!(
      tenant: @tenant,
      user: @user,
      scopes: ApiToken.valid_scopes
    )

    post_jsonrpc(
      { jsonrpc: "2.0", id: 1, method: "initialize", params: {} },
      headers: auth_headers(token: human_token.plaintext_token)
    )

    assert_response :forbidden
    body = response.parsed_body
    msg = body["error"]["message"]
    assert_match(/AI agent identity/, msg)
    assert_match(%r{/help/mcp}, msg)
    # The message names the actual user_type and handle so the operator can
    # see exactly whose token tripped the gate.
    assert_match(/human user @#{@user.handle}/, msg)
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
  # Accept header policy
  # ====================

  test "POST /mcp without Accept header is allowed (implicit */*)" do
    post "/mcp",
         params: { jsonrpc: "2.0", id: 1, method: "initialize", params: {} }.to_json,
         headers: {
           "Authorization" => "Bearer #{@plaintext_token}",
           "Content-Type" => "application/json",
           "MCP-Protocol-Version" => SUPPORTED_PROTOCOL_VERSION,
         }
    assert_response :success
  end

  test "POST /mcp with Accept: */* is allowed" do
    post "/mcp",
         params: { jsonrpc: "2.0", id: 1, method: "initialize", params: {} }.to_json,
         headers: {
           "Authorization" => "Bearer #{@plaintext_token}",
           "Content-Type" => "application/json",
           "Accept" => "*/*",
           "MCP-Protocol-Version" => SUPPORTED_PROTOCOL_VERSION,
         }
    assert_response :success
  end

  test "POST /mcp with Accept: application/json (no event-stream) is allowed since we never stream" do
    # Strict reading of the Streamable HTTP spec says the client MUST list
    # both. We're permissive because we never emit SSE — application/json
    # alone is enough for the client to consume our responses.
    post "/mcp",
         params: { jsonrpc: "2.0", id: 1, method: "initialize", params: {} }.to_json,
         headers: {
           "Authorization" => "Bearer #{@plaintext_token}",
           "Content-Type" => "application/json",
           "Accept" => "application/json",
           "MCP-Protocol-Version" => SUPPORTED_PROTOCOL_VERSION,
         }
    assert_response :success
  end

  test "POST /mcp with Accept that excludes application/json returns 406" do
    post "/mcp",
         params: { jsonrpc: "2.0", id: 1, method: "initialize", params: {} }.to_json,
         headers: {
           "Authorization" => "Bearer #{@plaintext_token}",
           "Content-Type" => "application/json",
           "Accept" => "text/plain",
           "MCP-Protocol-Version" => SUPPORTED_PROTOCOL_VERSION,
         }
    assert_response :not_acceptable
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

    ["fetch_page", "execute_action", "search", "get_help"].each do |name|
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

    get_help = body["result"]["tools"].find { |t| t["name"] == "get_help" }
    # get_help has no required arguments — no topic means "fetch the index".
    assert_nil get_help["inputSchema"]["required"]
    assert_includes get_help["inputSchema"]["properties"].keys, "topic"
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
    assert Note.exists?(text: "Hello from MCP test", created_by: @agent)
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
    assert Note.exists?(text: "Stripped suffix path", created_by: @agent)
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
    assert Note.exists?(text: "Stripped query path", created_by: @agent)
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
  # get_help
  # ====================

  test "get_help with a known topic returns the help markdown" do
    post_jsonrpc({
                   jsonrpc: "2.0",
                   id: 80,
                   method: "tools/call",
                   params: { name: "get_help", arguments: { topic: "notes" } },
                 })

    assert_response :success
    body = response.parsed_body
    assert_not body["result"]["isError"]
    text = body["result"]["content"].first["text"]
    # /help/notes renders a markdown doc with the heading "Notes". We just
    # need to know the inner dispatch hit the right page.
    assert_match(/Notes/i, text)
  end

  test "get_help with no topic returns the help index so the agent can discover topics" do
    post_jsonrpc({
                   jsonrpc: "2.0",
                   id: 81,
                   method: "tools/call",
                   params: { name: "get_help", arguments: {} },
                 })
    assert_response :success
    body = response.parsed_body
    assert_not body["result"]["isError"]
    text = body["result"]["content"].first["text"]
    # The /help index page lists topics — verify a couple are present so we
    # know we hit the right page, not some other Help-flavored response.
    assert_match(%r{/help/notes}, text)
    assert_match(%r{/help/decisions}, text)
  end

  test "get_help with non-String topic returns tool error" do
    post_jsonrpc({
                   jsonrpc: "2.0",
                   id: 82,
                   method: "tools/call",
                   params: { name: "get_help", arguments: { topic: [1, 2, 3] } },
                 })
    assert_response :success
    body = response.parsed_body
    assert body["result"]["isError"]
    assert_match(/topic/, body["result"]["content"].first["text"])
  end

  test "get_help with unknown topic surfaces the inner-dispatch 404 to the agent" do
    post_jsonrpc({
                   jsonrpc: "2.0",
                   id: 83,
                   method: "tools/call",
                   params: { name: "get_help", arguments: { topic: "does-not-exist-anywhere" } },
                 })
    assert_response :success
    body = response.parsed_body
    assert body["result"]["isError"]
  end

  test "get_help URL-encodes the topic so path traversal is harmless" do
    # An agent passing something like "../routes" must not be able to
    # navigate above /help/. URL-encoding turns the / into %2F which the
    # routes can't match — so the inner dispatch 404s and the agent gets
    # a clean tool error rather than reaching some other page.
    post_jsonrpc({
                   jsonrpc: "2.0",
                   id: 84,
                   method: "tools/call",
                   params: { name: "get_help", arguments: { topic: "../privacy" } },
                 })
    assert_response :success
    body = response.parsed_body
    assert body["result"]["isError"]
  end

  # ====================
  # resources/list and resources/read
  # ====================

  test "resources/list returns the harmonic://context resource" do
    post_jsonrpc({ jsonrpc: "2.0", id: 90, method: "resources/list" })

    assert_response :success
    body = response.parsed_body
    resources = body.dig("result", "resources")
    assert resources.is_a?(Array)

    context = resources.find { |r| r["uri"] == "harmonic://context" }
    assert context, "expected harmonic://context in resources/list"
    assert context["name"].is_a?(String) && context["name"].present?
    assert context["description"].is_a?(String) && context["description"].present?
    assert_equal "text/markdown", context["mimeType"]
  end

  test "resources/read returns the harmonic://context content" do
    post_jsonrpc({
                   jsonrpc: "2.0",
                   id: 91,
                   method: "resources/read",
                   params: { uri: "harmonic://context" },
                 })

    assert_response :success
    body = response.parsed_body
    contents = body.dig("result", "contents")
    assert contents.is_a?(Array) && contents.any?

    entry = contents.first
    assert_equal "harmonic://context", entry["uri"]
    assert_equal "text/markdown", entry["mimeType"]
    assert entry["text"].is_a?(String) && entry["text"].present?
    # The context should reference Harmonic and at least one of the tools so
    # we know we got the right document, not an empty placeholder.
    assert_match(/Harmonic/, entry["text"])
    assert_match(/fetch_page/, entry["text"])
  end

  test "resources/read with unknown URI returns JSON-RPC invalid-params error" do
    post_jsonrpc({
                   jsonrpc: "2.0",
                   id: 92,
                   method: "resources/read",
                   params: { uri: "harmonic://does-not-exist" },
                 })

    assert_response :success
    body = response.parsed_body
    assert_equal(-32_602, body["error"]["code"])
  end

  test "resources/read without uri param returns JSON-RPC invalid-params error" do
    post_jsonrpc({ jsonrpc: "2.0", id: 93, method: "resources/read", params: {} })

    assert_response :success
    body = response.parsed_body
    assert_equal(-32_602, body["error"]["code"])
  end

  test "resources/read with non-Hash params returns JSON-RPC invalid-params error" do
    post_jsonrpc({ jsonrpc: "2.0", id: 94, method: "resources/read", params: [1, 2, 3] })

    assert_response :success
    body = response.parsed_body
    assert_equal(-32_602, body["error"]["code"])
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

  # ====================
  # Audit logging
  #
  # Every tools/call writes an McpToolCallLog row tagged with the agent's
  # user, the token, the tool name, redacted arguments, and the outcome
  # (ok | tool_error | unknown_tool). This is the substrate for surfacing
  # to a human principal "what their agent has been doing."
  # ====================

  test "tools/call success writes an audit log tagged with agent identity" do
    assert_difference -> { McpToolCallLog.count }, 1 do
      post_jsonrpc({
                     jsonrpc: "2.0",
                     id: 60,
                     method: "tools/call",
                     params: { name: "fetch_page", arguments: { path: "/whoami" } },
                   })
    end

    log = McpToolCallLog.order(:created_at).last
    assert_equal @agent, log.user
    assert_equal @api_token, log.api_token
    assert_equal @tenant, log.tenant
    assert_equal "fetch_page", log.tool_name
    assert_equal "ok", log.status
    assert log.duration_ms >= 0
    assert_equal({ "path" => "/whoami" }, log.arguments)
  end

  test "tools/call with unknown tool writes a log with status=unknown_tool" do
    assert_difference -> { McpToolCallLog.count }, 1 do
      post_jsonrpc({
                     jsonrpc: "2.0",
                     id: 61,
                     method: "tools/call",
                     params: { name: "no_such_tool", arguments: { foo: "bar" } },
                   })
    end

    log = McpToolCallLog.order(:created_at).last
    assert_equal "no_such_tool", log.tool_name
    assert_equal "unknown_tool", log.status
  end

  test "tools/call that surfaces a tool error writes a log with status=tool_error" do
    # fetch_page with a non-existent path → MarkdownUiService returns an error
    # surfaced as a tool error.
    assert_difference -> { McpToolCallLog.count }, 1 do
      post_jsonrpc({
                     jsonrpc: "2.0",
                     id: 62,
                     method: "tools/call",
                     params: { name: "fetch_page", arguments: { path: "/totally/not/a/real/path" } },
                   })
    end

    log = McpToolCallLog.order(:created_at).last
    assert_equal "fetch_page", log.tool_name
    assert_equal "tool_error", log.status
  end

  test "execute_action audit log redacts params to key names only" do
    note = create_note(tenant: @tenant, collective: @collective, created_by: @user)

    assert_difference -> { McpToolCallLog.count }, 1 do
      post_jsonrpc({
                     jsonrpc: "2.0",
                     id: 63,
                     method: "tools/call",
                     params: {
                       name: "execute_action",
                       arguments: {
                         path: note.path,
                         action: "add_comment",
                         params: { "body" => "secret note content the principal should not see verbatim" },
                       },
                     },
                   })
    end

    log = McpToolCallLog.order(:created_at).last
    assert_equal "execute_action", log.tool_name
    assert_equal note.path, log.arguments["path"]
    assert_equal "add_comment", log.arguments["action"]
    # The action params value is replaced with a keys-only summary — the
    # raw values never hit the log.
    assert_equal({ "keys" => ["body"] }, log.arguments["params"])
    assert_no_match(/secret note content/, log.arguments.to_json)
  end

  test "execute_action audit log redacts malformed params (string) to a shape summary, never the raw value" do
    # Agent sends a bogus `params` value (not a Hash). The tool call returns a
    # tool error, but the audit log must still record the call WITHOUT
    # surfacing the raw string content.
    assert_difference -> { McpToolCallLog.count }, 1 do
      post_jsonrpc({
                     jsonrpc: "2.0",
                     id: 64,
                     method: "tools/call",
                     params: {
                       name: "execute_action",
                       arguments: {
                         path: "/whoami",
                         action: "noop",
                         params: "secret value that should never hit the log",
                       },
                     },
                   })
    end

    log = McpToolCallLog.order(:created_at).last
    assert_equal "execute_action", log.tool_name
    assert_no_match(/secret value/, log.arguments.to_json)
    # We do record the type so the principal can see "the agent sent
    # something malformed" without revealing the content.
    assert_equal "String", log.arguments.dig("params", "type")
  end

  test "fetch_page audit log strips undeclared extra fields from arguments" do
    # The agent's `arguments` hash is whatever JSON they sent. fetch_page's
    # schema only declares `path`, so any extra key — including one named
    # `params` — is undeclared content and must not land in the log.
    assert_difference -> { McpToolCallLog.count }, 1 do
      post_jsonrpc({
                     jsonrpc: "2.0",
                     id: 65,
                     method: "tools/call",
                     params: {
                       name: "fetch_page",
                       arguments: {
                         path: "/whoami",
                         params: "secret value the principal should never see",
                         extra_random_field: "another secret",
                       },
                     },
                   })
    end

    log = McpToolCallLog.order(:created_at).last
    assert_equal({ "path" => "/whoami" }, log.arguments)
    assert_no_match(/secret/, log.arguments.to_json)
  end

  test "execute_action audit log strips undeclared extra fields from arguments" do
    note = create_note(tenant: @tenant, collective: @collective, created_by: @user)

    assert_difference -> { McpToolCallLog.count }, 1 do
      post_jsonrpc({
                     jsonrpc: "2.0",
                     id: 66,
                     method: "tools/call",
                     params: {
                       name: "execute_action",
                       arguments: {
                         path: note.path,
                         action: "add_comment",
                         params: { "body" => "redacted body content" },
                         extra_secret: "should not be logged",
                       },
                     },
                   })
    end

    log = McpToolCallLog.order(:created_at).last
    assert_equal note.path, log.arguments["path"]
    assert_equal "add_comment", log.arguments["action"]
    assert_equal({ "keys" => ["body"] }, log.arguments["params"])
    assert_nil log.arguments["extra_secret"]
    assert_no_match(/should not be logged/, log.arguments.to_json)
  end

  test "unknown tool audit log records empty arguments (no field leakage from hallucinated tools)" do
    assert_difference -> { McpToolCallLog.count }, 1 do
      post_jsonrpc({
                     jsonrpc: "2.0",
                     id: 67,
                     method: "tools/call",
                     params: {
                       name: "no_such_tool",
                       arguments: { secret_field: "secret value" },
                     },
                   })
    end

    log = McpToolCallLog.order(:created_at).last
    assert_equal "no_such_tool", log.tool_name
    assert_equal "unknown_tool", log.status
    assert_equal({}, log.arguments)
  end

  test "tools/call with missing name returns INVALID_PARAMS and writes no audit log" do
    # Missing name is a protocol-layer error per the MCP spec; no tool was
    # attempted, so no audit row.
    assert_no_difference -> { McpToolCallLog.count } do
      post_jsonrpc({
                     jsonrpc: "2.0",
                     id: 68,
                     method: "tools/call",
                     params: { arguments: { path: "/whoami" } },
                   })
    end

    body = response.parsed_body
    assert_equal(-32_602, body["error"]["code"])
  end

  test "tools/call with non-Hash params writes no audit log" do
    # Pinning behavior: a malformed tools/call (params is not an object)
    # returns a JSON-RPC error envelope without ever reaching tool dispatch,
    # so it does not generate an audit row.
    assert_no_difference -> { McpToolCallLog.count } do
      post_jsonrpc({ jsonrpc: "2.0", id: 69, method: "tools/call", params: [1, 2, 3] })
    end
  end

  test "non-tool methods do not write audit logs" do
    assert_no_difference -> { McpToolCallLog.count } do
      post_jsonrpc({ jsonrpc: "2.0", id: 70, method: "ping" })
      post_jsonrpc({ jsonrpc: "2.0", id: 71, method: "tools/list" })
      post_jsonrpc({ jsonrpc: "2.0", id: 72, method: "resources/list" })
      post_jsonrpc({
                     jsonrpc: "2.0", id: 73, method: "initialize",
                     params: { protocolVersion: SUPPORTED_PROTOCOL_VERSION },
                   })
    end
  end

  test "unauthenticated tools/call does not write an audit log" do
    assert_no_difference -> { McpToolCallLog.count } do
      post "/mcp",
           params: { jsonrpc: "2.0", id: 80, method: "tools/call",
                     params: { name: "fetch_page", arguments: { path: "/whoami" } }, }.to_json,
           headers: { "Content-Type" => "application/json",
                      "Accept" => "application/json, text/event-stream",
                      "MCP-Protocol-Version" => SUPPORTED_PROTOCOL_VERSION, }
    end
  end

  test "tools/call request_id is recorded on the audit log" do
    post_jsonrpc({
                   jsonrpc: "2.0",
                   id: 90,
                   method: "tools/call",
                   params: { name: "fetch_page", arguments: { path: "/whoami" } },
                 })

    log = McpToolCallLog.order(:created_at).last
    # Rails always assigns a request_id; we don't care about the exact value,
    # just that it's persisted so logs are correlatable.
    assert log.request_id.present?, "expected request_id to be persisted"
  end

  # ====================
  # Rate limits + response body cap
  # ====================

  def with_rate_limit_override(burst: nil, sustained: nil, principal: nil, tenant: nil)
    cls = Mcp::EndpointController
    cls.stub(:burst_limit_per_token, burst || cls.burst_limit_per_token) do
      cls.stub(:sustained_limit_per_token, sustained || cls.sustained_limit_per_token) do
        cls.stub(:sustained_limit_per_principal, principal || cls.sustained_limit_per_principal) do
          cls.stub(:aggregate_limit_per_tenant, tenant || cls.aggregate_limit_per_tenant) do
            yield
          end
        end
      end
    end
  end

  # Scoped to specific keys so parallel tests don't reset each other's
  # counters. The shared tenant counter would otherwise race between tests.
  def clear_mcp_rate_limit_keys(token_ids: [], tenant_ids: [])
    patterns = []
    Array(token_ids).each do |tid|
      patterns << "rate_limit:mcp/burst:#{tid}"
      patterns << "rate_limit:mcp/sustained:#{tid}"
    end
    Array(tenant_ids).each { |t| patterns << "rate_limit:mcp/tenant:#{t}" }
    return if patterns.empty?

    Sidekiq.redis { |conn| patterns.each { |p| conn.del(p) } }
  end

  test "burst limit returns 429 with Retry-After when the per-token burst is exceeded" do
    clear_mcp_rate_limit_keys(token_ids: [@api_token.id])
    begin
      with_rate_limit_override(burst: 3, sustained: 1_000, tenant: 1_000_000) do
        3.times do |i|
          post_jsonrpc({ jsonrpc: "2.0", id: 100 + i, method: "ping" })
          assert_response :success, "request #{i + 1} within burst should pass"
        end

        post_jsonrpc({ jsonrpc: "2.0", id: 200, method: "ping" })
        assert_response :too_many_requests
        assert_equal "1", response.headers["Retry-After"]
        body = response.parsed_body
        assert_match(/rate limit/i, body["error"]["message"])
      end
    ensure
      clear_mcp_rate_limit_keys(token_ids: [@api_token.id])
    end
  end

  test "sustained limit returns 429 when the per-token per-minute limit is exceeded" do
    clear_mcp_rate_limit_keys(token_ids: [@api_token.id])
    begin
      with_rate_limit_override(burst: 1_000, sustained: 3, tenant: 1_000_000) do
        3.times do |i|
          post_jsonrpc({ jsonrpc: "2.0", id: 300 + i, method: "ping" })
          assert_response :success
        end

        post_jsonrpc({ jsonrpc: "2.0", id: 400, method: "ping" })
        assert_response :too_many_requests
        assert_equal "60", response.headers["Retry-After"]
      end
    ensure
      clear_mcp_rate_limit_keys(token_ids: [@api_token.id])
    end
  end

  test "per-principal limit returns 429 when one principal exceeds it across their agents" do
    # Same human principal owns two agents; sum of their calls hits the
    # principal limit even though no individual agent hits the per-token cap.
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    second_agent = create_ai_agent(parent: @user, name: "Sibling Agent #{SecureRandom.hex(2)}",
                                   agent_configuration: { "mode" => "external" })
    @tenant.add_user!(second_agent)
    second_token = ApiToken.create!(tenant: @tenant, user: second_agent, scopes: ApiToken.valid_scopes)
    Tenant.clear_thread_scope

    clear_mcp_rate_limit_keys(token_ids: [@api_token.id, second_token.id])
    # Also clear the principal key
    Sidekiq.redis { |c| c.del("rate_limit:mcp/principal:#{@user.id}") }

    begin
      with_rate_limit_override(burst: 1_000, sustained: 1_000, principal: 3, tenant: 1_000_000) do
        2.times do |i|
          post_jsonrpc({ jsonrpc: "2.0", id: 900 + i, method: "ping" })
          assert_response :success
        end
        post_jsonrpc({ jsonrpc: "2.0", id: 902, method: "ping" },
                     headers: auth_headers(token: second_token.plaintext_token))
        assert_response :success

        # 4th call by either agent busts the principal limit
        post_jsonrpc({ jsonrpc: "2.0", id: 903, method: "ping" })
        assert_response :too_many_requests
        assert_match(/mcp\/principal/, response.parsed_body["error"]["message"])
      end
    ensure
      clear_mcp_rate_limit_keys(token_ids: [@api_token.id, second_token.id])
      Sidekiq.redis { |c| c.del("rate_limit:mcp/principal:#{@user.id}") }
    end
  end

  test "tenant-level limit honors per-tenant settings override" do
    # A tenant with a custom mcp_aggregate_rate_limit_per_minute uses that
    # value instead of the controller's default.
    isolated_tenant = create_tenant(subdomain: "rl-override-#{SecureRandom.hex(4)}")
    isolated_tenant.enable_api!
    isolated_tenant.settings["mcp_aggregate_rate_limit_per_minute"] = 2
    isolated_tenant.save!

    isolated_user = create_user
    isolated_tenant.add_user!(isolated_user)
    Tenant.scope_thread_to_tenant(subdomain: isolated_tenant.subdomain)
    isolated_collective = create_collective(tenant: isolated_tenant, created_by: isolated_user)
    isolated_collective.enable_api!
    isolated_collective.add_user!(isolated_user)
    agent = create_ai_agent(parent: isolated_user, name: "Override Agent",
                            agent_configuration: { "mode" => "external" })
    isolated_tenant.add_user!(agent)
    token = ApiToken.create!(tenant: isolated_tenant, user: agent, scopes: ApiToken.valid_scopes)
    Tenant.clear_thread_scope

    host! "#{isolated_tenant.subdomain}.#{ENV.fetch("HOSTNAME", nil)}"

    begin
      # Class default would be 6_000; override is 2. With per-token and
      # per-principal high, the tenant override is what trips.
      with_rate_limit_override(burst: 1_000, sustained: 1_000, principal: 1_000) do
        2.times do |i|
          post_jsonrpc({ jsonrpc: "2.0", id: 1000 + i, method: "ping" },
                       headers: auth_headers(token: token.plaintext_token))
          assert_response :success
        end

        post_jsonrpc({ jsonrpc: "2.0", id: 1002, method: "ping" },
                     headers: auth_headers(token: token.plaintext_token))
        assert_response :too_many_requests
        assert_match(/mcp\/tenant/, response.parsed_body["error"]["message"])
      end
    ensure
      clear_mcp_rate_limit_keys(token_ids: [token.id], tenant_ids: [isolated_tenant.id])
      Sidekiq.redis { |c| c.del("rate_limit:mcp/principal:#{isolated_user.id}") }
    end
  end

  test "per-tenant aggregate limit returns 429 when exceeded across multiple tokens" do
    # Fresh tenant so this test's tenant counter isn't shared with the parallel
    # /mcp tests using @global_tenant.
    isolated_tenant = create_tenant(subdomain: "rl-tenant-#{SecureRandom.hex(4)}")
    isolated_tenant.enable_api!
    isolated_user = create_user
    isolated_tenant.add_user!(isolated_user)
    Tenant.scope_thread_to_tenant(subdomain: isolated_tenant.subdomain)
    isolated_collective = create_collective(tenant: isolated_tenant, created_by: isolated_user)
    isolated_collective.enable_api!
    isolated_collective.add_user!(isolated_user)
    agent_one = create_ai_agent(parent: isolated_user, name: "Agent One",
                                agent_configuration: { "mode" => "external" })
    agent_two = create_ai_agent(parent: isolated_user, name: "Agent Two",
                                agent_configuration: { "mode" => "external" })
    isolated_tenant.add_user!(agent_one)
    isolated_tenant.add_user!(agent_two)
    token_one = ApiToken.create!(tenant: isolated_tenant, user: agent_one, scopes: ApiToken.valid_scopes)
    token_two = ApiToken.create!(tenant: isolated_tenant, user: agent_two, scopes: ApiToken.valid_scopes)
    Tenant.clear_thread_scope

    host! "#{isolated_tenant.subdomain}.#{ENV.fetch("HOSTNAME", nil)}"

    begin
      with_rate_limit_override(burst: 1_000, sustained: 1_000, tenant: 3) do
        2.times do |i|
          post_jsonrpc({ jsonrpc: "2.0", id: 500 + i, method: "ping" },
                       headers: auth_headers(token: token_one.plaintext_token))
          assert_response :success
        end
        post_jsonrpc({ jsonrpc: "2.0", id: 502, method: "ping" },
                     headers: auth_headers(token: token_two.plaintext_token))
        assert_response :success

        post_jsonrpc({ jsonrpc: "2.0", id: 503, method: "ping" },
                     headers: auth_headers(token: token_one.plaintext_token))
        assert_response :too_many_requests
      end
    ensure
      clear_mcp_rate_limit_keys(token_ids: [token_one.id, token_two.id],
                                tenant_ids: [isolated_tenant.id])
    end
  end

  test "rate-limited request writes to SecurityAuditLog with scope, token, tenant, user, ip" do
    clear_mcp_rate_limit_keys(token_ids: [@api_token.id])
    captured = []
    SecurityAuditLog.stub(:log_mcp_rate_limited, ->(**kwargs) { captured << kwargs }) do
      with_rate_limit_override(burst: 1, sustained: 1_000, tenant: 1_000_000) do
        post_jsonrpc({ jsonrpc: "2.0", id: 700, method: "ping" })
        assert_response :success
        post_jsonrpc({ jsonrpc: "2.0", id: 701, method: "ping" })
        assert_response :too_many_requests
      end
    end

    assert_equal 1, captured.size
    event = captured.first
    assert_equal "mcp/burst", event[:scope]
    assert_equal @tenant.id, event[:tenant_id]
    assert_equal @api_token.id, event[:token_id]
    assert_equal @agent.id, event[:user_id]
    assert_equal @user.id, event[:principal_id], "principal_id should be the agent's parent user"
    assert event[:request_id].present?
  ensure
    clear_mcp_rate_limit_keys(token_ids: [@api_token.id])
  end

  test "rate-limited request response message names the breached scope" do
    clear_mcp_rate_limit_keys(token_ids: [@api_token.id])
    begin
      with_rate_limit_override(burst: 1, sustained: 1_000, tenant: 1_000_000) do
        post_jsonrpc({ jsonrpc: "2.0", id: 800, method: "ping" })
        post_jsonrpc({ jsonrpc: "2.0", id: 801, method: "ping" })
        assert_response :too_many_requests
        assert_match(/mcp\/burst/, response.parsed_body["error"]["message"])
      end
    ensure
      clear_mcp_rate_limit_keys(token_ids: [@api_token.id])
    end
  end

  test "rate-limited request is not audited (mechanism kicks in before tool dispatch)" do
    clear_mcp_rate_limit_keys(token_ids: [@api_token.id])
    begin
      with_rate_limit_override(burst: 1, sustained: 1_000, tenant: 1_000_000) do
        post_jsonrpc({
                       jsonrpc: "2.0", id: 600, method: "tools/call",
                       params: { name: "fetch_page", arguments: { path: "/whoami" } },
                     })
        assert_response :success

        assert_no_difference -> { McpToolCallLog.count } do
          post_jsonrpc({
                         jsonrpc: "2.0", id: 601, method: "tools/call",
                         params: { name: "fetch_page", arguments: { path: "/whoami" } },
                       })
          assert_response :too_many_requests
        end
      end
    ensure
      clear_mcp_rate_limit_keys(token_ids: [@api_token.id])
    end
  end

  test "request body over max_request_bytes returns 413 with a clean error" do
    huge_arg = "x" * (Mcp::EndpointController.max_request_bytes + 1_000)
    post_jsonrpc({
                   jsonrpc: "2.0", id: 1100, method: "tools/call",
                   params: { name: "search", arguments: { query: huge_arg } },
                 })

    assert_response :payload_too_large
    body = response.parsed_body
    assert_match(/exceeds/i, body["error"]["message"])
  end

  test "response body is capped at the configured max bytes and the truncation is visible" do
    huge_body = "x" * (Mcp::EndpointController.max_response_bytes + 2_000)
    fake_result = { content: huge_body, error: nil, path: "/whoami", actions: [] }

    fake_session = Object.new
    fake_session.define_singleton_method(:with_provided_token) { |_t, &blk| blk.call }
    fake_session.define_singleton_method(:navigate) { |_path| fake_result }
    fake_session.define_singleton_method(:set_path) { |_p| nil }
    fake_session.define_singleton_method(:execute_action) { |_n, _p| fake_result }

    MarkdownUiService.stub(:new, ->(**) { fake_session }) do
      post_jsonrpc({
                     jsonrpc: "2.0", id: 700, method: "tools/call",
                     params: { name: "fetch_page", arguments: { path: "/whoami" } },
                   })
    end

    assert_response :success
    body = response.parsed_body
    text = body.dig("result", "content", 0, "text")
    assert text.bytesize <= Mcp::EndpointController.max_response_bytes,
           "response text should be capped (got #{text.bytesize} bytes)"
    assert_match(/truncated/i, text, "truncation marker should be visible in the output")
  end

  # ====================
  # Resource attribution
  #
  # Every MCP execute_action call that creates or touches a resource writes an
  # McpToolCallResource row tied to the parent McpToolCallLog. action_name is
  # the literal action invoked (create_note, etc.). Behavior is gated on
  # Current.mcp_tool_call_log_id being set by the endpoint controller, which
  # the create-then-update lifecycle in handle_tools_call guarantees.
  # ====================

  test "execute_action create_note writes an McpToolCallResource linked to the log row" do
    assert_difference -> { McpToolCallResource.count }, 1 do
      post_jsonrpc({
                     jsonrpc: "2.0", id: 800, method: "tools/call",
                     params: {
                       name: "execute_action",
                       arguments: {
                         path: "/collectives/#{@collective.handle}/note",
                         action: "create_note",
                         params: { text: "attribution test note" },
                       },
                     },
                   })
    end

    log = McpToolCallLog.order(:created_at).last
    row = McpToolCallResource.order(:created_at).last
    assert_equal log, row.mcp_tool_call_log
    assert_equal "create_note", row.action_name
    assert_kind_of Note, row.resource
    assert_equal "attribution test note", row.resource.text
    assert_equal @collective, row.resource_collective
  end

  test "execute_action that touches a resource (confirm_read) writes attribution" do
    note = create_note(tenant: @tenant, collective: @collective, created_by: @user)

    assert_difference -> { McpToolCallResource.count }, 1 do
      post_jsonrpc({
                     jsonrpc: "2.0", id: 801, method: "tools/call",
                     params: {
                       name: "execute_action",
                       arguments: {
                         path: "/collectives/#{@collective.handle}/n/#{note.truncated_id}",
                         action: "confirm_read",
                         params: {},
                       },
                     },
                   })
    end

    row = McpToolCallResource.order(:created_at).last
    assert_equal "confirm_read", row.action_name
    assert_kind_of NoteHistoryEvent, row.resource
  end

  test "fetch_page does not write McpToolCallResource (no resource touched)" do
    assert_no_difference -> { McpToolCallResource.count } do
      post_jsonrpc({
                     jsonrpc: "2.0", id: 802, method: "tools/call",
                     params: { name: "fetch_page", arguments: { path: "/whoami" } },
                   })
    end
  end

  test "execute_action with no task-run context writes McpToolCallResource only (not AiAgentTaskRunResource)" do
    assert_difference -> { McpToolCallResource.count }, 1 do
      assert_no_difference -> { AiAgentTaskRunResource.count } do
        post_jsonrpc({
                       jsonrpc: "2.0", id: 803, method: "tools/call",
                       params: {
                         name: "execute_action",
                         arguments: {
                           path: "/collectives/#{@collective.handle}/note",
                           action: "create_note",
                           params: { text: "external-only attribution" },
                         },
                       },
                     })
      end
    end
  end

  test "rapid-fire execute_action across calls writes one McpToolCallResource per call sharing the right log_id" do
    3.times do |i|
      post_jsonrpc({
                     jsonrpc: "2.0", id: 810 + i, method: "tools/call",
                     params: {
                       name: "execute_action",
                       arguments: {
                         path: "/collectives/#{@collective.handle}/note",
                         action: "create_note",
                         params: { text: "rapid note #{i}" },
                       },
                     },
                   })
    end

    logs = McpToolCallLog.order(:created_at).last(3)
    assert_equal 3, logs.size
    logs.each do |log|
      rows = McpToolCallResource.where(mcp_tool_call_log_id: log.id).to_a
      assert_equal 1, rows.size, "expected one row per log, got #{rows.size} for #{log.id}"
    end
  end

  test "tool_error execute_action does not write McpToolCallResource (no resource created)" do
    assert_no_difference -> { McpToolCallResource.count } do
      post_jsonrpc({
                     jsonrpc: "2.0", id: 820, method: "tools/call",
                     params: {
                       name: "execute_action",
                       arguments: {
                         path: "/collectives/#{@collective.handle}/note",
                         action: "create_note",
                         params: {}, # missing required text → action fails
                       },
                     },
                   })
    end
  end

  # ====================
  # Task-run linkage and _meta exposure (Step B)
  #
  # When the calling token has a polymorphic context of AiAgentTaskRun
  # (i.e. it's an internal agent-runner ephemeral token), the log row gets
  # ai_agent_task_run_id stamped. Every tools/call response also carries
  # _meta.harmonic.tool_call_log_id so the agent-runner can plumb it into
  # AgentSessionStep rows for deep-linking.
  # ====================

  test "tools/call response includes _meta.harmonic.tool_call_log_id on success" do
    post_jsonrpc({
                   jsonrpc: "2.0", id: 900, method: "tools/call",
                   params: { name: "fetch_page", arguments: { path: "/whoami" } },
                 })

    body = response.parsed_body
    log = McpToolCallLog.order(:created_at).last
    assert_equal log.id, body.dig("result", "_meta", "harmonic", "tool_call_log_id")
  end

  test "tools/call response includes _meta.harmonic.tool_call_log_id on unknown tool" do
    post_jsonrpc({
                   jsonrpc: "2.0", id: 901, method: "tools/call",
                   params: { name: "no_such_tool", arguments: {} },
                 })

    body = response.parsed_body
    log = McpToolCallLog.order(:created_at).last
    assert_equal "unknown_tool", log.status
    assert_equal log.id, body.dig("result", "_meta", "harmonic", "tool_call_log_id")
  end

  test "log row stamps ai_agent_task_run_id when token context is an AiAgentTaskRun" do
    task_run = AiAgentTaskRun.create!(
      tenant: @tenant, ai_agent: @agent, initiated_by: @user,
      task: "test", max_steps: 5, status: "running"
    )
    @api_token.update!(context: task_run)

    post_jsonrpc({
                   jsonrpc: "2.0", id: 902, method: "tools/call",
                   params: { name: "fetch_page", arguments: { path: "/whoami" } },
                 })

    log = McpToolCallLog.order(:created_at).last
    assert_equal task_run.id, log.ai_agent_task_run_id
  end

  test "log row leaves ai_agent_task_run_id null when token has no task-run context" do
    # @api_token from setup has no context — represents an external client.
    post_jsonrpc({
                   jsonrpc: "2.0", id: 903, method: "tools/call",
                   params: { name: "fetch_page", arguments: { path: "/whoami" } },
                 })

    log = McpToolCallLog.order(:created_at).last
    assert_nil log.ai_agent_task_run_id
  end
end
