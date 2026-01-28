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

  # Two-Factor Authentication events

  sig { params(identity: OmniAuthIdentity, ip: String).void }
  def self.log_2fa_success(identity:, ip:)
    log_event(
      event: "2fa_success",
      severity: :info,
      email: identity.email,
      ip: ip
    )
  end

  sig { params(identity: OmniAuthIdentity, ip: String).void }
  def self.log_2fa_failure(identity:, ip:)
    log_event(
      event: "2fa_failure",
      severity: :warn,
      email: identity.email,
      ip: ip,
      failed_attempts: identity.otp_failed_attempts
    )
  end

  sig { params(identity: OmniAuthIdentity, ip: String).void }
  def self.log_2fa_lockout(identity:, ip:)
    log_event(
      event: "2fa_lockout",
      severity: :warn,
      email: identity.email,
      ip: ip,
      locked_until: identity.otp_locked_until&.iso8601
    )

    # Alert on 2FA lockouts (potential brute force attack)
    AlertService.notify_security_event(
      event: "2fa_lockout",
      email: identity.email,
      ip: ip
    )
  end

  sig { params(identity: OmniAuthIdentity, ip: String).void }
  def self.log_2fa_enabled(identity:, ip:)
    log_event(
      event: "2fa_enabled",
      severity: :info,
      email: identity.email,
      ip: ip
    )
  end

  sig { params(identity: OmniAuthIdentity, ip: String).void }
  def self.log_2fa_disabled(identity:, ip:)
    log_event(
      event: "2fa_disabled",
      severity: :info,
      email: identity.email,
      ip: ip
    )
  end

  sig { params(identity: OmniAuthIdentity, ip: String, remaining_codes: Integer).void }
  def self.log_2fa_recovery_code_used(identity:, ip:, remaining_codes:)
    log_event(
      event: "2fa_recovery_code_used",
      severity: :info,
      email: identity.email,
      ip: ip,
      remaining_codes: remaining_codes
    )
  end

  sig { params(identity: OmniAuthIdentity, ip: String).void }
  def self.log_2fa_recovery_codes_regenerated(identity:, ip:)
    log_event(
      event: "2fa_recovery_codes_regenerated",
      severity: :info,
      email: identity.email,
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

  # User suspension events

  sig { params(user: User, suspended_by: User, reason: String, ip: String).void }
  def self.log_user_suspended(user:, suspended_by:, reason:, ip:)
    log_event(
      event: "user_suspended",
      severity: :warn,
      user_id: user.id,
      email: user.email,
      suspended_by_id: suspended_by.id,
      suspended_by_email: suspended_by.email,
      reason: reason,
      ip: ip
    )

    AlertService.notify_security_event(
      event: "user_suspended",
      email: user.email,
      suspended_by: suspended_by.email,
      reason: reason,
      ip: ip
    )
  end

  sig { params(user: User, unsuspended_by: User, ip: String).void }
  def self.log_user_unsuspended(user:, unsuspended_by:, ip:)
    log_event(
      event: "user_unsuspended",
      severity: :info,
      user_id: user.id,
      email: user.email,
      unsuspended_by_id: unsuspended_by.id,
      unsuspended_by_email: unsuspended_by.email,
      ip: ip
    )
  end

  sig { params(user: User, ip: String).void }
  def self.log_suspended_login_attempt(user:, ip:)
    log_event(
      event: "suspended_login_attempt",
      severity: :warn,
      user_id: user.id,
      email: user.email,
      ip: ip
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
