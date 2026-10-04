# frozen_string_literal: true

require "test_helper"

# The whole agent signup flow over HTTP, with the agent and the human
# principal in separate sessions: the agent starts a signup, the principal
# claims it in a browser session, the agent collects a token, and that token
# works against /mcp.
class AgentSignupFlowTest < ActionDispatch::IntegrationTest
  MCP_PROTOCOL_VERSION = "2025-11-25"

  setup do
    @tenant = @global_tenant
    @tenant.enable_api!
    @global_collective.enable_api!
    @tenant.set_feature_flag!("external_ai_agents", true)
    @tenant.set_feature_flag!("agent_signup", true)
    @host = "#{@tenant.subdomain}.#{ENV.fetch("HOSTNAME", nil)}"
    host! @host

    @human = create_user(email: "principal-#{SecureRandom.hex(8)}@example.com", name: "Principal")
    @tenant.add_user!(@human)
    mark_activated!(@human)
  end

  def agent_session
    @agent_session ||= open_session.tap { |s| s.host!(@host) }
  end

  test "an agent signs up, their principal claims them, and the collected token works on /mcp" do
    agent = agent_session

    # The agent discovers the flow and starts a signup, with no credentials.
    agent.get "/agent-signups", headers: { "Accept" => "text/markdown" }
    assert_equal 200, agent.response.status

    agent.post "/agent-signups", params: { principal_email: @human.email, name: "Stickman", handle: "stickman-flow" }, as: :json
    assert_equal 201, agent.response.status
    started = agent.response.parsed_body
    status_path = URI.parse(started["status_url"]).path
    claim_path = URI.parse(started["claim_url"]).path

    agent.post status_path, params: { poll_secret: started["poll_secret"] }, as: :json
    assert_equal "pending", agent.response.parsed_body["status"]

    # The token-less agent cannot reach /mcp yet.
    agent.post "/mcp", params: { jsonrpc: "2.0", id: 1, method: "initialize", params: {} }.to_json,
                       headers: { "Content-Type" => "application/json", "MCP-Protocol-Version" => MCP_PROTOCOL_VERSION }
    assert_equal 401, agent.response.status

    # The principal claims in their own browser session.
    sign_in_with_ai_agents_reverify(@human)
    get claim_path
    assert_response :success

    post claim_path, params: { name: "Stickman", handle: "stickman-flow", pairing_code: started["pairing_code"] }
    assert_redirected_to "/ai-agents/stickman-flow"

    # The agent's next poll hands over the token, once.
    agent.post status_path, params: { poll_secret: started["poll_secret"] }, as: :json
    ready = agent.response.parsed_body
    assert_equal "ready", ready["status"]
    assert_equal "stickman-flow", ready["handle"]

    agent.post status_path, params: { poll_secret: started["poll_secret"] }, as: :json
    assert_equal({ "status" => "redeemed" }, agent.response.parsed_body)

    # The token is a working MCP credential for the new agent.
    agent.post URI.parse(ready["mcp_endpoint"]).path,
               params: { jsonrpc: "2.0", id: 1, method: "initialize", params: {} }.to_json,
               headers: {
                 "Authorization" => "Bearer #{ready["mcp_token"]}",
                 "Content-Type" => "application/json",
                 "Accept" => "application/json, text/event-stream",
                 "MCP-Protocol-Version" => MCP_PROTOCOL_VERSION,
               }
    assert_equal 200, agent.response.status
    assert_nil agent.response.parsed_body["error"]

    created = User.find_by(id: ApiToken.authenticate(ready["mcp_token"], tenant_id: @tenant.id).user_id)
    assert created.ai_agent?
    assert_equal @human.id, created.parent_id
  end
end
