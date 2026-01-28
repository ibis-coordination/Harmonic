# typed: true

# SecurityAuditLog provides structured logging for security-relevant events.
# Logs are written in JSON format to facilitate aggregation and alerting.
#
# Events logged:
# - Authentication: login success/failure, logout, session creation
# - Authorization: permission denied, admin actions
# - Account changes: password reset, email change
#
# Usage:
#   SecurityAuditLog.log_login_success(user: user, ip: request.remote_ip)
#   SecurityAuditLog.log_login_failure(email: email, ip: request.remote_ip, reason: "invalid_password")
#
class SecurityAuditLog
  extend T::Sig

  LOGGER = ActiveSupport::TaggedLogging.new(
    ActiveSupport::Logger.new(
      Rails.root.join("log/security_audit.log"),
      1, # Keep 1 old log file
      50.megabytes # Rotate at 50MB
    )
  )

  # Authentication events

  sig { params(user: User, ip: String, user_agent: T.nilable(String)).void }
  def self.log_login_success(user:, ip:, user_agent: nil)
    log_event(
      event: "login_success",
      severity: :info,
      user_id: user.id,
      email: user.email,
      ip: ip,
      user_agent: user_agent
    )
  end

  sig { params(email: String, ip: String, reason: String, user_agent: T.nilable(String)).void }
  def self.log_login_failure(email:, ip:, reason:, user_agent: nil)
    log_event(
      event: "login_failure",
      severity: :warn,
      email: email,
      ip: ip,
      reason: reason,
      user_agent: user_agent
    )
  end

  sig { params(user: User, ip: String, reason: T.nilable(String)).void }
  def self.log_logout(user:, ip:, reason: nil)
    log_event(
      event: "logout",
      severity: :info,
      user_id: user.id,
      email: user.email,
      ip: ip,
      reason: reason,
    )
  end

  # Password events

  sig { params(email: String, ip: String).void }
  def self.log_password_reset_requested(email:, ip:)
    log_event(
      event: "password_reset_requested",
      severity: :info,
      email: email,
      ip: ip
    )
  end

  sig { params(user: User, ip: String).void }
  def self.log_password_changed(user:, ip:)
    log_event(
      event: "password_changed",
      severity: :info,
      user_id: user.id,
      email: user.email,
      ip: ip
    )
  end

  # Authorization events

  sig { params(user: User, ip: String, resource: String, action: String).void }
  def self.log_permission_denied(user:, ip:, resource:, action:)
    log_event(
      event: "permission_denied",
      severity: :warn,
      user_id: user.id,
      email: user.email,
      ip: ip,
      resource: resource,
      action: action
    )
  end

  # Admin events

  sig { params(admin: User, ip: String, action: String, target_user_id: T.nilable(String), details: T::Hash[Symbol, T.untyped]).void }
  def self.log_admin_action(admin:, ip:, action:, target_user_id: nil, details: {})
    # Sorbet doesn't support mixing explicit keyword args with splats, so use T.unsafe
    T.unsafe(self).log_event(
      event: "admin_action",
      severity: :info,
      user_id: admin.id,
      email: admin.email,
      ip: ip,
      admin_action: action,
      target_user_id: target_user_id,
      **details
    )
  end

  # Rate limiting events

  sig { params(ip: String, matched: String, request_path: String).void }
  def self.log_rate_limited(ip:, matched:, request_path:)
    log_event(
      event: "rate_limited",
      severity: :warn,
      ip: ip,
      matched: matched,
      request_path: request_path
    )

    # Alert for rate limiting on sensitive endpoints
    if request_path.include?("/login") || request_path.include?("/password")
      AlertService.notify_security_event(
        event: "rate_limited",
        ip: ip,
        matched: matched,
        request_path: request_path
      )
    end
  end

  # IP blocking events

  sig { params(ip: String, matched: String).void }
  def self.log_ip_blocked(ip:, matched:)
    log_event(
      event: "ip_blocked",
      severity: :warn,
      ip: ip,
      matched: matched
    )

    # Always alert on IP blocks
    AlertService.notify_security_event(
      event: "ip_blocked",
      ip: ip,
      matched: matched
    )
  end

  # Generic event logging

  sig { params(event: String, severity: Symbol, data: T.untyped).void }
  def self.log_event(event:, severity: :info, **data)
    payload = {
      timestamp: Time.current.iso8601(3),
      event: event,
      environment: Rails.env,
      **data.compact,
    }.to_json

    case severity
    when :debug then LOGGER.debug(payload)
    when :warn then LOGGER.warn(payload)
    when :error then LOGGER.error(payload)
    else LOGGER.info(payload)
    end

    # Also log to Rails logger in production for centralized logging
    return unless Rails.env.production?

    # Rails.logger is TaggedLogging in production, but Sorbet doesn't know that
    T.unsafe(Rails.logger).tagged("SECURITY_AUDIT") { Rails.logger.send(severity, payload) }
  end
end
