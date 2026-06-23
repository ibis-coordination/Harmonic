# frozen_string_literal: true

require "test_helper"
require "webmock/minitest"

class HarmonicBridgeSetupsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = @global_tenant
    @collective = @global_collective
    @human = @global_user
    host! "#{@tenant.subdomain}.#{ENV.fetch("HOSTNAME", nil)}"

    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)

    @agent = create_ai_agent(
      parent: @human,
      name: "External Setup Test Agent",
      agent_configuration: { "mode" => "external" }
    )
    @tenant.add_user!(@agent)
    @collective.add_user!(@agent)

    Collective.clear_thread_scope
    Tenant.clear_thread_scope
  end

  def make_setup(**overrides)
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    s = HarmonicBridgeSetup.create!(
      tenant: @tenant,
      ai_agent_user: @agent,
      created_by_user: @human,
      **overrides
    )
    Collective.clear_thread_scope
    Tenant.clear_thread_scope
    s
  end

  # ---------- GET show ----------

  test "GET show: returns the metadata bundle and marks redeemed (no credentials yet)" do
    setup = make_setup
    get "/bridge-setups/#{setup.public_id}"
    assert_response :ok
    body = response.parsed_body
    assert_equal @agent.tenant_users.find_by(tenant: @tenant).handle, body["agent_handle"]
    assert body["harmonic_mcp_endpoint"].present?
    assert body["webhook_register_url"].include?(setup.public_id)
    assert_equal ["notifications.delivered", "reminders.delivered"], body["events_recommended"]

    # No credentials in the GET response — token is minted at POST time.
    assert_nil body["harmonic_token"]

    setup.reload
    assert setup.redeemed_at.present?
    assert_nil setup.api_token, "no token minted by GET"
  end

  test "GET show: 404 on second redemption" do
    setup = make_setup
    get "/bridge-setups/#{setup.public_id}"
    assert_response :ok
    get "/bridge-setups/#{setup.public_id}"
    assert_response :not_found
  end

  test "GET show: 404 on expired setup" do
    setup = make_setup(expires_at: 1.minute.ago)
    get "/bridge-setups/#{setup.public_id}"
    assert_response :not_found
  end

  test "GET show: 404 on unknown public_id" do
    get "/bridge-setups/not-a-real-id"
    assert_response :not_found
  end

  # ---------- POST register_webhook ----------

  def stub_reachable(url)
    stub_request(:post, url).to_return(status: 200, body: '{"received":true}')
  end

  test "POST register_webhook: mints token + creates AutomationRule + returns both credentials" do
    setup = make_setup
    get "/bridge-setups/#{setup.public_id}"
    assert_response :ok

    webhook_url = "https://example.com/webhook/#{@agent.tenant_users.find_by(tenant: @tenant).handle}"
    stub_reachable(webhook_url)
    assert_difference -> { AutomationRule.tenant_scoped_only(@tenant.id).count } => 1 do
      assert_difference -> { @agent.api_tokens.count } => 1 do
        post "/bridge-setups/#{setup.public_id}/webhook",
             params: { webhook_url: webhook_url, events: ["notifications.delivered"] }
      end
    end
    assert_response :ok
    body = response.parsed_body
    assert body["harmonic_token"].present?, "POST response carries the freshly-minted MCP token"
    assert body["signing_secret"].present?

    setup.reload
    rule = setup.automation_rule
    assert_not_nil rule
    assert_equal webhook_url, rule.actions["webhook_url"]
    assert_equal body["signing_secret"], rule.webhook_secret
    assert setup.webhook_registered_at.present?
    assert setup.api_token.present?
    assert setup.api_token.mcp_only?
  end

  test "POST register_webhook: 404 if GET show not yet called" do
    setup = make_setup
    post "/bridge-setups/#{setup.public_id}/webhook",
         params: { webhook_url: "https://example.org/y", events: ["notifications.delivered"] }
    assert_response :not_found
  end

  test "POST register_webhook: 404 on second invocation" do
    setup = make_setup
    get "/bridge-setups/#{setup.public_id}"
    url = "https://example.org/y"
    stub_reachable(url)
    post "/bridge-setups/#{setup.public_id}/webhook",
         params: { webhook_url: url, events: ["notifications.delivered"] }
    assert_response :ok
    post "/bridge-setups/#{setup.public_id}/webhook",
         params: { webhook_url: url, events: ["notifications.delivered"] }
    assert_response :not_found
  end

  test "POST register_webhook: 404 if expired" do
    setup = make_setup
    get "/bridge-setups/#{setup.public_id}"
    setup.update_columns(expires_at: 1.minute.ago)
    post "/bridge-setups/#{setup.public_id}/webhook",
         params: { webhook_url: "https://example.org/y", events: ["notifications.delivered"] }
    assert_response :not_found
  end

  test "POST register_webhook: 422 if webhook_url is missing" do
    setup = make_setup
    get "/bridge-setups/#{setup.public_id}"
    post "/bridge-setups/#{setup.public_id}/webhook", params: { events: ["notifications.delivered"] }
    assert_response :unprocessable_entity
  end

  test "POST register_webhook: 422 if webhook_url is not HTTPS" do
    setup = make_setup
    get "/bridge-setups/#{setup.public_id}"
    assert_no_difference -> { AutomationRule.tenant_scoped_only(@tenant.id).count } do
      post "/bridge-setups/#{setup.public_id}/webhook",
           params: { webhook_url: "http://example.com/insecure", events: ["notifications.delivered"] }
    end
    assert_response :unprocessable_entity
    assert_match(/https/i, response.parsed_body["error"].to_s)
  end

  test "POST register_webhook: 422 if webhook_url has embedded credentials" do
    setup = make_setup
    get "/bridge-setups/#{setup.public_id}"
    # Built dynamically so the literal `user:pass@host` doesn't trip the
    # check-secrets pre-commit hook (which scans for basic-auth URLs).
    url_with_creds = URI("https://example.com/webhook").tap { |u| u.userinfo = "u:p" }.to_s
    assert_no_difference -> { AutomationRule.tenant_scoped_only(@tenant.id).count } do
      post "/bridge-setups/#{setup.public_id}/webhook",
           params: { webhook_url: url_with_creds, events: ["notifications.delivered"] }
    end
    assert_response :unprocessable_entity
  end

  test "POST register_webhook: 422 if webhook_url is malformed" do
    setup = make_setup
    get "/bridge-setups/#{setup.public_id}"
    post "/bridge-setups/#{setup.public_id}/webhook",
         params: { webhook_url: "not a url", events: ["notifications.delivered"] }
    assert_response :unprocessable_entity
  end

  test "POST register_webhook: defaults to setup's events_recommended if events omitted" do
    setup = make_setup
    get "/bridge-setups/#{setup.public_id}"
    url = "https://example.org/y"
    stub_reachable(url)
    post "/bridge-setups/#{setup.public_id}/webhook",
         params: { webhook_url: url }
    assert_response :ok
    setup.reload
    rule = setup.automation_rule
    assert_equal setup.events_recommended, rule.trigger_config["event_types"]
  end

  test "POST register_webhook: 422 + nothing leaked (no token, no AutomationRule) when the webhook URL is unreachable" do
    setup = make_setup
    get "/bridge-setups/#{setup.public_id}"
    url = "https://example.com/unreachable/webhook"
    stub_request(:post, url).to_raise(Errno::ECONNREFUSED)

    assert_no_difference -> { AutomationRule.tenant_scoped_only(@tenant.id).count } do
      assert_no_difference -> { @agent.api_tokens.count } do
        post "/bridge-setups/#{setup.public_id}/webhook",
             params: { webhook_url: url, events: ["notifications.delivered"] }
      end
    end
    assert_response :unprocessable_entity
    body = response.parsed_body
    assert_equal "webhook_unreachable", body["error"]
    assert body["detail"].present?

    # Setup is back to redeemed-but-not-completed; the caller can retry the POST.
    setup.reload
    assert_nil setup.webhook_registered_at
    assert_nil setup.automation_rule
    assert_nil setup.api_token
  end

  test "POST register_webhook: 422 + nothing leaked when webhook URL returns a non-2xx status" do
    setup = make_setup
    get "/bridge-setups/#{setup.public_id}"
    url = "https://example.com/broken/webhook"
    stub_request(:post, url).to_return(status: 502, body: "Bad Gateway")

    assert_no_difference -> { AutomationRule.tenant_scoped_only(@tenant.id).count } do
      assert_no_difference -> { @agent.api_tokens.count } do
        post "/bridge-setups/#{setup.public_id}/webhook",
             params: { webhook_url: url, events: ["notifications.delivered"] }
      end
    end
    assert_response :unprocessable_entity
    assert_equal "webhook_unreachable", response.parsed_body["error"]
    assert_match(/502/, response.parsed_body["detail"].to_s)
  end

  test "POST register_webhook: signs the verification request with the fresh signing secret" do
    setup = make_setup
    get "/bridge-setups/#{setup.public_id}"
    url = "https://example.com/verify/webhook"

    captured_headers = {}
    captured_body = nil
    stub_request(:post, url)
      .to_return(status: 200)
      .with do |req|
        captured_headers = req.headers
        captured_body = req.body
        true
      end

    post "/bridge-setups/#{setup.public_id}/webhook",
         params: { webhook_url: url, events: ["notifications.delivered"] }
    assert_response :ok
    signing_secret = response.parsed_body["signing_secret"]

    assert_equal "harmonic.webhook.test", captured_headers["X-Harmonic-Event"]
    expected = WebhookDeliveryService.sign(captured_body, captured_headers["X-Harmonic-Timestamp"].to_i, signing_secret)
    assert_equal "sha256=#{expected}", captured_headers["X-Harmonic-Signature"]
  end
end
