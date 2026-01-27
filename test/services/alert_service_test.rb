# typed: false
require "test_helper"

class AlertServiceTest < ActiveSupport::TestCase
  setup do
    # Enable AlertService for testing
    ENV["ALERT_SERVICE_ENABLED"] = "true"
    # Clear any cached throttle data
    Rails.cache.clear if Rails.cache.respond_to?(:clear)
  end

  teardown do
    ENV.delete("ALERT_SERVICE_ENABLED")
    ENV.delete("SLACK_WEBHOOK_URL")
    ENV.delete("ALERT_EMAIL_RECIPIENTS")
  end

  test "notify builds correct payload" do
    # Capture the log output to verify alert was processed
    log_output = StringIO.new
    Rails.logger = ActiveSupport::TaggedLogging.new(ActiveSupport::Logger.new(log_output))

    AlertService.notify("Test alert message", severity: :warning, context: { ip: "1.2.3.4" })

    log_content = log_output.string
    assert_includes log_content, "Test alert message"
    assert_includes log_content, "warning"
  end

  test "notify_security_event formats ip_blocked message" do
    log_output = StringIO.new
    Rails.logger = ActiveSupport::TaggedLogging.new(ActiveSupport::Logger.new(log_output))

    AlertService.notify_security_event(
      event: "ip_blocked",
      ip: "1.2.3.4",
      matched: "block-bad-actors"
    )

    log_content = log_output.string
    assert_includes log_content, "IP address blocked"
    assert_includes log_content, "1.2.3.4"
  end

  test "notify_security_event formats rate_limited message" do
    log_output = StringIO.new
    Rails.logger = ActiveSupport::TaggedLogging.new(ActiveSupport::Logger.new(log_output))

    AlertService.notify_security_event(
      event: "rate_limited",
      ip: "1.2.3.4",
      matched: "login/ip",
      request_path: "/login"
    )

    log_content = log_output.string
    assert_includes log_content, "Rate limited"
    assert_includes log_content, "/login"
  end

  test "does not send alerts when disabled" do
    ENV.delete("ALERT_SERVICE_ENABLED")

    log_output = StringIO.new
    Rails.logger = ActiveSupport::TaggedLogging.new(ActiveSupport::Logger.new(log_output))

    AlertService.notify("Should not appear", severity: :warning)

    # In test env without ALERT_SERVICE_ENABLED, nothing should be logged
    assert_empty log_output.string
  end

  test "throttles repeated alerts" do
    # Use memory cache for this test (test env uses null_store by default)
    original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new

    log_output = StringIO.new
    Rails.logger = ActiveSupport::TaggedLogging.new(ActiveSupport::Logger.new(log_output))

    # Send 5 identical alerts - first 3 should go through, rest should be throttled
    5.times do
      AlertService.notify("Repeated alert", severity: :warning)
    end

    log_content = log_output.string
    # Count actual alerts sent (JSON payloads with [ALERT] tag)
    # The throttle messages contain "Throttled alert:" prefix, so exclude those
    alert_lines = log_content.lines.select { |line| line.include?("[ALERT]") && line.include?('"message":"Repeated alert"') }
    throttle_lines = log_content.lines.select { |line| line.include?("Throttled alert:") }

    # Should have sent 3 alerts and throttled 2
    assert_equal 3, alert_lines.count, "Expected 3 alerts to be sent"
    assert_equal 2, throttle_lines.count, "Expected 2 alerts to be throttled"
  ensure
    Rails.cache = original_cache
  end

  test "does not throttle critical alerts" do
    log_output = StringIO.new
    Rails.logger = ActiveSupport::TaggedLogging.new(ActiveSupport::Logger.new(log_output))

    # Send 5 identical critical alerts - all should go through
    5.times do
      AlertService.notify("Critical alert", severity: :critical)
    end

    log_content = log_output.string
    alert_count = log_content.scan("Critical alert").count

    assert_equal 5, alert_count, "Critical alerts should not be throttled"
  end

  test "sends to slack when configured" do
    ENV["SLACK_WEBHOOK_URL"] = "https://hooks.slack.com/test"

    # Stub the HTTP request
    stub_request(:post, "https://hooks.slack.com/test")
      .to_return(status: 200, body: "ok")

    AlertService.notify("Slack test", severity: :warning)

    # Give the thread a moment to execute
    sleep 0.1

    assert_requested :post, "https://hooks.slack.com/test"
  end
end
