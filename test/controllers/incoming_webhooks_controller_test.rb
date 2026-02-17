require "test_helper"

class IncomingWebhooksControllerTest < ActionDispatch::IntegrationTest
  TIMESTAMP_TOLERANCE = 5.minutes

  def setup
    @tenant = @global_tenant
    @tenant.enable_api!
    @superagent = @global_superagent
    @superagent.enable_api!
    @user = @global_user

    # Set up subdomain-based host for requests
    host! "#{@tenant.subdomain}.#{ENV.fetch('HOSTNAME', 'harmonic.local')}"

    # Create a webhook-triggered automation rule
    @automation_rule = AutomationRule.unscoped.create!(
      tenant: @tenant,
      superagent: @superagent,
      created_by: @user,
      name: "Webhook Test Rule",
      trigger_type: "webhook",
      trigger_config: {},
      actions: [{ "type" => "internal_action", "action" => "create_note", "params" => { "text" => "Triggered!" } }],
      enabled: true,
    )

    @webhook_path = @automation_rule.webhook_path
    @webhook_secret = @automation_rule.webhook_secret
  end

  def generate_signature(body, timestamp, secret)
    WebhookDeliveryService.sign(body, timestamp, secret)
  end

  def valid_webhook_headers(body, secret = @webhook_secret)
    timestamp = Time.current.to_i
    signature = generate_signature(body, timestamp, secret)
    {
      "Content-Type" => "application/json",
      "X-Harmonic-Timestamp" => timestamp.to_s,
      "X-Harmonic-Signature" => "sha256=#{signature}",
    }
  end

  # === Success Tests ===

  test "valid signature accepts webhook and returns 200" do
    payload = { "event" => "test", "data" => { "value" => 123 } }.to_json

    post "/hooks/#{@webhook_path}",
      params: payload,
      headers: valid_webhook_headers(payload)

    assert_response :ok
    json = JSON.parse(response.body)
    assert_equal "accepted", json["status"]
    # Returns full UUID run_id (AutomationRuleRun doesn't have truncated_id)
    assert json["run_id"].present?
    assert_match(/^[0-9a-f-]{36}$/, json["run_id"])
  end

  test "creates AutomationRuleRun on success" do
    payload = { "event" => "test" }.to_json

    assert_difference "AutomationRuleRun.unscoped.count" do
      post "/hooks/#{@webhook_path}",
        params: payload,
        headers: valid_webhook_headers(payload)
    end

    assert_response :ok

    run = AutomationRuleRun.unscoped.order(created_at: :desc).first
    assert_equal @automation_rule.id, run.automation_rule_id
    assert_equal "webhook", run.trigger_source
    assert_equal "pending", run.status
    assert_equal @webhook_path, run.trigger_data["webhook_path"]
    assert run.trigger_data["payload"].present?
  end

  test "enqueues AutomationRuleExecutionJob on success" do
    payload = { "event" => "test" }.to_json

    assert_enqueued_with(job: AutomationRuleExecutionJob) do
      post "/hooks/#{@webhook_path}",
        params: payload,
        headers: valid_webhook_headers(payload)
    end

    assert_response :ok
  end

  # === Authentication/Signature Tests ===

  test "missing signature returns 401" do
    payload = { "event" => "test" }.to_json

    post "/hooks/#{@webhook_path}",
      params: payload,
      headers: {
        "Content-Type" => "application/json",
        "X-Harmonic-Timestamp" => Time.current.to_i.to_s,
      }

    assert_response :unauthorized
    json = JSON.parse(response.body)
    assert_equal "invalid_signature", json["error"]
  end

  test "missing timestamp returns 401" do
    payload = { "event" => "test" }.to_json
    signature = generate_signature(payload, Time.current.to_i, @webhook_secret)

    post "/hooks/#{@webhook_path}",
      params: payload,
      headers: {
        "Content-Type" => "application/json",
        "X-Harmonic-Signature" => "sha256=#{signature}",
      }

    assert_response :unauthorized
    json = JSON.parse(response.body)
    assert_equal "invalid_signature", json["error"]
  end

  test "invalid signature returns 401" do
    payload = { "event" => "test" }.to_json
    timestamp = Time.current.to_i
    wrong_signature = generate_signature(payload, timestamp, "wrong_secret")

    post "/hooks/#{@webhook_path}",
      params: payload,
      headers: {
        "Content-Type" => "application/json",
        "X-Harmonic-Timestamp" => timestamp.to_s,
        "X-Harmonic-Signature" => "sha256=#{wrong_signature}",
      }

    assert_response :unauthorized
    json = JSON.parse(response.body)
    assert_equal "invalid_signature", json["error"]
  end

  test "expired timestamp returns 401" do
    payload = { "event" => "test" }.to_json
    old_timestamp = (Time.current - 10.minutes).to_i
    signature = generate_signature(payload, old_timestamp, @webhook_secret)

    post "/hooks/#{@webhook_path}",
      params: payload,
      headers: {
        "Content-Type" => "application/json",
        "X-Harmonic-Timestamp" => old_timestamp.to_s,
        "X-Harmonic-Signature" => "sha256=#{signature}",
      }

    assert_response :unauthorized
    json = JSON.parse(response.body)
    assert_equal "timestamp_expired", json["error"]
  end

  test "signature without sha256 prefix is accepted" do
    payload = { "event" => "test" }.to_json
    timestamp = Time.current.to_i
    signature = generate_signature(payload, timestamp, @webhook_secret)

    post "/hooks/#{@webhook_path}",
      params: payload,
      headers: {
        "Content-Type" => "application/json",
        "X-Harmonic-Timestamp" => timestamp.to_s,
        "X-Harmonic-Signature" => signature, # No "sha256=" prefix
      }

    assert_response :ok
  end

  # === Not Found Tests ===

  test "unknown webhook_path returns 404" do
    payload = { "event" => "test" }.to_json

    post "/hooks/unknown_path_12345",
      params: payload,
      headers: valid_webhook_headers(payload)

    assert_response :not_found
    json = JSON.parse(response.body)
    assert_equal "not_found", json["error"]
  end

  # === Disabled Rule Tests ===

  test "disabled rule returns 422" do
    @automation_rule.update!(enabled: false)
    payload = { "event" => "test" }.to_json

    post "/hooks/#{@webhook_path}",
      params: payload,
      headers: valid_webhook_headers(payload)

    assert_response :unprocessable_entity
    json = JSON.parse(response.body)
    assert_equal "rule_disabled", json["error"]
  end

  # === Edge Cases ===

  test "empty payload is accepted" do
    payload = ""

    post "/hooks/#{@webhook_path}",
      params: payload,
      headers: valid_webhook_headers(payload)

    assert_response :ok
  end

  test "non-JSON payload is accepted" do
    payload = "plain text payload"
    timestamp = Time.current.to_i
    signature = generate_signature(payload, timestamp, @webhook_secret)

    post "/hooks/#{@webhook_path}",
      params: payload,
      headers: {
        "Content-Type" => "text/plain",
        "X-Harmonic-Timestamp" => timestamp.to_s,
        "X-Harmonic-Signature" => "sha256=#{signature}",
      }

    assert_response :ok
  end

  test "webhook stores raw payload in trigger_data" do
    payload = { "nested" => { "data" => [1, 2, 3] } }.to_json

    post "/hooks/#{@webhook_path}",
      params: payload,
      headers: valid_webhook_headers(payload)

    assert_response :ok

    run = AutomationRuleRun.unscoped.order(created_at: :desc).first
    assert_equal({ "nested" => { "data" => [1, 2, 3] } }, run.trigger_data["payload"])
  end

  test "webhook stores source IP in trigger_data" do
    payload = { "event" => "test" }.to_json

    post "/hooks/#{@webhook_path}",
      params: payload,
      headers: valid_webhook_headers(payload)

    assert_response :ok

    run = AutomationRuleRun.unscoped.order(created_at: :desc).first
    assert run.trigger_data["source_ip"].present?, "source_ip should be recorded"
    # In test environment, remote_ip is typically 127.0.0.1
    assert_match(/\d+\.\d+\.\d+\.\d+/, run.trigger_data["source_ip"])
  end

  test "does not require CSRF token" do
    payload = { "event" => "test" }.to_json

    # Explicitly not sending any CSRF token
    post "/hooks/#{@webhook_path}",
      params: payload,
      headers: valid_webhook_headers(payload)

    assert_response :ok
  end

  test "does not require authentication" do
    payload = { "event" => "test" }.to_json

    # No Authorization header
    post "/hooks/#{@webhook_path}",
      params: payload,
      headers: valid_webhook_headers(payload)

    assert_response :ok
  end

  # === IP Restriction Tests ===

  test "IP restriction allows matching IP" do
    @automation_rule.update!(trigger_config: { "allowed_ips" => ["127.0.0.1"] })
    payload = { "event" => "test" }.to_json

    post "/hooks/#{@webhook_path}",
      params: payload,
      headers: valid_webhook_headers(payload)

    assert_response :ok
  end

  test "IP restriction blocks non-matching IP" do
    @automation_rule.update!(trigger_config: { "allowed_ips" => ["10.0.0.1"] })
    payload = { "event" => "test" }.to_json

    post "/hooks/#{@webhook_path}",
      params: payload,
      headers: valid_webhook_headers(payload)

    assert_response :forbidden
    json = JSON.parse(response.body)
    assert_equal "ip_not_allowed", json["error"]
  end

  test "IP restriction allows CIDR range containing client IP" do
    # 127.0.0.1 is within 127.0.0.0/8
    @automation_rule.update!(trigger_config: { "allowed_ips" => ["127.0.0.0/8"] })
    payload = { "event" => "test" }.to_json

    post "/hooks/#{@webhook_path}",
      params: payload,
      headers: valid_webhook_headers(payload)

    assert_response :ok
  end

  test "IP restriction blocks CIDR range not containing client IP" do
    @automation_rule.update!(trigger_config: { "allowed_ips" => ["10.0.0.0/8"] })
    payload = { "event" => "test" }.to_json

    post "/hooks/#{@webhook_path}",
      params: payload,
      headers: valid_webhook_headers(payload)

    assert_response :forbidden
  end

  test "IP restriction allows multiple IPs with one match" do
    @automation_rule.update!(trigger_config: { "allowed_ips" => ["10.0.0.1", "127.0.0.1", "192.168.1.1"] })
    payload = { "event" => "test" }.to_json

    post "/hooks/#{@webhook_path}",
      params: payload,
      headers: valid_webhook_headers(payload)

    assert_response :ok
  end

  test "no IP restriction allows all IPs" do
    @automation_rule.update!(trigger_config: {})
    payload = { "event" => "test" }.to_json

    post "/hooks/#{@webhook_path}",
      params: payload,
      headers: valid_webhook_headers(payload)

    assert_response :ok
  end

  # === Cross-Tenant Security ===

  test "webhook path from another tenant returns 404" do
    # Create a second tenant with its own automation rule
    other_tenant = create_tenant(subdomain: "other-tenant-#{SecureRandom.hex(4)}")
    other_superagent = other_tenant.main_superagent
    other_user = create_user(name: "Other User")
    other_tenant.add_user!(other_user)

    other_rule = AutomationRule.unscoped.create!(
      tenant: other_tenant,
      superagent: other_superagent,
      created_by: other_user,
      name: "Other Tenant Webhook",
      trigger_type: "webhook",
      trigger_config: {},
      actions: [{ "type" => "internal_action", "action" => "create_note" }],
      enabled: true,
    )

    # Try to access other tenant's webhook path from our tenant's subdomain
    # This should return 404 because the path doesn't exist in our tenant
    payload = { "event" => "test" }.to_json
    timestamp = Time.current.to_i
    signature = generate_signature(payload, timestamp, other_rule.webhook_secret)

    post "/hooks/#{other_rule.webhook_path}",
      params: payload,
      headers: {
        "Content-Type" => "application/json",
        "X-Harmonic-Timestamp" => timestamp.to_s,
        "X-Harmonic-Signature" => "sha256=#{signature}",
      }

    assert_response :not_found
    json = JSON.parse(response.body)
    assert_equal "not_found", json["error"]
  end
end
