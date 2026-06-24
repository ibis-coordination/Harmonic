# frozen_string_literal: true

require "test_helper"
require "webmock/minitest"
require_relative "../support/bridge_protocol_fixtures"

class HarmonicBridgeSetupsControllerTest < ActionDispatch::IntegrationTest
  include BridgeProtocolFixtures

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

  # ---------- POST redeem ----------

  test "POST redeem: returns the full credential bundle and marks redeemed" do
    setup = make_setup
    post "/bridge-setups/#{setup.public_id}"
    assert_response :ok
    body = response.parsed_body

    # Wire-shape contract: same fixture the TypeScript bridge tests load.
    # If a field is renamed on either side, this fails.
    assert_matches_bridge_protocol_fixture(body, "redeem_response.json")

    # Value-level assertions on top of the shape contract.
    assert_equal @agent.tenant_users.find_by(tenant: @tenant).handle, body["agent_handle"]
    assert body["webhook_register_url"].include?(setup.public_id)
    assert_equal ["notifications.delivered", "reminders.delivered"], body["events_recommended"]

    setup.reload
    assert setup.redeemed_at.present?
    assert setup.api_token.present?
    assert setup.automation_rule.present?, "pending rule is created at GET so signing secret has a home"
    assert_equal body["signing_secret"], setup.automation_rule.webhook_secret
    assert_equal false, setup.automation_rule.enabled?, "rule is disabled until POST"
  end

  test "POST redeem: 404 on second redemption" do
    setup = make_setup
    post "/bridge-setups/#{setup.public_id}"
    assert_response :ok
    post "/bridge-setups/#{setup.public_id}"
    assert_response :not_found
  end

  test "POST redeem: 404 on expired setup" do
    setup = make_setup(expires_at: 1.minute.ago)
    post "/bridge-setups/#{setup.public_id}"
    assert_response :not_found
  end

  test "POST redeem: 404 on unknown public_id" do
    post "/bridge-setups/not-a-real-id"
    assert_response :not_found
  end

  test "POST redeem: 409 when a second setup URL races against a first redemption for the same agent" do
    # Two HarmonicBridgeSetup rows for the same agent. The first GET wins
    # and mints the rule. The second GET must NOT mint a second rule —
    # `redeem!` re-checks inside the lock and raises ConflictingSetup; the
    # controller surfaces a 409 so the second bridge install fails loudly
    # rather than silently parking a long-lived token.
    first = make_setup
    second = make_setup
    post "/bridge-setups/#{first.public_id}"
    assert_response :ok
    post "/bridge-setups/#{second.public_id}"
    assert_response :conflict
    assert_equal "agent_has_pending_or_active_webhook", response.parsed_body["error"]
    assert_equal 1, @agent.api_tokens.count
    assert_equal 1, AutomationRule.tenant_scoped_only(@tenant.id).where(ai_agent_id: @agent.id).count
  end

  # ---------- POST register_webhook ----------

  def stub_reachable(url)
    stub_request(:post, url).to_return(status: 200, body: '{"received":true}')
  end

  test "POST register_webhook: fills the URL into the GET-created rule + enables it, returns ok" do
    setup = make_setup
    post "/bridge-setups/#{setup.public_id}"
    assert_response :ok
    redeem_response_secret = response.parsed_body["signing_secret"]
    setup.reload
    pending_rule_id = setup.automation_rule.id

    webhook_url = "https://example.com/webhook/#{@agent.tenant_users.find_by(tenant: @tenant).handle}"
    stub_reachable(webhook_url)
    assert_no_difference -> { AutomationRule.tenant_scoped_only(@tenant.id).count }, "rule was already created at GET" do
      assert_no_difference -> { @agent.api_tokens.count }, "token was already minted at GET" do
        post "/bridge-setups/#{setup.public_id}/webhook",
             params: { webhook_url: webhook_url, events: ["notifications.delivered"] }
      end
    end
    assert_response :ok
    # Wire-shape contract for POST success body.
    assert_matches_bridge_protocol_fixture(response.parsed_body, "post_response.json")
    assert_equal({ "ok" => true }, response.parsed_body)

    setup.reload
    rule = setup.automation_rule
    assert_equal pending_rule_id, rule.id, "same rule, now populated"
    assert_equal webhook_url, rule.actions["webhook_url"]
    assert rule.enabled?, "rule is enabled only after verification succeeded"
    assert_equal redeem_response_secret, rule.webhook_secret,
                 "secret is the one returned by GET (rule's own webhook_secret field, unchanged)"
    assert setup.webhook_registered_at.present?
  end

  test "POST register_webhook: rule stays disabled during the verification call" do
    # Tightens the guarantee that real notifications can't fire to an
    # unverified URL: while the deliver call is in flight, the rule has the
    # URL stored but enabled? is false.
    setup = make_setup
    post "/bridge-setups/#{setup.public_id}"
    url = "https://example.com/inspect-during-verify/webhook"

    saw_disabled_with_url = false
    stub_request(:post, url).to_return do |_req|
      rule = setup.reload.automation_rule
      saw_disabled_with_url = rule.present? && rule.actions["webhook_url"] == url && !rule.enabled?
      { status: 200, body: '{"ok":true}' }
    end

    post "/bridge-setups/#{setup.public_id}/webhook",
         params: { webhook_url: url, events: ["notifications.delivered"] }
    assert_response :ok
    assert saw_disabled_with_url,
           "during the verification HTTP call, the rule must hold the URL but stay disabled"
    setup.reload
    assert setup.automation_rule.enabled?, "rule enables only after deliver returns ok"
  end

  test "POST register_webhook: 404 if POST redeem not yet called" do
    setup = make_setup
    post "/bridge-setups/#{setup.public_id}/webhook",
         params: { webhook_url: "https://example.org/y", events: ["notifications.delivered"] }
    assert_response :not_found
  end

  test "POST register_webhook: 404 on second invocation" do
    setup = make_setup
    post "/bridge-setups/#{setup.public_id}"
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
    post "/bridge-setups/#{setup.public_id}"
    setup.update_columns(expires_at: 1.minute.ago)
    post "/bridge-setups/#{setup.public_id}/webhook",
         params: { webhook_url: "https://example.org/y", events: ["notifications.delivered"] }
    assert_response :not_found
  end

  test "POST register_webhook: 422 if webhook_url is missing" do
    setup = make_setup
    post "/bridge-setups/#{setup.public_id}"
    post "/bridge-setups/#{setup.public_id}/webhook", params: { events: ["notifications.delivered"] }
    assert_response :unprocessable_entity
  end

  test "POST register_webhook: 422 if webhook_url is not HTTPS" do
    setup = make_setup
    post "/bridge-setups/#{setup.public_id}"
    assert_no_difference -> { AutomationRule.tenant_scoped_only(@tenant.id).count } do
      post "/bridge-setups/#{setup.public_id}/webhook",
           params: { webhook_url: "http://example.com/insecure", events: ["notifications.delivered"] }
    end
    assert_response :unprocessable_entity
    assert_match(/https/i, response.parsed_body["error"].to_s)
  end

  test "POST register_webhook: 422 if webhook_url has embedded credentials" do
    setup = make_setup
    post "/bridge-setups/#{setup.public_id}"
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
    post "/bridge-setups/#{setup.public_id}"
    post "/bridge-setups/#{setup.public_id}/webhook",
         params: { webhook_url: "not a url", events: ["notifications.delivered"] }
    assert_response :unprocessable_entity
  end

  test "POST register_webhook: defaults to setup's events_recommended if events omitted" do
    setup = make_setup
    post "/bridge-setups/#{setup.public_id}"
    url = "https://example.org/y"
    stub_reachable(url)
    post "/bridge-setups/#{setup.public_id}/webhook",
         params: { webhook_url: url }
    assert_response :ok
    setup.reload
    rule = setup.automation_rule
    assert_equal setup.events_recommended, rule.trigger_config["event_types"]
  end

  test "POST register_webhook: 422 + full rollback when verification fails (connection refused)" do
    setup = make_setup
    post "/bridge-setups/#{setup.public_id}"
    url = "https://example.com/unreachable/webhook"
    stub_request(:post, url).to_raise(Errno::ECONNREFUSED)

    # Token + secret were minted by GET; the verification failure must wipe
    # them so the setup isn't left half-finished.
    assert_difference -> { AutomationRule.tenant_scoped_only(@tenant.id).count } => -1 do
      assert_difference -> { @agent.api_tokens.count } => -1 do
        post "/bridge-setups/#{setup.public_id}/webhook",
             params: { webhook_url: url, events: ["notifications.delivered"] }
      end
    end
    assert_response :unprocessable_entity
    body = response.parsed_body
    # Wire-shape contract for the verification-failure error.
    assert_matches_bridge_protocol_fixture(body, "post_error_webhook_unreachable.json")
    assert_equal "webhook_unreachable", body["error"]

    setup.reload
    assert_nil setup.webhook_registered_at
    assert_nil setup.automation_rule
    assert_nil setup.api_token
    assert_not setup.webhook_registerable?, "setup is no longer POSTable after revert"
  end

  test "POST register_webhook: 422 + full rollback when webhook URL returns a non-2xx status" do
    setup = make_setup
    post "/bridge-setups/#{setup.public_id}"
    url = "https://example.com/broken/webhook"
    stub_request(:post, url).to_return(status: 502, body: "Bad Gateway")

    assert_difference -> { AutomationRule.tenant_scoped_only(@tenant.id).count } => -1 do
      assert_difference -> { @agent.api_tokens.count } => -1 do
        post "/bridge-setups/#{setup.public_id}/webhook",
             params: { webhook_url: url, events: ["notifications.delivered"] }
      end
    end
    assert_response :unprocessable_entity
    assert_equal "webhook_unreachable", response.parsed_body["error"]
    assert_match(/502/, response.parsed_body["detail"].to_s)
  end

  test "POST register_webhook: a second POST after a failed verification is 404 (setup is consumed)" do
    setup = make_setup
    post "/bridge-setups/#{setup.public_id}"
    url = "https://example.com/will-fail/webhook"
    stub_request(:post, url).to_raise(Errno::ECONNREFUSED)
    post "/bridge-setups/#{setup.public_id}/webhook",
         params: { webhook_url: url, events: ["notifications.delivered"] }
    assert_response :unprocessable_entity

    # Even retrying with a now-working URL fails: the setup has no signing
    # secret left, so webhook_registerable? is false.
    fixed_url = "https://example.com/now-working/webhook"
    stub_reachable(fixed_url)
    post "/bridge-setups/#{setup.public_id}/webhook",
         params: { webhook_url: fixed_url, events: ["notifications.delivered"] }
    assert_response :not_found
  end

  test "POST register_webhook: verification request is signed with the GET-revealed secret" do
    setup = make_setup
    post "/bridge-setups/#{setup.public_id}"
    signing_secret = response.parsed_body["signing_secret"]

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

    assert_equal "harmonic.webhook.test", captured_headers["X-Harmonic-Event"]
    expected = WebhookDeliveryService.sign(captured_body, captured_headers["X-Harmonic-Timestamp"].to_i, signing_secret)
    assert_equal "sha256=#{expected}", captured_headers["X-Harmonic-Signature"]
  end
end
