# frozen_string_literal: true

# Configure session cookies to be shared across all subdomains.
# This ensures that logging out on any subdomain destroys the session everywhere.
#
# We explicitly set the domain with a leading dot (e.g., ".harmonic.local")
# to share cookies across all subdomains like:
# - app.harmonic.local
# - auth.harmonic.local
# - second.harmonic.local
#
# This matches the pattern used for other shared cookies in SessionsController
# (token, redirect_to_subdomain, etc.) and avoids potential issues with the
# :all option on .local domains.
#
# Note: The auth flow in SessionsController is designed to work with shared
# sessions - it uses encrypted token cookies to pass user_id between subdomains,
# then sets the session fresh on the target tenant subdomain.
#
# In test environment, we skip the domain setting because Rails' integration
# test framework doesn't fully support domain-scoped cookies.
# Persist the session cookie on disk for the idle-timeout window instead of
# leaving it session-scoped. Without `expire_after`, `_harmonic_session` is a
# browser-session cookie: the browser drops it when the browsing session ends.
# On an iOS PWA, iOS suspends and reaps the standalone web view whenever the app
# is backgrounded, so every cold launch arrived with no session cookie but a
# live 90-day refresh cookie next to it — which forced a silent refresh, and
# therefore a token rotation, on every single app open. That rotation churn is
# the root cause behind #326 (each rotation left a predecessor row that was
# being counted as a phantom device).
#
# `expire_after` makes the cookie durable but bounded: Rails rewrites it on
# every response, so its on-disk lifetime is a *rolling* window. A cold start
# within that window now finds the session cookie still valid and reuses it —
# no refresh, no rotation.
#
# Crucially, `expire_after` must be set LONGER than the longest server-side
# timeout, NOT equal to the idle timeout. `expire_after` does not just set the
# browser's cookie lifetime — Rails' CookieStore also embeds an expiry in the
# encrypted payload and, once it passes, treats the session as *empty* on the
# server side (blank `session[:user_id]`) before any controller code runs. The
# real expiry authority is `check_session_timeout` in application_controller.rb:
# it is the code that emits the user-facing "expired due to inactivity" / "session
# has expired" flash AND writes the `SecurityAuditLog.log_logout` event. If the
# cookie's own expiry fired first (as it did when this was set to the idle
# timeout), the session would be silently wiped before that check could run — no
# flash, no audit event. So the cookie is given headroom past the absolute cap
# and acts purely as a persistence backstop; `check_session_timeout` remains the
# sole authority on when and how a session ends.
#
# Security: a persistent session cookie is a bearer credential at rest, but its
# *validity* is still gated entirely server-side by the 2h-idle / 24h-absolute
# checks (a cookie the browser keeps past those is rejected on the next request),
# it stays httponly/secure/same-site, and a durable 90-day refresh cookie already
# sits beside it on the same device. A longer at-rest window adds no exposure
# (the credential is dead server-side long before the cookie file expires) and
# strictly helps observability: the server gets to log the timeout rather than
# the browser silently forgetting the cookie.
#
# NOTE: this default must stay in sync with SESSION_ABSOLUTE_TIMEOUT in
# application_controller.rb. We re-parse the env var here (rather than reference
# ApplicationController) to avoid autoloading the controller during boot.
session_absolute_timeout = (ENV["SESSION_ABSOLUTE_TIMEOUT"]&.to_i || 24.hours).seconds

session_options = {
  key: "_harmonic_session",
  same_site: :lax,
  httponly: true,
  # 2x the absolute cap: comfortably beyond any valid session so the server-side
  # timeout checks always fire before the cookie itself expires.
  expire_after: session_absolute_timeout * 2,
}

unless Rails.env.test?
  session_options[:domain] = ".#{ENV['HOSTNAME']}"
  session_options[:secure] = Rails.env.production? || ENV['HOST_MODE'] == 'caddy'
end

Rails.application.config.session_store :cookie_store, **session_options
