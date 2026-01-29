# typed: false
# frozen_string_literal: true

# Security checks that run at application startup.
# These checks prevent the application from starting with insecure configurations.

if Rails.env.production?
  # Prevent honor_system auth mode in production.
  # Honor system bypasses all authentication and should NEVER be used in production.
  if ENV["AUTH_MODE"] == "honor_system"
    raise <<~ERROR
      SECURITY ERROR: AUTH_MODE=honor_system is not allowed in production!

      Honor system authentication bypasses all security checks and allows
      anyone to impersonate any user. This mode is only intended for local
      development and testing.

      To fix this, set AUTH_MODE=oauth in your environment configuration.
    ERROR
  end
end
