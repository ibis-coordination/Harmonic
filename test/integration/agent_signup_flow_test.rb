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

  MD = { "Accept" => "text/markdown" }.freeze

  def fields(body)
    body.scan(/^- (\w+): (.+)$/).to_h
  end

  test "an agent signs up, their principal claims them, and the collected token works on /mcp" do
    agent = agent_session

    # The agent discovers the flow and starts a signup, with no credentials,
    # through the markdown UI: page, then the action its frontmatter lists.
    agent.get "/agent-signups", headers: MD
    assert_equal 200, agent.response.status
    assert_includes agent.response.body, "start_agent_signup"

    agent.post "/agent-signups/actions/start_agent_signup",
               params: { principal_email: @human.email, name: "Stickman", handle: "stickman-flow" }, headers: MD
    assert_equal 200, agent.response.status
    started = fields(agent.response.body)
    check_path = "#{started["signup_page"]}/actions/check_agent_signup"
    claim_path = URI.parse(started["claim_url"]).path

    agent.get started["signup_page"], headers: MD
    assert_includes agent.response.body, "check_agent_signup"

    agent.post check_path, params: { poll_secret: started["poll_secret"] }, headers: MD
    assert_equal "pending", fields(agent.response.body)["status"]

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

    # The agent's next check hands over the token, once.
    agent.post check_path, params: { poll_secret: started["poll_secret"] }, headers: MD
    ready = fields(agent.response.body)
    assert_equal "ready", ready["status"]
    assert_equal "stickman-flow", ready["handle"]

    agent.post check_path, params: { poll_secret: started["poll_secret"] }, headers: MD
    assert_equal "redeemed", fields(agent.response.body)["status"]

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
