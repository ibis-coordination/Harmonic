# frozen_string_literal: true

require "test_helper"

class AgentSignupsControllerTest < ActionDispatch::IntegrationTest
  include ActionMailer::TestHelper

  setup do
    @tenant = @global_tenant
    host! "#{@tenant.subdomain}.#{ENV.fetch("HOSTNAME", nil)}"
    @tenant.set_feature_flag!("external_ai_agents", true)
    @tenant.set_feature_flag!("agent_signup", true)
    # A member with a fresh email per test: the per-email throttle counts in
    # Redis, which is shared across parallel test workers and outlives the
    # test's database transaction.
    @human = create_user(email: "principal-#{SecureRandom.hex(8)}@example.com", name: "Principal")
    @tenant.add_user!(@human)
    mark_activated!(@human)
  end

  def start_signup(email: @human.email, name: "Stickman", handle: nil)
    post "/agent-signups",
         params: { principal_email: email, name: name, handle: handle }.compact,
         as: :json
  end

  def signups
    AgentSignup.tenant_scoped_only(@tenant.id)
  end

  # ---------- discovery page ----------

  test "GET /agent-signups describes the flow in markdown without a session" do
    get "/agent-signups", headers: { "Accept" => "text/markdown" }

    assert_response :success
    assert_includes response.body, "POST /agent-signups"
    assert_includes response.body, "principal_email"
    assert_includes response.body, "pairing_code"
  end

  test "GET /agent-signups renders an HTML page without a session" do
    get "/agent-signups"

    assert_response :success
    assert_includes response.body, "principal_email"
  end

  test "GET /agent-signups is not found when agent signup is off" do
    @tenant.set_feature_flag!("agent_signup", false)

    get "/agent-signups", headers: { "Accept" => "text/markdown" }

    assert_response :not_found
  end

  test "GET /agent-signups is not found when external agents are off" do
    @tenant.set_feature_flag!("external_ai_agents", false)

    get "/agent-signups", headers: { "Accept" => "text/markdown" }

    assert_response :not_found
  end

  # ---------- start ----------

  test "POST /agent-signups creates a signup and returns the agent's credentials" do
    assert_difference -> { signups.count }, 1 do
      start_signup
    end

    assert_response :created
    body = response.parsed_body
    signup = signups.order(:created_at).last

    assert_equal "pending", body["status"]
    assert_match(/\A\d{6}\z/, body["pairing_code"])
    assert signup.poll_secret_matches?(body["poll_secret"])
    assert_equal "https://#{@tenant.subdomain}.#{ENV.fetch("HOSTNAME", nil)}/agent-signups/#{signup.public_id}/claim", body["claim_url"]
    assert_equal "https://#{@tenant.subdomain}.#{ENV.fetch("HOSTNAME", nil)}/agent-signups/#{signup.public_id}/status", body["status_url"]
    assert_equal signup.expires_at.iso8601, body["expires_at"]
    assert_equal @human.id, signup.principal_user_id
    assert_equal "Stickman", signup.proposed_name
  end

  test "POST /agent-signups emails the principal a claim link when the email matches a member" do
    assert_enqueued_emails 1 do
      start_signup
    end
  end

  test "POST /agent-signups sends nothing when the email matches no eligible member" do
    assert_no_enqueued_emails do
      start_signup(email: "nobody-#{SecureRandom.hex(4)}@example.com")
    end

    assert_response :created
    assert_nil signups.order(:created_at).last.principal_user_id
  end

  test "POST /agent-signups responds the same way whether or not the email matched" do
    start_signup
    matched_status = response.status
    matched = response.parsed_body

    start_signup(email: "nobody-#{SecureRandom.hex(4)}@example.com")
    unmatched = response.parsed_body

    assert_equal matched_status, response.status
    assert_equal matched.keys, unmatched.keys
    assert_equal matched["status"], unmatched["status"]
    assert_equal matched["next_steps"], unmatched["next_steps"]
    assert_equal matched["pairing_code"].length, unmatched["pairing_code"].length
    assert_equal matched["poll_secret"].length, unmatched["poll_secret"].length
  end

  test "POST /agent-signups accepts a proposed handle" do
    start_signup(handle: "stickman")

    assert_response :created
    assert_equal "stickman", signups.order(:created_at).last.proposed_handle
  end

  test "POST /agent-signups is not found when agent signup is off" do
    @tenant.set_feature_flag!("agent_signup", false)

    assert_no_difference -> { signups.count } do
      start_signup
    end

    assert_response :not_found
  end

  test "POST /agent-signups rejects a missing name, naming the expected field" do
    assert_no_difference -> { signups.count } do
      post "/agent-signups", params: { principal_email: @human.email }, as: :json
    end

    assert_response :unprocessable_entity
    assert_match(/name/, response.parsed_body["error"])
  end

  test "POST /agent-signups rejects a name that is too long" do
    start_signup(name: "x" * (AgentSignup::MAX_NAME_LENGTH + 1))

    assert_response :unprocessable_entity
    assert_match(/name/, response.parsed_body["error"])
  end

  test "POST /agent-signups rejects a missing or malformed email" do
    post "/agent-signups", params: { name: "Stickman" }, as: :json
    assert_response :unprocessable_entity
    assert_match(/principal_email/, response.parsed_body["error"])

    start_signup(email: "not-an-email")
    assert_response :unprocessable_entity
    assert_match(/principal_email/, response.parsed_body["error"])
  end

  test "POST /agent-signups throttles repeated signups naming the same email" do
    AgentSignupsController::SIGNUPS_PER_EMAIL_PER_DAY.times do
      start_signup
      assert_response :created
    end

    assert_no_enqueued_emails do
      assert_no_difference -> { signups.count } do
        start_signup(email: "  #{@human.email.upcase} ")
      end
    end

    assert_response :too_many_requests
  end

  test "POST /agent-signups throttles unmatched emails the same way" do
    email = "nobody-#{SecureRandom.hex(4)}@example.com"
    AgentSignupsController::SIGNUPS_PER_EMAIL_PER_DAY.times { start_signup(email: email) }

    start_signup(email: email)

    assert_response :too_many_requests
  end
  # ---------- status and pickup ----------

  def poll(signup, secret: signup.poll_secret)
    post "/agent-signups/#{signup.public_id}/status", params: { poll_secret: secret }.compact, as: :json
  end

  def model_signup(email: @human.email)
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    AgentSignup.start!(tenant: @tenant, principal_email: email, name: "Stickman", handle: "stickman")
  ensure
    Tenant.clear_thread_scope
  end

  def claim!(signup)
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    agent = create_ai_agent(parent: @human, name: "Stickman", agent_configuration: { "mode" => "external" })
    @tenant.add_user!(agent, handle: "stickman-#{SecureRandom.hex(3)}")
    signup.claim!(ai_agent: agent)
    agent
  ensure
    Tenant.clear_thread_scope
  end

  def tokens_for(agent)
    ApiToken.tenant_scoped_only(@tenant.id).where(user_id: agent.id)
  end

  test "status is pending until the principal claims" do
    signup = model_signup

    poll(signup)

    assert_response :success
    assert_equal({ "status" => "pending" }, response.parsed_body)
  end

  test "status for a signup that matched no member is also pending" do
    signup = model_signup(email: "nobody-#{SecureRandom.hex(4)}@example.com")

    poll(signup)

    assert_response :success
    assert_equal({ "status" => "pending" }, response.parsed_body)
  end

  test "status is not found for a wrong, missing or foreign poll secret" do
    signup = model_signup
    other = model_signup

    poll(signup, secret: "wrong")
    assert_response :not_found

    poll(signup, secret: nil)
    assert_response :not_found

    poll(signup, secret: other.poll_secret)
    assert_response :not_found
  end

  test "status is not found for an unknown signup" do
    post "/agent-signups/does-not-exist/status", params: { poll_secret: "anything" }, as: :json

    assert_response :not_found
  end

  test "status is not found when agent signup is off" do
    signup = model_signup
    @tenant.set_feature_flag!("agent_signup", false)

    poll(signup)

    assert_response :not_found
  end

  test "status reports declined and expired" do
    declined = model_signup
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    declined.decline!
    Tenant.clear_thread_scope
    poll(declined)
    assert_equal "declined", response.parsed_body["status"]

    lapsed = model_signup
    travel 25.hours do
      poll(lapsed)
      assert_equal "expired", response.parsed_body["status"]
    end
  end

  test "status hands over the MCP token once the agent is claimed" do
    signup = model_signup
    agent = claim!(signup)

    assert_difference -> { tokens_for(agent).count }, 1 do
      poll(signup)
    end

    assert_response :success
    body = response.parsed_body
    assert_equal "ready", body["status"]
    assert_equal "https://#{@tenant.subdomain}.#{ENV.fetch("HOSTNAME", nil)}/mcp", body["mcp_endpoint"]
    assert_equal agent.tenant_users.find_by(tenant_id: @tenant.id).handle, body["handle"]

    token = ApiToken.authenticate(body["mcp_token"], tenant_id: @tenant.id)
    assert_equal agent.id, token.user_id
    assert token.mcp_type?
  end

  test "status returns the token only once" do
    signup = model_signup
    agent = claim!(signup)
    poll(signup)

    assert_no_difference -> { tokens_for(agent).count } do
      poll(signup)
    end

    assert_response :success
    assert_equal({ "status" => "redeemed" }, response.parsed_body)
  end

  test "status withholds the token while the agent waits on billing" do
    signup = model_signup
    agent = claim!(signup)
    agent.update!(pending_billing_setup: true)

    assert_no_difference -> { tokens_for(agent).count } do
      poll(signup)
    end

    assert_equal({ "status" => "claimed_awaiting_billing" }, response.parsed_body)
  end

  test "status withholds the token once the pickup window has lapsed" do
    signup = model_signup
    agent = claim!(signup)

    travel 25.hours do
      assert_no_difference -> { tokens_for(agent).count } do
        poll(signup)
      end
      assert_equal({ "status" => "expired" }, response.parsed_body)
    end
  end
end
