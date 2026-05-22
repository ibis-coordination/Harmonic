# typed: false

# Bot-protection middleware that fronts the two OmniAuth-handled POSTs that
# the BotProtection controller concern can't reach (because OmniAuth's Rack
# middleware consumes them before any controller runs):
#
#   POST /auth/identity/register
#   POST /auth/identity/callback
#
# Same honeypot + Turnstile rules as the BotProtection concern. Registered
# in config/initializers/omniauth.rb immediately before
# `Rails.application.config.middleware.use OmniAuth::Builder` so it has
# first crack at the request before OmniAuth handles it.
class OmniAuthBotProtection
  PROTECTED_PATHS = ["/auth/identity/register", "/auth/identity/callback"].freeze
  HONEYPOT_FIELD = "company_website".freeze
  TURNSTILE_TOKEN_FIELD = "cf_turnstile_response".freeze

  def initialize(app)
    @app = app
  end

  def call(env)
    req = Rack::Request.new(env)
    return @app.call(env) unless req.post? && PROTECTED_PATHS.include?(req.path)
    return @app.call(env) if disabled?

    if honeypot_failed?(req)
      log(reason: "honeypot", req: req)
      return bot_response
    end

    if turnstile_enabled? && !TurnstileVerifier.verify(token: req.params[TURNSTILE_TOKEN_FIELD], ip: req.ip)
      log(reason: "turnstile", req: req)
      return bot_response
    end

    @app.call(env)
  end

  private

  def honeypot_failed?(req)
    req.params[HONEYPOT_FIELD].to_s.strip.present?
  end

  def turnstile_enabled?
    ENV["TURNSTILE_SECRET_KEY"].to_s.present?
  end

  def disabled?
    Rails.env.test? && ENV["FORCE_BOT_PROTECTION_IN_TEST"].to_s.empty?
  end

  # No flash: we run before ActionDispatch::Flash has been swept into env, so
  # the cleanly-supported `flash[:alert] = ...` API isn't available here, and
  # writing directly into session["_flash"] couples us to Rails internals.
  # The legitimate user impact is minimal — real users shouldn't ever trip
  # honeypot/Turnstile from these endpoints, and a bare /login bounce is fine
  # for bots. The audit log captures the diagnostic info.
  def bot_response
    [302, { "Location" => "/login", "Content-Type" => "text/html" }, ["Bot check failed"]]
  end

  def log(reason:, req:)
    return unless defined?(SecurityAuditLog)

    SecurityAuditLog.log_bot_signal(
      ip: req.ip,
      path: req.path,
      reason: reason,
      user_id: req.env["rack.session"]&.dig("user_id")
    )
  end
end
