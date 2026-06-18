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
