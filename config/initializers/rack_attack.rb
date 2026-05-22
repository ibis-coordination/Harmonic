# Rack Attack configuration for rate limiting
class Rack::Attack
  # Always allow requests from localhost
  safelist('allow-localhost') do |req|
    req.ip == '127.0.0.1' || req.ip == '::1'
  end

  # Allow requests from Docker network (for e2e tests in development/test only)
  if Rails.env.development? || Rails.env.test?
    safelist('allow-docker-network') do |req|
      req.ip&.start_with?('192.168.') || req.ip&.start_with?('172.')
    end
  end

  # Skip throttling for health checks and static assets
  safelist('allow-healthcheck') do |req|
    req.path == '/healthcheck'
  end

  # General request throttle - 300 requests per minute per IP
  # This provides baseline protection against abuse while allowing normal usage
  throttle('req/ip', limit: 300, period: 1.minute) do |req|
    req.ip unless req.path.start_with?('/assets')
  end

  # Stricter throttle for write operations (POST/PUT/PATCH/DELETE)
  # 60 write requests per minute per IP
  throttle('writes/ip', limit: 60, period: 1.minute) do |req|
    if %w[POST PUT PATCH DELETE].include?(req.request_method)
      req.ip
    end
  end

  # Throttle login attempts by IP address
  throttle('login/ip', limit: 5, period: 20.minutes) do |req|
    if req.path == '/auth/identity/callback' && req.post?
      req.ip
    end
  end

  # Throttle login attempts by email
  throttle('login/email', limit: 5, period: 20.minutes) do |req|
    if req.path == '/auth/identity/callback' && req.post?
      # Get email from form data
      req.params.dig('auth_key') || req.params.dig('email')
    end
  end

  # Throttle password reset requests
  throttle('password-reset/ip', limit: 5, period: 1.hour) do |req|
    if req.path.start_with?('/password') && req.post?
      req.ip
    end
  end

  # Throttle 2FA verification attempts
  throttle('2fa/ip', limit: 10, period: 15.minutes) do |req|
    if req.path == '/login/verify-2fa' && req.post?
      req.ip
    end
  end

  # Throttle email change requests
  throttle('email-change/ip', limit: 5, period: 1.hour) do |req|
    if req.path.match?(%r{/u/[^/]+/settings/email\z}) && req.patch?
      req.ip
    end
  end

  # Throttle OAuth callback requests
  throttle('oauth-callback/ip', limit: 10, period: 5.minutes) do |req|
    if req.path.start_with?('/auth/') && req.post?
      req.ip
    end
  end

  # Block IP addresses that make too many requests
  blocklist('block-bad-actors') do |req|
    # Block if more than 100 requests in 5 minutes
    Rack::Attack::Allow2Ban.filter(req.ip, maxretry: 5, findtime: 5.minutes, bantime: 1.hour) do
      # Return true if this IP should be blocked
      req.env['rack.attack.matched'] && req.env['rack.attack.match_type'] == :throttle
    end
  end
  # Invite-code submission. Tight enough to make code brute-force impractical:
  # 5 attempts per hour from an IP, with a per-user backstop so a single bot
  # session rotating IPs is still capped at 10/hour.
  throttle('invite_required/ip', limit: 5, period: 1.hour) do |req|
    req.ip if req.path == '/invite-required' && req.post?
  end

  throttle('invite_required/user', limit: 10, period: 1.hour) do |req|
    if req.path == '/invite-required' && req.post?
      req.env['rack.session']&.dig('user_id')
    end
  end

  # Final tenant + collective join. The code was already validated at the
  # confirm step, but rate-limit anyway to backstop session-hijack scenarios.
  throttle('accept_invite/ip', limit: 10, period: 1.hour) do |req|
    req.ip if req.path == '/invite-required/accept' && req.post?
  end

  # Identity registration. The generic writes/ip throttle (60/min) is the only
  # existing protection on this endpoint; 5/hour is a much tighter cap on
  # mass-account-creation attempts.
  throttle('identity_register/ip', limit: 5, period: 1.hour) do |req|
    req.ip if req.path == '/auth/identity/register' && req.post?
  end

  # Throttle data export requests: 3 per hour per IP
  throttle('exports/ip', limit: 3, period: 1.hour) do |req|
    if req.path.match?(%r{/(?:collectives|workspace)/[^/]+/exports\z}) && req.post?
      req.ip
    end
  end

  # Throttle per-user data export creation: 3 per hour per IP. The endpoint
  # is browser-only (API tokens are blocked at the controller level) and
  # already has an in-process "one active per user" check; this is a backstop
  # against an attacker with a hijacked session enqueuing serial exports.
  throttle('user_data_exports/ip', limit: 3, period: 1.hour) do |req|
    if req.path.match?(%r{/u/[^/]+/settings/data-export\z}) && req.post?
      req.ip
    end
  end

  # Throttle data import requests: 100 per hour per IP. Imports are tenant-admin
  # only and already gated by reverification + ensure_tenant_admin; this throttle
  # is a backstop against compromised-admin or misconfigured-automation abuse, not
  # general anti-spam. A migrating admin doing many sequential imports is normal.
  throttle('imports/ip', limit: 100, period: 1.hour) do |req|
    if req.path == '/tenant-admin/imports' && req.post?
      req.ip
    end
  end
end

# Configure cache store for Rack::Attack
# Use Redis for better performance and persistence across server restarts
Rack::Attack.cache.store = ActiveSupport::Cache::RedisCacheStore.new(
  url: ENV['REDIS_URL'],
  namespace: 'rack_attack'
)

# Log throttled and blocked requests to security audit log
ActiveSupport::Notifications.subscribe('throttle.rack_attack') do |_name, _start, _finish, _id, payload|
  req = payload[:request]
  SecurityAuditLog.log_rate_limited(
    ip: req.ip,
    matched: req.env['rack.attack.matched'],
    request_path: req.path,
  )
end

ActiveSupport::Notifications.subscribe('blocklist.rack_attack') do |_name, _start, _finish, _id, payload|
  req = payload[:request]
  SecurityAuditLog.log_ip_blocked(
    ip: req.ip,
    matched: req.env['rack.attack.matched']
  )
end
