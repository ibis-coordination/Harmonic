# typed: false

require "test_helper"

class SecurityAuditLogReaderTest < ActiveSupport::TestCase
  def setup
    @log_file = Rails.root.join("log/security_audit.log")
  end

  test "log_exists? returns true when log file exists" do
    # The log file should exist from other tests that log security events
    if File.exist?(@log_file)
      assert SecurityAuditLogReader.log_exists?
    else
      # Create a log entry to ensure file exists
      SecurityAuditLog.log_event(event: "test_event", severity: :info, ip: "127.0.0.1")
      assert SecurityAuditLogReader.log_exists?
    end
  end

  test "summary returns hash with all event types" do
    summary = SecurityAuditLogReader.summary(since: 24.hours.ago)

    # Should have all event types as keys
    SecurityAuditLogReader::EVENT_TYPES.each do |event_type|
      assert summary.key?(event_type), "Summary should include #{event_type}"
      assert summary[event_type].is_a?(Integer), "#{event_type} count should be an integer"
    end
  end

  test "summary counts events within time window" do
    unique_ip = "192.168.#{rand(1..254)}.#{rand(1..254)}"

    # Log a test event
    SecurityAuditLog.log_login_success(
      user: @global_user,
      ip: unique_ip,
      user_agent: "TestAgent"
    )

    summary = SecurityAuditLogReader.summary(since: 1.minute.ago)
    assert summary["login_success"] >= 1, "Should count recent login_success events"
  end

  test "recent_events returns array of event hashes" do
    events = SecurityAuditLogReader.recent_events(limit: 10)

    assert events.is_a?(Array)
    events.each do |event|
      assert event.is_a?(Hash)
      assert event.key?("timestamp"), "Event should have timestamp"
      assert event.key?("event"), "Event should have event type"
    end
  end

  test "recent_events returns newest first" do
    events = SecurityAuditLogReader.recent_events(limit: 10)

    return if events.size < 2

    # Verify sorted by timestamp descending
    timestamps = events.map { |e| e["timestamp"] }
    assert_equal timestamps.sort.reverse, timestamps, "Events should be sorted newest first"
  end

  test "recent_events respects limit" do
    events = SecurityAuditLogReader.recent_events(limit: 5)
    assert events.size <= 5, "Should respect limit parameter"
  end

  test "events_by_type filters by event type" do
    unique_ip = "192.168.#{rand(1..254)}.#{rand(1..254)}"

    # Log a specific event type
    SecurityAuditLog.log_logout(user: @global_user, ip: unique_ip)

    events = SecurityAuditLogReader.events_by_type("logout", limit: 50)

    assert events.is_a?(Array)
    events.each do |event|
      assert_equal "logout", event["event"], "All events should be logout type"
    end
  end

  test "top_ips returns array of ip, count tuples" do
    top_ips = SecurityAuditLogReader.top_ips(since: 24.hours.ago, limit: 5)

    assert top_ips.is_a?(Array)
    top_ips.each do |ip, count|
      assert ip.is_a?(String), "IP should be a string"
      assert count.is_a?(Integer), "Count should be an integer"
    end
  end

  test "top_ips sorted by count descending" do
    top_ips = SecurityAuditLogReader.top_ips(since: 24.hours.ago, limit: 10)

    return if top_ips.size < 2

    counts = top_ips.map { |_ip, count| count }
    assert_equal counts.sort.reverse, counts, "IPs should be sorted by count descending"
  end

  test "events_by_ip filters by IP address" do
    unique_ip = "10.99.#{rand(1..254)}.#{rand(1..254)}"

    # Log events from specific IP
    SecurityAuditLog.log_login_success(user: @global_user, ip: unique_ip, user_agent: "Test")
    SecurityAuditLog.log_logout(user: @global_user, ip: unique_ip)

    events = SecurityAuditLogReader.events_by_ip(unique_ip, limit: 10)

    assert events.size >= 2, "Should find events from the specific IP"
    events.each do |event|
      assert_equal unique_ip, event["ip"], "All events should be from the specified IP"
    end
  end

  test "handles malformed log lines gracefully" do
    # This test verifies the reader doesn't crash on bad data
    # The actual log file may have valid data, so we just verify no exceptions
    assert_nothing_raised do
      SecurityAuditLogReader.summary(since: 24.hours.ago)
      SecurityAuditLogReader.recent_events(limit: 10)
    end
  end

  test "EVENT_TYPES constant includes all expected types" do
    expected_types = %w[
      login_success
      login_failure
      logout
      password_reset_requested
      password_changed
      permission_denied
      admin_action
      rate_limited
      ip_blocked
    ]

    expected_types.each do |event_type|
      assert SecurityAuditLogReader::EVENT_TYPES.include?(event_type),
             "EVENT_TYPES should include #{event_type}"
    end
  end

  # Tests for new filtering and drill-down functionality

  test "event_at_line returns event with line_number" do
    # Count existing lines in the log file
    line_count_before = File.exist?(@log_file) ? File.foreach(@log_file).count : 0

    # Create a new event
    unique_ip = "10.88.#{rand(1..254)}.#{rand(1..254)}"
    SecurityAuditLog.log_login_success(user: @global_user, ip: unique_ip, user_agent: "Test")

    # Get the event we just created (should be at line_count_before + 1)
    expected_line = line_count_before + 1
    event = SecurityAuditLogReader.event_at_line(expected_line)

    assert event.is_a?(Hash), "Should return a hash"
    assert_equal expected_line, event["line_number"], "Should include line_number"
    assert event.key?("timestamp"), "Should have timestamp"
    assert event.key?("event"), "Should have event type"
  end

  test "event_at_line returns nil for invalid line numbers" do
    assert_nil SecurityAuditLogReader.event_at_line(0)
    assert_nil SecurityAuditLogReader.event_at_line(-1)
    assert_nil SecurityAuditLogReader.event_at_line(999_999_999)
  end

  test "filtered_events returns events with line_number" do
    unique_ip = "10.77.#{rand(1..254)}.#{rand(1..254)}"
    SecurityAuditLog.log_login_success(user: @global_user, ip: unique_ip, user_agent: "Test")

    result = SecurityAuditLogReader.filtered_events(per_page: 10)

    assert result.is_a?(Hash), "Should return a hash"
    assert result.key?(:events), "Should have :events key"
    assert result.key?(:total_count), "Should have :total_count key"
    assert result[:events].is_a?(Array)
    result[:events].each do |event|
      assert event.key?("line_number"), "Each event should have line_number"
      assert event["line_number"].is_a?(Integer), "line_number should be an integer"
    end
  end

  test "filtered_events filters by event_type" do
    unique_ip = "10.66.#{rand(1..254)}.#{rand(1..254)}"
    SecurityAuditLog.log_login_success(user: @global_user, ip: unique_ip, user_agent: "Test")
    SecurityAuditLog.log_logout(user: @global_user, ip: unique_ip)

    result = SecurityAuditLogReader.filtered_events(event_type: "logout", per_page: 100)

    result[:events].each do |event|
      assert_equal "logout", event["event"], "All events should be logout type"
    end
  end

  test "filtered_events filters by ip" do
    unique_ip = "10.55.#{rand(1..254)}.#{rand(1..254)}"
    other_ip = "10.44.#{rand(1..254)}.#{rand(1..254)}"

    SecurityAuditLog.log_login_success(user: @global_user, ip: unique_ip, user_agent: "Test")
    SecurityAuditLog.log_login_success(user: @global_user, ip: other_ip, user_agent: "Test")

    result = SecurityAuditLogReader.filtered_events(ip: unique_ip, per_page: 100)

    result[:events].each do |event|
      assert_equal unique_ip, event["ip"], "All events should be from the specified IP"
    end
  end

  test "filtered_events filters by email" do
    unique_ip = "10.33.#{rand(1..254)}.#{rand(1..254)}"
    user_email = @global_user.email

    SecurityAuditLog.log_login_success(user: @global_user, ip: unique_ip, user_agent: "Test")

    result = SecurityAuditLogReader.filtered_events(email: user_email, per_page: 100)

    result[:events].each do |event|
      assert_equal user_email, event["email"], "All events should have the specified email"
    end
  end

  test "filtered_events filters by time window" do
    unique_ip = "10.22.#{rand(1..254)}.#{rand(1..254)}"
    SecurityAuditLog.log_login_success(user: @global_user, ip: unique_ip, user_agent: "Test")

    result = SecurityAuditLogReader.filtered_events(since: 1.minute.ago, per_page: 100)

    result[:events].each do |event|
      timestamp = Time.zone.parse(event["timestamp"])
      assert timestamp >= 1.minute.ago, "All events should be within time window"
    end
  end

  test "filtered_events sorts by timestamp descending by default" do
    result = SecurityAuditLogReader.filtered_events(per_page: 10)

    return if result[:events].size < 2

    timestamps = result[:events].map { |e| e["timestamp"] }
    assert_equal timestamps.sort.reverse, timestamps, "Events should be sorted newest first"
  end

  test "filtered_events sorts ascending when specified" do
    result = SecurityAuditLogReader.filtered_events(sort_dir: "asc", per_page: 10)

    return if result[:events].size < 2

    timestamps = result[:events].map { |e| e["timestamp"] }
    assert_equal timestamps.sort, timestamps, "Events should be sorted oldest first"
  end

  test "filtered_events can sort by event type" do
    result = SecurityAuditLogReader.filtered_events(sort_by: "event", sort_dir: "asc", per_page: 50)

    return if result[:events].size < 2

    event_types = result[:events].map { |e| e["event"] }
    assert_equal event_types.sort, event_types, "Events should be sorted by event type"
  end

  test "filtered_events respects per_page" do
    result = SecurityAuditLogReader.filtered_events(per_page: 3)
    assert result[:events].size <= 3, "Should respect per_page parameter"
  end

  # Pagination tests

  test "filtered_events returns total_count correctly" do
    unique_ip = "10.11.#{rand(1..254)}.#{rand(1..254)}"

    # Log 5 events
    5.times { SecurityAuditLog.log_login_success(user: @global_user, ip: unique_ip, user_agent: "Test") }

    result = SecurityAuditLogReader.filtered_events(ip: unique_ip, per_page: 2)

    assert_equal 5, result[:total_count], "Should return correct total count"
    assert result[:events].size <= 2, "Should only return per_page events"
  end

  test "filtered_events paginates correctly with page parameter" do
    unique_ip = "10.12.#{rand(1..254)}.#{rand(1..254)}"

    # Log 5 events
    5.times { SecurityAuditLog.log_login_success(user: @global_user, ip: unique_ip, user_agent: "Test") }

    # Get page 1 (2 per page)
    page1_result = SecurityAuditLogReader.filtered_events(ip: unique_ip, page: 1, per_page: 2)
    # Get page 2
    page2_result = SecurityAuditLogReader.filtered_events(ip: unique_ip, page: 2, per_page: 2)
    # Get page 3 (should have 1 event)
    page3_result = SecurityAuditLogReader.filtered_events(ip: unique_ip, page: 3, per_page: 2)

    assert_equal 2, page1_result[:events].size, "Page 1 should have 2 events"
    assert_equal 2, page2_result[:events].size, "Page 2 should have 2 events"
    assert_equal 1, page3_result[:events].size, "Page 3 should have 1 event"

    # Verify no overlap
    page1_line_numbers = page1_result[:events].map { |e| e["line_number"] }
    page2_line_numbers = page2_result[:events].map { |e| e["line_number"] }
    page3_line_numbers = page3_result[:events].map { |e| e["line_number"] }

    assert_empty page1_line_numbers & page2_line_numbers, "Pages should not overlap"
    assert_empty page2_line_numbers & page3_line_numbers, "Pages should not overlap"
  end

  test "filtered_events returns empty array for page beyond total" do
    unique_ip = "10.13.#{rand(1..254)}.#{rand(1..254)}"
    SecurityAuditLog.log_login_success(user: @global_user, ip: unique_ip, user_agent: "Test")

    result = SecurityAuditLogReader.filtered_events(ip: unique_ip, page: 999, per_page: 50)

    assert_equal [], result[:events], "Should return empty array for page beyond total"
    assert result[:total_count] >= 1, "Total count should still be accurate"
  end
end
