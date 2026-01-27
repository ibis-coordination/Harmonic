# typed: true

# SecurityAuditLogReader provides methods to read and aggregate security audit log data.
# Used by the admin security dashboard to display metrics and recent events.
#
# Usage:
#   SecurityAuditLogReader.summary(since: 24.hours.ago)
#   SecurityAuditLogReader.recent_events(limit: 100)
#   SecurityAuditLogReader.events_by_type("login_failure", limit: 50)
#
class SecurityAuditLogReader
  extend T::Sig

  LOG_FILE = Rails.root.join("log/security_audit.log")

  # Event types tracked by SecurityAuditLog
  EVENT_TYPES = [
    "login_success",
    "login_failure",
    "logout",
    "password_reset_requested",
    "password_changed",
    "permission_denied",
    "admin_action",
    "rate_limited",
    "ip_blocked",
  ].freeze

  # Summary of security events within a time window
  sig { params(since: ActiveSupport::TimeWithZone).returns(T::Hash[String, Integer]) }
  def self.summary(since: 24.hours.ago)
    counts = EVENT_TYPES.index_with { 0 }

    each_entry do |entry|
      timestamp = parse_timestamp(entry["timestamp"])
      next if timestamp.nil? || timestamp < since

      event = entry["event"]
      counts[event] = counts.fetch(event, 0) + 1 if event.present?
    end

    counts
  end

  # Recent security events, newest first
  sig { params(limit: Integer).returns(T::Array[T::Hash[String, T.untyped]]) }
  def self.recent_events(limit: 100)
    events = []

    each_entry do |entry|
      events << entry
    end

    # Sort by timestamp descending (newest first) and limit
    events
      .sort_by { |e| e["timestamp"] || "" }
      .reverse
      .first(limit)
  end

  # Events filtered by type, newest first
  sig { params(event_type: String, limit: Integer).returns(T::Array[T::Hash[String, T.untyped]]) }
  def self.events_by_type(event_type, limit: 50)
    events = []

    each_entry do |entry|
      events << entry if entry["event"] == event_type
    end

    events
      .sort_by { |e| e["timestamp"] || "" }
      .reverse
      .first(limit)
  end

  # Top IPs by event count within a time window
  sig { params(since: ActiveSupport::TimeWithZone, limit: Integer).returns(T::Array[[String, Integer]]) }
  def self.top_ips(since: 24.hours.ago, limit: 10)
    ip_counts = Hash.new(0)

    each_entry do |entry|
      timestamp = parse_timestamp(entry["timestamp"])
      next if timestamp.nil? || timestamp < since

      ip = entry["ip"]
      ip_counts[ip] += 1 if ip.present?
    end

    ip_counts.sort_by { |_ip, count| -count }.first(limit)
  end

  # Events from a specific IP, newest first
  sig { params(ip: String, limit: Integer).returns(T::Array[T::Hash[String, T.untyped]]) }
  def self.events_by_ip(ip, limit: 50)
    events = []

    each_entry do |entry|
      events << entry if entry["ip"] == ip
    end

    events
      .sort_by { |e| e["timestamp"] || "" }
      .reverse
      .first(limit)
  end

  # Get a single event by line number (1-indexed)
  sig { params(line_number: Integer).returns(T.nilable(T::Hash[String, T.untyped])) }
  def self.event_at_line(line_number)
    return nil unless log_exists?
    return nil if line_number < 1

    each_entry_with_line do |entry, index|
      return entry.merge("line_number" => index) if index == line_number
    end

    nil
  end

  # Filtered events with sorting and pagination options
  # Returns a hash with :events (paginated results) and :total_count (for pagination UI)
  sig do
    params(
      event_type: T.nilable(String),
      ip: T.nilable(String),
      email: T.nilable(String),
      since: T.nilable(ActiveSupport::TimeWithZone),
      sort_by: String,
      sort_dir: String,
      page: Integer,
      per_page: Integer
    ).returns({ events: T::Array[T::Hash[String, T.untyped]], total_count: Integer })
  end
  def self.filtered_events(event_type: nil, ip: nil, email: nil, since: nil, sort_by: "timestamp", sort_dir: "desc", page: 1, per_page: 50)
    events = []

    each_entry_with_line do |entry, line_number|
      # Apply filters
      next if event_type.present? && entry["event"] != event_type
      next if ip.present? && entry["ip"] != ip
      next if email.present? && entry["email"] != email

      if since.present?
        timestamp = parse_timestamp(entry["timestamp"])
        next if timestamp.nil? || timestamp < since
      end

      events << entry.merge("line_number" => line_number)
    end

    total_count = events.size

    # Sort
    events = events.sort_by { |e| e[sort_by] || "" }
    events = events.reverse if sort_dir == "desc"

    # Paginate
    offset = (page - 1) * per_page
    paginated_events = events.slice(offset, per_page) || []

    { events: paginated_events, total_count: total_count }
  end

  # Check if log file exists and is readable
  sig { returns(T::Boolean) }
  def self.log_exists?
    File.exist?(LOG_FILE) && File.readable?(LOG_FILE)
  end

  # Private: Iterate over each valid log entry
  sig { params(_block: T.proc.params(entry: T::Hash[String, T.untyped]).void).void }
  def self.each_entry(&_block)
    return unless log_exists?

    File.foreach(LOG_FILE) do |line|
      entry = JSON.parse(line)
      yield entry
    rescue JSON::ParserError
      # Skip malformed lines
      next
    end
  end
  private_class_method :each_entry

  # Private: Iterate over each valid log entry with line number (1-indexed)
  sig { params(_block: T.proc.params(entry: T::Hash[String, T.untyped], line_number: Integer).void).void }
  def self.each_entry_with_line(&_block)
    return unless log_exists?

    File.foreach(LOG_FILE).with_index(1) do |line, index|
      entry = JSON.parse(line)
      yield entry, index
    rescue JSON::ParserError
      # Skip malformed lines
      next
    end
  end
  private_class_method :each_entry_with_line

  # Private: Parse ISO8601 timestamp string
  sig { params(timestamp_str: T.nilable(String)).returns(T.nilable(ActiveSupport::TimeWithZone)) }
  def self.parse_timestamp(timestamp_str)
    return nil if timestamp_str.blank?

    Time.zone.parse(timestamp_str)
  rescue ArgumentError
    nil
  end
  private_class_method :parse_timestamp
end
