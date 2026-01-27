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
session_options = {
  key: "_harmonic_session",
  same_site: :lax,
}

unless Rails.env.test?
  session_options[:domain] = ".#{ENV['HOSTNAME']}"
  session_options[:secure] = Rails.env.production? || ENV['HOST_MODE'] == 'caddy'
end

Rails.application.config.session_store :cookie_store, **session_options
