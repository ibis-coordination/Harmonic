require "test_helper"

# The ActionContextValidation concern is included in ApplicationController and
# runs via `append_before_action`. It MUST short-circuit cleanly for any
# request that isn't an MCP execute_action dispatch by a restricted (AI agent)
# user — otherwise it would 422 every write across the app.
#
# These tests pin those bypass paths so a regression that removes a guard
# can't go undetected.
class ActionContextValidationTest < ActionDispatch::IntegrationTest
  def setup
    @tenant = @global_tenant
    @tenant.enable_api!
    @collective = @global_collective
    @collective.enable_api!
    @user = @global_user
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    host! "#{@tenant.subdomain}.#{ENV.fetch("HOSTNAME", nil)}"
  end

  test "human users writing via direct REST are not gated by the context validation" do
    # The concern fires only for AI agents under MCP dispatch. A human
    # session-authenticated user writing via direct REST should be unaffected
    # — no `context` declared, but no 422 either.
    sign_in_as(@user, tenant: @tenant)

    assert_difference -> { Note.count }, 1 do
      post "/collectives/#{@collective.handle}/note/actions/create_note",
           params: { text: "human direct REST write" }.to_json,
           headers: { "Content-Type" => "application/json", "Accept" => "text/markdown" }
    end
    assert_response :success
  end

  test "AI agents writing via direct REST are blocked by mcp_only, not by context validation" do
    # Agent tokens default to mcp_only:true. A direct REST hit gets 403
    # "mcp_only" from api_authorize! BEFORE the concern's chain entry.
    # This pins the layered defense: mcp_only is the outer fence; context
    # validation is the inner gate that only fires under MCP dispatch.
    agent = create_ai_agent(parent: @user, name: "Direct-REST Test Agent",
                            agent_configuration: { "mode" => "external" })
    @tenant.add_user!(agent)
    @collective.add_user!(agent)
    token = ApiToken.create!(tenant: @tenant, user: agent, scopes: ApiToken.valid_scopes, mcp_only: true)

    post "/collectives/#{@collective.handle}/note/actions/create_note",
         params: { text: "should not land" }.to_json,
         headers: {
           "Content-Type" => "application/json",
           "Accept" => "text/markdown",
           "Authorization" => "Bearer #{token.plaintext_token}",
         }

    # The mcp_only fence fires first — agent never reaches the concern.
    assert_response :forbidden
    body = response.parsed_body
    assert_equal "mcp_only", body["error"]
  end

  test "AI agent under MCP execute_action with declared-vs-resolved visibility mismatch gets 422 (positive case)" do
    # The bypass tests above pin paths that should NOT trigger the concern.
    # This one pins the path that SHOULD trigger it: an AI agent dispatching
    # via /mcp with a declared visibility that doesn't match the resolved
    # audience. Without this, removing `restricted_user?` or `write_request?`
    # would leave all three bypass tests green — the file would falsely claim
    # to "pin the guards" while the inner gate could be unwired entirely.
    agent = create_ai_agent(parent: @user, name: "MCP Mismatch Agent",
                            agent_configuration: { "mode" => "external" })
    @tenant.add_user!(agent)
    @collective.add_user!(agent)
    token = ApiToken.create!(tenant: @tenant, user: agent, scopes: ApiToken.valid_scopes, mcp_only: true)

    # @collective is non-main → resolves to "shared"; declaring "public" mismatches.
    body = {
      jsonrpc: "2.0",
      id: 1,
      method: "tools/call",
      params: {
        name: "execute_action",
        arguments: {
          path: "/collectives/#{@collective.handle}/note",
          action: "create_note",
          params: { text: "should be blocked" },
          context: {
            identity: { actor: "@#{agent.handle}" },
            visibility: "public",
            intention: "write a note",
          },
        },
      },
    }.to_json

    assert_no_difference -> { Note.count } do
      post "/mcp", params: body, headers: {
        "Content-Type" => "application/json",
        "Accept" => "application/json",
        "Authorization" => "Bearer #{token.plaintext_token}",
      }
    end

    assert_response :success # JSON-RPC envelopes the 422 in a tool error
    inner = response.parsed_body.dig("result", "content", 0, "text")
    parsed_inner = JSON.parse(inner.to_s)
    assert_equal "visibility_mismatch", parsed_inner["error"]
    assert_equal "shared", parsed_inner["expected"]
    assert_equal "public", parsed_inner["got"]
  end

  # --- Visibility-zone guardrails -----------------------------------------
  #
  # The zone gate sits right after audience resolution in the same concern,
  # using the resolved audience as ground truth. These pin the three gate
  # paths an integration test can reach: public denied by default, public
  # allowed once granted, shared allowed by default. (private-always-allowed
  # is exhaustively covered at the unit level in capability_check_test.)

  def post_create_note_via_mcp(collective:, declared_visibility:, token:)
    body = {
      jsonrpc: "2.0",
      id: 1,
      method: "tools/call",
      params: {
        name: "execute_action",
        arguments: {
          path: "/collectives/#{collective.handle}/note",
          action: "create_note",
          params: { text: "zone gate test" },
          context: {
            identity: { actor: "@#{token.user.handle}" },
            visibility: declared_visibility,
            intention: "write a note",
          },
        },
      },
    }.to_json

    post "/mcp", params: body, headers: {
      "Content-Type" => "application/json",
      "Accept" => "application/json",
      "Authorization" => "Bearer #{token.plaintext_token}",
    }
  end

  def mcp_inner_error(response)
    inner = response.parsed_body.dig("result", "content", 0, "text")
    JSON.parse(inner.to_s)
  end

  test "AI agent is denied a public-zone action by default (public off unless granted)" do
    main = @tenant.main_collective
    main.enable_api!
    agent = create_ai_agent(parent: @user, name: "Zone Default Agent",
                            agent_configuration: { "mode" => "external" })
    @tenant.add_user!(agent)
    main.add_user!(agent)
    token = ApiToken.create!(tenant: @tenant, user: agent, scopes: ApiToken.valid_scopes, mcp_only: true)

    assert_no_difference -> { Note.count } do
      # main collective → resolves to "public"; declared correctly, but the
      # agent hasn't been granted the public zone.
      post_create_note_via_mcp(collective: main, declared_visibility: "public", token: token)
    end

    assert_response :success # JSON-RPC envelopes the 403 in a tool error
    parsed = mcp_inner_error(response)
    assert_equal "zone_restricted", parsed["error"]
    assert_equal "public", parsed["zone"]
  end

  test "AI agent granted the public zone may act there" do
    main = @tenant.main_collective
    main.enable_api!
    agent = create_ai_agent(parent: @user, name: "Zone Public Agent",
                            agent_configuration: { "mode" => "external", "visibility_zones" => ["public"] })
    @tenant.add_user!(agent)
    main.add_user!(agent)
    token = ApiToken.create!(tenant: @tenant, user: agent, scopes: ApiToken.valid_scopes, mcp_only: true)

    assert_difference -> { Note.count }, 1 do
      post_create_note_via_mcp(collective: main, declared_visibility: "public", token: token)
    end
    assert_response :success
  end

  test "AI agent may act in the shared zone by default" do
    # @collective is a non-main collective → resolves to "shared", which is
    # on by default. No visibility_zones configured.
    agent = create_ai_agent(parent: @user, name: "Zone Shared Agent",
                            agent_configuration: { "mode" => "external" })
    @tenant.add_user!(agent)
    @collective.add_user!(agent)
    token = ApiToken.create!(tenant: @tenant, user: agent, scopes: ApiToken.valid_scopes, mcp_only: true)

    assert_difference -> { Note.count }, 1 do
      post_create_note_via_mcp(collective: @collective, declared_visibility: "shared", token: token)
    end
    assert_response :success
  end

  test "non-agent token with mcp_only disabled bypasses the context gate but writes anyway (humans aren't restricted_users)" do
    # A human-owned API token (which CAN'T be mcp_only — model validation
    # pins mcp_only to ai_agent users). A direct REST write goes through
    # without context. ActionContextValidation runs but short-circuits at
    # `restricted_user?` — humans aren't restricted.
    token = ApiToken.create!(tenant: @tenant, user: @user, scopes: ApiToken.valid_scopes)

    assert_difference -> { Note.count }, 1 do
      post "/collectives/#{@collective.handle}/note/actions/create_note",
           params: { text: "human bearer-token write" }.to_json,
           headers: {
             "Content-Type" => "application/json",
             "Accept" => "text/markdown",
             "Authorization" => "Bearer #{token.plaintext_token}",
           }
    end
    assert_response :success
  end
end
