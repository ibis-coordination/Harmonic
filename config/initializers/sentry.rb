# typed: false
# frozen_string_literal: true

# Sentry error tracking configuration
# https://docs.sentry.io/platforms/ruby/guides/rails/

Sentry.init do |config|
  # DSN is required - Sentry is disabled if not set
  config.dsn = ENV.fetch("SENTRY_DSN", nil)

  # Only enable in production and staging environments
  config.enabled_environments = ["production", "staging"]

  # Enable breadcrumbs for debugging context
  config.breadcrumbs_logger = [:active_support_logger, :http_logger]

  # Sample rate for performance monitoring (10% of transactions)
  config.traces_sample_rate = ENV.fetch("SENTRY_TRACES_SAMPLE_RATE", 0.1).to_f

  # Sample rate for profiling (10% of sampled transactions)
  config.profiles_sample_rate = ENV.fetch("SENTRY_PROFILES_SAMPLE_RATE", 0.1).to_f

  # Set the environment
  config.environment = Rails.env

  # Release tracking (use git SHA if available)
  config.release = ENV["GIT_SHA"] || ENV["RENDER_GIT_COMMIT"] || `git rev-parse HEAD 2>/dev/null`.strip.presence

  # Filter sensitive data before sending to Sentry
  config.before_send = lambda do |event, _hint|
    # Filter out health check endpoint errors
    return nil if event.request && event.request.url&.include?("/healthcheck")

    # Remove sensitive headers
    if event.request&.headers
      event.request.headers.delete("Authorization")
      event.request.headers.delete("Cookie")
    end

    event
  end

  # Add custom context to all events
  config.before_send_transaction = lambda do |event, _hint|
    # Sample out health check transactions
    return nil if event.transaction == "HealthcheckController#show"

    event
  end

  # Configure which exceptions to ignore
  config.excluded_exceptions += [
    "ActionController::RoutingError",
    "ActionController::InvalidAuthenticityToken",
    "ActionController::UnknownFormat",
  ]

  # Send default PII (IP address, user email) - disable for stricter privacy
  config.send_default_pii = true
end

# Set user context on each request
# This is done in ApplicationController to have access to current_user
