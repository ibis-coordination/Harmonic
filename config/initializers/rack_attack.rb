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
end

# Configure cache store for Rack::Attack
# Use Redis for better performance and persistence across server restarts
Rack::Attack.cache.store = ActiveSupport::Cache::RedisCacheStore.new(
  url: ENV['REDIS_URL'],
  namespace: 'rack_attack'
)
