# typed: true
# frozen_string_literal: true

require "net/http"
require "json"
require "uri"

# AlertService handles sending alerts to external services (Slack, email)
# for security events and operational issues.
#
# Usage:
#   AlertService.notify("Multiple failed login attempts detected", severity: :warning, context: { ip: "1.2.3.4" })
#   AlertService.notify("IP blocked", severity: :critical, context: { ip: "1.2.3.4", reason: "brute_force" })
#
class AlertService
  extend T::Sig

  SEVERITY_LEVELS = T.let([:info, :warning, :critical].freeze, T::Array[Symbol])

  # Throttle settings: max alerts per key per time window
  THROTTLE_WINDOW = T.let(5.minutes, ActiveSupport::Duration)
  THROTTLE_MAX_ALERTS = T.let(3, Integer)

  class << self
    extend T::Sig

    sig { params(message: String, severity: Symbol, context: T::Hash[Symbol, T.untyped]).void }
    def notify(message, severity: :warning, context: {})
      return unless should_alert?(severity)
      return if throttled?(message, severity)

      payload = build_payload(message, severity, context)

      send_to_slack(payload) if slack_configured?
      send_email(payload) if email_configured? && severity == :critical
      log_alert(payload)
    end

    sig { params(event: String, data: T.untyped).void }
    def notify_security_event(event:, **data)
      severity = security_event_severity(event)
      message = format_security_message(event, data)
      notify(message, severity: severity, context: data)
    end

    private

    sig { params(severity: Symbol).returns(T::Boolean) }
    def should_alert?(severity)
      enabled_envs = ["production", "staging"]
      return false unless enabled_envs.include?(Rails.env.to_s) || ENV["ALERT_SERVICE_ENABLED"] == "true"

      SEVERITY_LEVELS.include?(severity)
    end

    sig { params(message: String, severity: Symbol).returns(T::Boolean) }
    def throttled?(message, severity)
      return false unless defined?(Rails.cache) && Rails.cache.respond_to?(:increment)

      # Critical alerts are never throttled
      return false if severity == :critical

      throttle_key = "alert_throttle:#{Digest::MD5.hexdigest(message)}"
      count = Rails.cache.increment(throttle_key, 1, expires_in: THROTTLE_WINDOW, initial: 0)

      # Allow first N alerts, then throttle
      if count && count > THROTTLE_MAX_ALERTS
        Rails.logger.info("[AlertService] Throttled alert: #{message}")
        return true
      end

      false
    end

    sig { params(message: String, severity: Symbol, context: T::Hash[Symbol, T.untyped]).returns(T::Hash[Symbol, T.untyped]) }
    def build_payload(message, severity, context)
      {
        message: message,
        severity: severity,
        timestamp: Time.current.iso8601,
        environment: Rails.env,
        hostname: ENV.fetch("HOSTNAME", "unknown"),
        context: context,
      }
    end

    sig { params(payload: T::Hash[Symbol, T.untyped]).void }
    def send_to_slack(payload)
      webhook_url = ENV.fetch("SLACK_WEBHOOK_URL", nil)
      return if webhook_url.blank?

      slack_message = format_slack_message(payload)

      Thread.new do
        uri = URI.parse(webhook_url)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = true
        http.open_timeout = 5
        http.read_timeout = 5

        request = Net::HTTP::Post.new(uri.request_uri)
        request["Content-Type"] = "application/json"
        request.body = slack_message.to_json

        response = http.request(request)
        Rails.logger.error("[AlertService] Slack webhook failed: #{response.code} #{response.body}") unless response.is_a?(Net::HTTPSuccess)
      rescue StandardError => e
        Rails.logger.error("[AlertService] Slack webhook error: #{e.message}")
      end
    end

    sig { params(payload: T::Hash[Symbol, T.untyped]).returns(T::Hash[Symbol, T.untyped]) }
    def format_slack_message(payload)
      emoji = case payload[:severity]
              when :critical then ":rotating_light:"
              when :warning then ":warning:"
              else ":information_source:"
              end

      color = case payload[:severity]
              when :critical then "#dc3545"  # red
              when :warning then "#ffc107"   # yellow
              else "#17a2b8" # blue
              end

      {
        attachments: [
          {
            color: color,
            blocks: [
              {
                type: "header",
                text: {
                  type: "plain_text",
                  text: "#{emoji} Harmonic Alert - #{payload[:severity].to_s.upcase}",
                  emoji: true,
                },
              },
              {
                type: "section",
                text: {
                  type: "mrkdwn",
                  text: payload[:message],
                },
              },
              {
                type: "context",
                elements: [
                  {
                    type: "mrkdwn",
                    text: "*Environment:* #{payload[:environment]} | *Time:* #{payload[:timestamp]}",
                  },
                ],
              },
            ],
          },
        ],
      }
    end

    sig { params(payload: T::Hash[Symbol, T.untyped]).void }
    def send_email(payload)
      recipients = ENV.fetch("ALERT_EMAIL_RECIPIENTS", nil)
      return if recipients.blank?

      # Use ActionMailer if configured
      if defined?(AlertMailer)
        AlertMailer.critical_alert(
          recipients: recipients.split(",").map(&:strip),
          subject: "[CRITICAL] Harmonic Alert: #{payload[:message].truncate(50)}",
          payload: payload
        ).deliver_later
      end
    rescue StandardError => e
      Rails.logger.error("[AlertService] Email alert error: #{e.message}")
    end

    sig { params(payload: T::Hash[Symbol, T.untyped]).void }
    def log_alert(payload)
      Rails.logger.tagged("ALERT") do
        Rails.logger.send(
          payload[:severity] == :critical ? :error : :warn,
          payload.to_json
        )
      end
    end

    sig { returns(T::Boolean) }
    def slack_configured?
      ENV["SLACK_WEBHOOK_URL"].present?
    end

    sig { returns(T::Boolean) }
    def email_configured?
      ENV["ALERT_EMAIL_RECIPIENTS"].present?
    end

    sig { params(event: String).returns(Symbol) }
    def security_event_severity(event)
      case event
      when "ip_blocked", "rate_limited"
        :warning
      else
        :info
      end
    end

    sig { params(event: String, data: T::Hash[Symbol, T.untyped]).returns(String) }
    def format_security_message(event, data)
      case event
      when "ip_blocked"
        "IP address blocked: #{data[:ip]} (#{data[:matched]})"
      when "rate_limited"
        "Rate limited: #{data[:ip]} on #{data[:request_path]} (#{data[:matched]})"
      when "login_failure"
        "Failed login attempt for #{data[:email]} from #{data[:ip]}"
      else
        "Security event: #{event} - #{data.inspect}"
      end
    end
  end
end
