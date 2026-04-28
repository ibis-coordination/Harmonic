# typed: false

# Shared time parsing for controllers that accept scheduled_for parameters.
# Supports ISO 8601, Unix timestamps, relative times (1h, 2d, 1w), and datetime-local.
module ParsesScheduledTime
  extend ActiveSupport::Concern

  private

  def parse_scheduled_time(value, timezone: nil)
    return nil if value.blank?

    result = case value.to_s
    when /^\d{10,}$/ # Unix timestamp (10+ digits)
      Time.at(value.to_i).utc
    when /^\d+[smhdw]$/i # Relative time: 30s, 5m, 1h, 2d, 1w
      parse_relative_time(value)
    when /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}$/ # datetime-local format (no timezone): 2024-01-22T14:00
      tz = timezone.present? ? ActiveSupport::TimeZone[timezone] : nil
      tz ||= @current_tenant&.timezone || ActiveSupport::TimeZone["UTC"]
      tz.parse(value).utc
    when /^\d{4}-\d{2}-\d{2}/ # ISO 8601 with timezone info
      Time.parse(value).utc
    else
      Time.parse(value).utc
    end

    result&.in_time_zone("UTC")
  rescue ArgumentError, TypeError
    nil
  end

  def parse_relative_time(value)
    match = value.to_s.match(/^(\d+)([smhdw])$/i)
    return nil unless match

    amount = match[1].to_i
    unit = match[2].downcase

    case unit
    when "s" then amount.seconds.from_now
    when "m" then amount.minutes.from_now
    when "h" then amount.hours.from_now
    when "d" then amount.days.from_now
    when "w" then amount.weeks.from_now
    end
  end
end
