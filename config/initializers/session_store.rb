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
# every response, so its on-disk lifetime is a *rolling* window equal to the
# idle timeout. A cold start within the idle window now finds the session cookie
# still valid and reuses it — no refresh, no rotation. Past the window the
# cookie is gone and a silent refresh happens exactly as before. The server-side
# idle/absolute checks in `check_session_timeout` are unchanged and remain the
# real authority (the absolute 24h cap still applies regardless of this cookie);
# this only aligns the cookie's browser persistence with the idle timeout so the
# session survives a PWA teardown that happens inside its valid window.
#
# Security: a persistent session cookie is a bearer credential at rest, but it
# is bounded to the idle timeout, stays httponly/secure/same-site, and a durable
# 90-day refresh cookie already sits beside it on the same device. Keeping the
# session cookie ephemeral bought almost nothing (the refresh cookie can
# silently re-mint it anyway) while forcing constant rotation.
#
# NOTE: this default must stay in sync with SESSION_IDLE_TIMEOUT in
# application_controller.rb. We re-parse the env var here (rather than reference
# ApplicationController) to avoid autoloading the controller during boot.
session_idle_timeout = (ENV["SESSION_IDLE_TIMEOUT"]&.to_i || 2.hours).seconds

session_options = {
  key: "_harmonic_session",
  same_site: :lax,
  httponly: true,
  expire_after: session_idle_timeout,
}

unless Rails.env.test?
  session_options[:domain] = ".#{ENV['HOSTNAME']}"
  session_options[:secure] = Rails.env.production? || ENV['HOST_MODE'] == 'caddy'
end

Rails.application.config.session_store :cookie_store, **session_options
