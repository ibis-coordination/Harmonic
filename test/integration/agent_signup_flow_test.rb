# frozen_string_literal: true

require "test_helper"

# The whole agent signup flow over HTTP, with the agent and the human
# principal in separate sessions: the agent starts a signup, the principal
# claims it in a browser session, the agent collects a token, and that token
# works against /mcp. Once for a member, once for a human who has no account
# yet on an invite-only tenant.
class AgentSignupFlowTest < ActionDispatch::IntegrationTest
  include ActionMailer::TestHelper

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

    post claim_path, params: {
      name: "Stickman", handle: "stickman-flow", pairing_code: started["pairing_code"], confirm_responsibility: "1",
    }
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

  # What registering through the identity provider leaves behind: a human
  # with the typed email, unverified, without 2FA, a member of nothing.
  def register(email)
    user = create_user(email: email, name: "Newcomer")
    user.find_or_create_omni_auth_identity!
    user
  end

  def login_callback_as(user)
    derived_key = ActiveSupport::KeyGenerator.new(Rails.application.secret_key_base).generate_key("cross_subdomain_token", 32)
    cookies[:token] = ActiveSupport::MessageEncryptor.new(derived_key).encrypt_and_sign("#{@tenant.id}:#{user.id}:#{Time.current.to_i}")
    get "/login/callback"
  end

  test "a human with no account joins an invite-only tenant from the claim link, claims, and the agent connects" do
    @tenant.update!(settings: @tenant.settings.merge("require_invite" => true))
    invite = Invite.create!(tenant: @tenant, collective: @global_collective, created_by: @global_user,
                            code: SecureRandom.hex(8), expires_at: 1.week.from_now)
    email = "newcomer-#{SecureRandom.hex(8)}@example.com"
    agent = agent_session

    # The agent signs up, carrying the invite its principal was given.
    assert_enqueued_emails 1 do
      agent.post "/agent-signups/actions/start_agent_signup",
                 params: { principal_email: email, name: "Stickman", handle: "stickman-new", invite_code: invite.code }, headers: MD
    end
    assert_equal 200, agent.response.status
    started = fields(agent.response.body)
    check_path = "#{started["signup_page"]}/actions/check_agent_signup"
    claim_path = URI.parse(started["claim_url"]).path

    # The human opens the emailed link with no account: login, then register.
    get claim_path
    assert_redirected_to "/login"
    user = register(email)
    login_callback_as(user)
    follow_redirect! while response.redirect?
    assert_equal "/invite-required", request.path, "a non-member of an invite-only tenant joins first"
    assert_includes response.body, %(name="code" value="#{invite.code}"), "the invite the signup carried is waiting"

    # Joining brings them back to the claim, which the activation gate holds
    # until their email is verified and 2FA is set up.
    post "/invite-required/accept", params: { code: invite.code }
    assert_redirected_to claim_path
    get claim_path
    assert_redirected_to "/activate"

    identity = user.omni_auth_identity
    raw_token = identity.send_email_confirmation!
    get "/confirm-email/#{raw_token}"
    assert_response :success

    get "/settings/two-factor"
    assert_response :success
    secret = user.omni_auth_identity.reload.otp_secret
    post "/settings/two-factor/confirm", params: { code: ROTP::TOTP.new(secret).now }

    get "/activate"
    assert_redirected_to claim_path

    # Reverification (a fresh TOTP window: a code is good once), then the
    # claim itself.
    travel 1.minute
    get claim_path
    assert_redirected_to "/reverify"
    post "/reverify", params: { code: ROTP::TOTP.new(secret).now }
    get claim_path
    assert_response :success
    assert_includes response.body, "Stickman"

    post claim_path, params: {
      name: "Stickman", handle: "stickman-new", pairing_code: started["pairing_code"], confirm_responsibility: "1",
    }
    assert_redirected_to "/ai-agents/stickman-new"

    # The agent collects the token and it works on /mcp.
    agent.post check_path, params: { poll_secret: started["poll_secret"] }, headers: MD
    ready = fields(agent.response.body)
    assert_equal "ready", ready["status"]

    agent.post URI.parse(ready["mcp_endpoint"]).path,
               params: { jsonrpc: "2.0", id: 1, method: "initialize", params: {} }.to_json,
               headers: {
                 "Authorization" => "Bearer #{ready["mcp_token"]}",
                 "Content-Type" => "application/json",
                 "Accept" => "application/json, text/event-stream",
                 "MCP-Protocol-Version" => MCP_PROTOCOL_VERSION,
               }
    assert_equal 200, agent.response.status

    created = User.find_by(id: ApiToken.authenticate(ready["mcp_token"], tenant_id: @tenant.id).user_id)
    assert_equal user.id, created.parent_id
    assert @tenant.tenant_users.exists?(user: user)
    assert @global_collective.collective_members.exists?(user: user), "the invite's collective was joined too"
  end
end
