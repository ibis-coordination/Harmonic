# typed: false

require "test_helper"

class SecurityAuditLogTest < ActiveSupport::TestCase
  def setup
    @tenant = @global_tenant
    @user = @global_user
    @log_file = Rails.root.join("log/security_audit.log")
    # Record current line count so find_log_entries only searches entries
    # written during this test, avoiding collisions with accumulated entries
    @log_line_offset = File.exist?(@log_file) ? File.readlines(@log_file).size : 0
  end

  # Find log entries matching the given criteria
  # Only searches entries written after @log_line_offset to avoid
  # false matches from other tests or previous test runs
  def find_log_entries(**criteria)
    return [] unless File.exist?(@log_file)

    File.readlines(@log_file).drop(@log_line_offset).filter_map do |line|
      entry = JSON.parse(line) rescue nil
      next unless entry
      entry if criteria.all? { |key, value| entry[key.to_s] == value }
    end
  end

  test "log_login_success logs user login" do
    # Use unique IP to identify this specific test's log entry
    unique_ip = "192.168.#{rand(1..254)}.#{rand(1..254)}"

    SecurityAuditLog.log_login_success(
      user: @user,
      ip: unique_ip,
      user_agent: "Mozilla/5.0"
    )

    entries = find_log_entries(event: "login_success", ip: unique_ip)
    assert_equal 1, entries.size, "Expected exactly one login_success entry with IP #{unique_ip}"

    entry = entries.first
    assert_equal @user.id, entry["user_id"]
    assert_equal @user.email, entry["email"]
    assert_equal "Mozilla/5.0", entry["user_agent"]
    assert_equal "test", entry["environment"]
    assert_not_nil entry["timestamp"]
  end

  test "log_login_failure logs failed login attempt" do
    unique_email = "attacker-#{SecureRandom.hex(4)}@example.com"

    SecurityAuditLog.log_login_failure(
      email: unique_email,
      ip: "10.0.0.1",
      reason: "invalid_password",
      user_agent: "curl/7.64.1"
    )

    entries = find_log_entries(event: "login_failure", email: unique_email)
    assert_equal 1, entries.size

    entry = entries.first
    assert_equal "10.0.0.1", entry["ip"]
    assert_equal "invalid_password", entry["reason"]
    assert_equal "curl/7.64.1", entry["user_agent"]
  end

  test "log_logout logs user logout" do
    unique_ip = "192.168.#{rand(1..254)}.#{rand(1..254)}"

    SecurityAuditLog.log_logout(user: @user, ip: unique_ip)

    entries = find_log_entries(event: "logout", ip: unique_ip, email: @user.email)
    assert_equal 1, entries.size

    entry = entries.first
    assert_equal @user.id, entry["user_id"]
  end

  test "log_password_reset_requested logs password reset request" do
    unique_email = "user-#{SecureRandom.hex(4)}@example.com"

    SecurityAuditLog.log_password_reset_requested(
      email: unique_email,
      ip: "192.168.1.100"
    )

    entries = find_log_entries(event: "password_reset_requested", email: unique_email)
    assert_equal 1, entries.size

    entry = entries.first
    assert_equal "192.168.1.100", entry["ip"]
  end

  test "log_password_changed logs password change" do
    unique_ip = "192.168.#{rand(1..254)}.#{rand(1..254)}"

    SecurityAuditLog.log_password_changed(user: @user, ip: unique_ip)

    entries = find_log_entries(event: "password_changed", ip: unique_ip, email: @user.email)
    assert_equal 1, entries.size

    entry = entries.first
    assert_equal @user.id, entry["user_id"]
  end

  test "log_permission_denied logs access denial" do
    unique_ip = "192.168.#{rand(1..254)}.#{rand(1..254)}"
    unique_resource = "AdminPanel-#{SecureRandom.hex(4)}"

    SecurityAuditLog.log_permission_denied(
      user: @user,
      ip: unique_ip,
      resource: unique_resource,
      action: "view"
    )

    entries = find_log_entries(event: "permission_denied", resource: unique_resource)
    assert_equal 1, entries.size

    entry = entries.first
    assert_equal @user.id, entry["user_id"]
    assert_equal @user.email, entry["email"]
    assert_equal unique_ip, entry["ip"]
    assert_equal "view", entry["action"]
  end

  test "log_admin_action logs administrative actions" do
    target_user = create_user(email: "target@example.com", name: "Target User")
    unique_ip = "192.168.#{rand(1..254)}.#{rand(1..254)}"

    SecurityAuditLog.log_admin_action(
      admin: @user,
      ip: unique_ip,
      action: "delete_user",
      target_user_id: target_user.id,
      details: { reason: "spam account" }
    )

    entries = find_log_entries(event: "admin_action", ip: unique_ip, target_user_id: target_user.id)
    assert_equal 1, entries.size

    entry = entries.first
    assert_equal @user.id, entry["user_id"]
    assert_equal @user.email, entry["email"]
    assert_equal "delete_user", entry["admin_action"]
    assert_equal "spam account", entry["reason"]
  end

  test "log_rate_limited logs rate limiting events" do
    unique_path = "/api/notes-#{SecureRandom.hex(4)}"

    SecurityAuditLog.log_rate_limited(
      ip: "192.168.1.1",
      matched: "req/ip",
      request_path: unique_path
    )

    entries = find_log_entries(event: "rate_limited", request_path: unique_path)
    assert_equal 1, entries.size

    entry = entries.first
    assert_equal "192.168.1.1", entry["ip"]
    assert_equal "req/ip", entry["matched"]
  end

  test "log_event logs generic events with correct severity" do
    unique_path = "/login-#{SecureRandom.hex(4)}"

    SecurityAuditLog.log_event(
      event: "ip_blocked",
      severity: :warn,
      ip: "192.168.1.1",
      matched: "blocklist",
      request_path: unique_path
    )

    entries = find_log_entries(event: "ip_blocked", request_path: unique_path)
    assert_equal 1, entries.size

    entry = entries.first
    assert_equal "192.168.1.1", entry["ip"]
    assert_equal "blocklist", entry["matched"]
  end

  test "log_event persists severity in JSON payload" do
    unique_path = "/severity-test-#{SecureRandom.hex(4)}"

    SecurityAuditLog.log_event(
      event: "test_severity",
      severity: :warn,
      request_path: unique_path
    )

    entries = find_log_entries(event: "test_severity", request_path: unique_path)
    assert_equal 1, entries.size

    entry = entries.first
    assert_equal "warn", entry["severity"], "severity should be persisted in the JSON payload"
  end

  test "log_event persists default info severity" do
    unique_path = "/severity-default-#{SecureRandom.hex(4)}"

    SecurityAuditLog.log_event(
      event: "test_default_severity",
      request_path: unique_path
    )

    entries = find_log_entries(event: "test_default_severity", request_path: unique_path)
    assert_equal 1, entries.size

    entry = entries.first
    assert_equal "info", entry["severity"], "default severity should be info"
  end

  test "log_event persists error severity" do
    unique_path = "/severity-error-#{SecureRandom.hex(4)}"

    SecurityAuditLog.log_event(
      event: "test_error_severity",
      severity: :error,
      request_path: unique_path
    )

    entries = find_log_entries(event: "test_error_severity", request_path: unique_path)
    assert_equal 1, entries.size

    entry = entries.first
    assert_equal "error", entry["severity"], "error severity should be persisted"
  end

  test "log entries contain ISO8601 timestamp" do
    unique_ip = "192.168.#{rand(1..254)}.#{rand(1..254)}"

    SecurityAuditLog.log_logout(user: @user, ip: unique_ip)

    entries = find_log_entries(event: "logout", ip: unique_ip)
    assert_equal 1, entries.size

    entry = entries.first
    # ISO8601 timestamp with milliseconds: 2024-01-15T12:34:56.789Z
    assert_match(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}/, entry["timestamp"])
  end

  test "log_content_deleted logs admin content deletion with snapshot" do
    tenant = create_tenant
    admin = create_user
    author = create_user
    collective = create_collective(tenant: tenant, created_by: admin)
    Tenant.current_id = tenant.id
    note = create_note(tenant: tenant, collective: collective, created_by: author, title: "Bad Post", text: "Offensive content")
    unique_ip = "192.168.#{rand(1..254)}.#{rand(1..254)}"

    SecurityAuditLog.log_content_deleted(
      content: note,
      deleted_by: admin,
      ip: unique_ip,
      snapshot: note.content_snapshot,
    )

    entries = find_log_entries(event: "content_deleted", ip: unique_ip)
    assert_equal 1, entries.size

    entry = entries.first
    assert_equal "warn", entry["severity"]
    assert_equal "Note", entry["content_type"]
    assert_equal note.id, entry["content_id"]
    assert_equal note.truncated_id, entry["content_truncated_id"]
    assert_equal admin.id, entry["deleted_by_id"]
    assert_equal admin.email, entry["deleted_by_email"]
    assert_equal "Bad Post", entry.dig("snapshot", "title")
    assert_equal "Offensive content", entry.dig("snapshot", "text")
  end

  test "log_content_deleted truncates long snapshot values" do
    tenant = create_tenant
    admin = create_user
    collective = create_collective(tenant: tenant, created_by: admin)
    Tenant.current_id = tenant.id
    long_text = "x" * 3000
    note = create_note(tenant: tenant, collective: collective, created_by: admin, text: long_text)
    unique_ip = "192.168.#{rand(1..254)}.#{rand(1..254)}"

    SecurityAuditLog.log_content_deleted(
      content: note,
      deleted_by: admin,
      ip: unique_ip,
      snapshot: note.content_snapshot,
    )

    entries = find_log_entries(event: "content_deleted", ip: unique_ip)
    entry = entries.first
    assert_equal 2000, entry.dig("snapshot", "text").length
  end

  test "nil optional fields are excluded from log entry" do
    unique_ip = "192.168.#{rand(1..254)}.#{rand(1..254)}"

    SecurityAuditLog.log_login_success(
      user: @user,
      ip: unique_ip,
      user_agent: nil
    )

    entries = find_log_entries(event: "login_success", ip: unique_ip)
    assert_equal 1, entries.size

    entry = entries.first
    assert_not entry.key?("user_agent"), "nil user_agent should not be in log entry"
  end
end
