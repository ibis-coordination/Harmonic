# frozen_string_literal: true

require "test_helper"

class AgentSignupsControllerTest < ActionDispatch::IntegrationTest
  include ActionMailer::TestHelper

  MD = { "Accept" => "text/markdown" }.freeze
  START = "/agent-signups/actions/start_agent_signup"

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

  def start_signup(email: @human.email, name: "Stickman", handle: nil, headers: MD)
    post START, params: { principal_email: email, name: name, handle: handle }.compact, headers: headers
  end

  # The `- key: value` lines of an action result.
  def result_fields(body = response.body)
    body.scan(/^- (\w+): (.+)$/).to_h
  end

  def signups
    AgentSignup.tenant_scoped_only(@tenant.id)
  end

  # ---------- pages ----------

  test "GET /agent-signups describes the flow in markdown without a session and lists the start action" do
    get "/agent-signups", headers: MD

    assert_response :success
    assert_includes response.body, "start_agent_signup"
    assert_includes response.body, "principal_email"
    assert_includes response.body, "pairing_code"
    frontmatter = YAML.safe_load(response.body.split("---")[1], permitted_classes: [Time])
    assert_equal(["start_agent_signup"], frontmatter["actions"].map { |a| a["name"] })
  end

  test "GET /agent-signups renders an HTML page without a session" do
    get "/agent-signups"

    assert_response :success
    assert_includes response.body, "principal_email"
  end

  test "GET /agent-signups is not found when agent signup is off" do
    @tenant.set_feature_flag!("agent_signup", false)

    get "/agent-signups", headers: MD

    assert_response :not_found
  end

  test "GET /agent-signups is not found when external agents are off" do
    @tenant.set_feature_flag!("external_ai_agents", false)

    get "/agent-signups", headers: MD

    assert_response :not_found
  end

  test "the actions index and the action descriptions follow the markdown action pattern" do
    get "/agent-signups/actions", headers: MD
    assert_response :success
    assert_includes response.body, "/agent-signups/actions/start_agent_signup"

    get START, headers: MD
    assert_response :success
    assert_includes response.body, "# Action: `start_agent_signup`"
    assert_includes response.body, "principal_email"

    signup = model_signup
    get "/agent-signups/#{signup.public_id}/actions", headers: MD
    assert_response :success
    assert_includes response.body, "/agent-signups/#{signup.public_id}/actions/check_agent_signup"

    get "/agent-signups/#{signup.public_id}/actions/check_agent_signup", headers: MD
    assert_response :success
    assert_includes response.body, "# Action: `check_agent_signup`"
    assert_includes response.body, "poll_secret"
  end

  test "a signup's page lists the check action and reveals nothing about the signup" do
    signup = model_signup

    get "/agent-signups/#{signup.public_id}", headers: MD
    real = response.body
    assert_response :success
    assert_includes real, "check_agent_signup"
    assert_not_includes real, "Stickman"

    get "/agent-signups/no-such-signup", headers: MD
    assert_response :success
    strip = ->(body, id) { body.gsub(id, "ID").gsub(/^timestamp: .*$/, "") }
    assert_equal strip.call(real, signup.public_id), strip.call(response.body, "no-such-signup")
  end

  # ---------- start ----------

  test "start_agent_signup creates a signup and returns the agent's credentials as markdown" do
    assert_difference -> { signups.count }, 1 do
      start_signup
    end

    assert_response :success
    assert_equal "text/markdown", response.media_type
    assert_includes response.body, "# Action Success: `start_agent_signup`"
    fields = result_fields
    signup = signups.order(:created_at).last

    assert_equal "pending", fields["status"]
    assert_match(/\A\d{6}\z/, fields["pairing_code"])
    assert signup.poll_secret_matches?(fields["poll_secret"])
    assert_equal "https://#{@tenant.subdomain}.#{ENV.fetch("HOSTNAME", nil)}/agent-signups/#{signup.public_id}/claim", fields["claim_url"]
    assert_equal "/agent-signups/#{signup.public_id}", fields["signup_page"]
    assert_equal signup.expires_at.iso8601, fields["expires_at"]
    assert_equal @human.id, signup.principal_user_id
    assert_equal "Stickman", signup.proposed_name
  end

  test "start_agent_signup answers in markdown whatever the Accept header, and takes a JSON body" do
    post START, params: { principal_email: @human.email, name: "Stickman" }, as: :json

    assert_response :success
    assert_equal "text/markdown", response.media_type
    assert_equal "pending", result_fields["status"]
  end

  test "start_agent_signup emails the principal a claim link when the email matches a member" do
    assert_enqueued_emails 1 do
      start_signup
    end
  end

  test "start_agent_signup sends nothing when the email matches no eligible member" do
    assert_no_enqueued_emails do
      start_signup(email: "nobody-#{SecureRandom.hex(4)}@example.com")
    end

    assert_response :success
    assert_nil signups.order(:created_at).last.principal_user_id
  end

  test "start_agent_signup responds the same way whether or not the email matched" do
    start_signup
    matched_status = response.status
    matched = response.body

    start_signup(email: "nobody-#{SecureRandom.hex(4)}@example.com")
    unmatched = response.body

    blank = lambda do |body|
      body.gsub(/^- (claim_url|signup_page|pairing_code|poll_secret|expires_at): .+$/, '- \1: X')
        .gsub(%r{/agent-signups/[\w-]+}, "/agent-signups/ID").gsub(/^timestamp: .*$/, "")
    end
    assert_equal matched_status, response.status
    assert_equal blank.call(matched), blank.call(unmatched)
    assert_equal result_fields(matched)["poll_secret"].length, result_fields(unmatched)["poll_secret"].length
  end

  test "start_agent_signup accepts a proposed handle" do
    start_signup(handle: "stickman")

    assert_response :success
    assert_equal "stickman", signups.order(:created_at).last.proposed_handle
  end

  test "start_agent_signup is not found when agent signup is off" do
    @tenant.set_feature_flag!("agent_signup", false)

    assert_no_difference -> { signups.count } do
      start_signup
    end

    assert_response :not_found
  end

  test "start_agent_signup rejects a missing name, naming the expected field" do
    assert_no_difference -> { signups.count } do
      post START, params: { principal_email: @human.email }, headers: MD
    end

    assert_response :unprocessable_entity
    assert_includes response.body, "# Action Error: `start_agent_signup`"
    assert_match(/name is required/, response.body)
  end

  test "start_agent_signup rejects a name that is too long" do
    start_signup(name: "x" * (AgentSignup::MAX_NAME_LENGTH + 1))

    assert_response :unprocessable_entity
    assert_match(/name must be/, response.body)
  end

  test "start_agent_signup rejects a missing or malformed email" do
    post START, params: { name: "Stickman" }, headers: MD
    assert_response :unprocessable_entity
    assert_match(/principal_email is required/, response.body)

    start_signup(email: "not-an-email")
    assert_response :unprocessable_entity
    assert_match(/principal_email must be/, response.body)
  end

  test "start_agent_signup throttles repeated signups naming the same email" do
    AgentSignupsController::SIGNUPS_PER_EMAIL_PER_DAY.times do
      start_signup
      assert_response :success
    end

    assert_no_enqueued_emails do
      assert_no_difference -> { signups.count } do
        start_signup(email: "  #{@human.email.upcase} ")
      end
    end

    assert_response :too_many_requests
  end

  test "start_agent_signup throttles unmatched emails the same way" do
    email = "nobody-#{SecureRandom.hex(4)}@example.com"
    AgentSignupsController::SIGNUPS_PER_EMAIL_PER_DAY.times { start_signup(email: email) }

    start_signup(email: email)

    assert_response :too_many_requests
  end

  # ---------- check and pickup ----------

  def check(signup, secret: signup.poll_secret)
    post "/agent-signups/#{signup.public_id}/actions/check_agent_signup", params: { poll_secret: secret }.compact, headers: MD
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

  test "check_agent_signup is pending until the principal claims" do
    signup = model_signup

    check(signup)

    assert_response :success
    assert_includes response.body, "# Action Success: `check_agent_signup`"
    assert_equal({ "status" => "pending" }, result_fields)
  end

  test "check_agent_signup for a signup that matched no member is also pending" do
    signup = model_signup(email: "nobody-#{SecureRandom.hex(4)}@example.com")
    check(signup)
    unmatched = response.body

    check(model_signup)

    assert_equal({ "status" => "pending" }, result_fields(unmatched))
    strip = ->(body) { body.gsub(%r{/agent-signups/[\w-]+}, "/agent-signups/ID").gsub(/^timestamp: .*$/, "") }
    assert_equal strip.call(response.body), strip.call(unmatched)
  end

  test "check_agent_signup is not found for a wrong, missing or foreign poll secret" do
    signup = model_signup
    other = model_signup

    check(signup, secret: "wrong")
    assert_response :not_found

    check(signup, secret: nil)
    assert_response :not_found

    check(signup, secret: other.poll_secret)
    assert_response :not_found
  end

  test "check_agent_signup is not found for an unknown signup" do
    post "/agent-signups/does-not-exist/actions/check_agent_signup", params: { poll_secret: "anything" }, headers: MD

    assert_response :not_found
  end

  test "check_agent_signup is not found when agent signup is off" do
    signup = model_signup
    @tenant.set_feature_flag!("agent_signup", false)

    check(signup)

    assert_response :not_found
  end

  test "check_agent_signup reports declined and expired" do
    declined = model_signup
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    declined.decline!
    Tenant.clear_thread_scope
    check(declined)
    assert_equal "declined", result_fields["status"]

    lapsed = model_signup
    travel 25.hours do
      check(lapsed)
      assert_equal "expired", result_fields["status"]
    end
  end

  test "check_agent_signup hands over the MCP token once the agent is claimed" do
    signup = model_signup
    agent = claim!(signup)

    assert_difference -> { tokens_for(agent).count }, 1 do
      check(signup)
    end

    assert_response :success
    fields = result_fields
    assert_equal "ready", fields["status"]
    assert_equal "https://#{@tenant.subdomain}.#{ENV.fetch("HOSTNAME", nil)}/mcp", fields["mcp_endpoint"]
    assert_equal agent.tenant_users.find_by(tenant_id: @tenant.id).handle, fields["handle"]

    token = ApiToken.authenticate(fields["mcp_token"], tenant_id: @tenant.id)
    assert_equal agent.id, token.user_id
    assert token.mcp_type?
  end

  test "check_agent_signup returns the token only once" do
    signup = model_signup
    agent = claim!(signup)
    check(signup)

    assert_no_difference -> { tokens_for(agent).count } do
      check(signup)
    end

    assert_response :success
    assert_equal({ "status" => "redeemed" }, result_fields)
  end

  test "check_agent_signup withholds the token while the agent waits on billing" do
    signup = model_signup
    agent = claim!(signup)
    agent.update!(pending_billing_setup: true)

    assert_no_difference -> { tokens_for(agent).count } do
      check(signup)
    end

    assert_equal({ "status" => "claimed_awaiting_billing" }, result_fields)
  end

  test "check_agent_signup withholds the token once the pickup window has lapsed, and says not to start again" do
    signup = model_signup
    agent = claim!(signup)

    travel 25.hours do
      assert_no_difference -> { tokens_for(agent).count } do
        check(signup)
      end
      assert_equal({ "status" => "pickup_window_closed" }, result_fields)
      assert_includes response.body, "Do not start again"
    end
  end

  # ---------- discovery from help and /mcp ----------

  test "help pages point to agent signup only where it is on" do
    @tenant.enable_api! # /help/mcp exists only where the API is on
    sign_in_as(@human, tenant: @tenant)

    get "/help/agents", headers: MD
    assert_includes response.body, "/agent-signups"
    get "/help/mcp", headers: MD
    assert_includes response.body, "/agent-signups"

    @tenant.set_feature_flag!("agent_signup", false)

    get "/help/agents", headers: MD
    assert_not_includes response.body, "/agent-signups"
    get "/help/mcp", headers: MD
    assert_not_includes response.body, "/agent-signups"
  end

  test "an unauthorized /mcp request points to agent signup only where it is on" do
    mcp_headers = { "Content-Type" => "application/json", "MCP-Protocol-Version" => "2025-11-25" }
    body = { jsonrpc: "2.0", id: 1, method: "initialize", params: {} }.to_json

    post "/mcp", params: body, headers: mcp_headers
    assert_response :unauthorized
    assert_includes response.parsed_body.dig("error", "message"), "/agent-signups"

    @tenant.set_feature_flag!("agent_signup", false)

    post "/mcp", params: body, headers: mcp_headers
    assert_response :unauthorized
    assert_equal "Unauthorized", response.parsed_body.dig("error", "message")
  end
  # ---------- who may call ----------

  test "an agent who already has a token is refused, since they already have an account" do
    @tenant.enable_api!
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    agent = create_ai_agent(parent: @human, name: "Existing", agent_configuration: { "mode" => "external" })
    @tenant.add_user!(agent)
    token = ApiToken.create!(tenant: @tenant, user: agent, scopes: ApiToken.valid_scopes, token_type: "rest")
    Tenant.clear_thread_scope

    assert_no_difference -> { signups.count } do
      post START, params: { principal_email: @human.email, name: "Second Self" },
                  headers: MD.merge("Authorization" => "Bearer #{token.plaintext_token}")
    end

    assert_response :forbidden
  end

  test "a logged-in human may start a signup like anyone else" do
    sign_in_as(@human, tenant: @tenant)

    assert_difference -> { signups.count }, 1 do
      start_signup
    end

    assert_response :success
  end

  test "signup works without an account on a login-optional tenant too" do
    @tenant.settings["require_login"] = false
    @tenant.save!

    assert_difference -> { signups.count }, 1 do
      start_signup
    end
    assert_response :success
  ensure
    @tenant.settings["require_login"] = true
    @tenant.save!
  end

  test "the privacy help page names agent signup as open to callers with no account, only where it is on" do
    sign_in_as(@human, tenant: @tenant)

    get "/help/privacy", headers: MD
    assert_includes response.body, "/agent-signups"

    @tenant.set_feature_flag!("agent_signup", false)
    get "/help/privacy", headers: MD
    assert_not_includes response.body, "/agent-signups"
  end
end
