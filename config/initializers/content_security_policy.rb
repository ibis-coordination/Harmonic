# Be sure to restart your server when you modify this file.

# Define an application-wide content security policy
# For further information see the following documentation
# https://developer.mozilla.org/en-US/docs/Web/HTTP/Headers/Content-Security-Policy

Rails.application.configure do
  config.content_security_policy do |policy|
    policy.default_src :self
    policy.font_src    :self, :data
    policy.object_src  :none
    policy.base_uri    :self

    # Allow form submissions to self and any HTTPS destination.
    # OAuth login buttons POST to /auth/:provider (self), then OmniAuth redirects
    # to the provider's authorize URL. WebKit (iOS) checks redirect destinations
    # against form-action, so we must allow HTTPS broadly rather than listing
    # each OAuth provider domain.
    policy.form_action :self, "https:"

    # Images and direct uploads: allow self, data URIs, and DigitalOcean Spaces.
    # `connect_src` is required for Active Storage direct uploads (PUT from
    # browser to Spaces) — without it the browser blocks the request before
    # the CORS preflight even fires.
    spaces_host = if ENV["DO_SPACES_ENDPOINT"].present?
                    URI.parse(ENV["DO_SPACES_ENDPOINT"]).host rescue nil
                  end
    if spaces_host
      spaces_origins = ["https://#{spaces_host}", "https://#{ENV['DO_SPACES_BUCKET']}.#{spaces_host}"]
      policy.img_src :self, :data, *spaces_origins
      policy.connect_src :self, "https://api.drand.sh", *spaces_origins
    else
      policy.img_src :self, :data
      policy.connect_src :self, "https://api.drand.sh"
    end

    # Scripts: self only (no inline scripts without nonce). Cloudflare Turnstile
    # adds challenges.cloudflare.com when the auth-flow bot defense is enabled —
    # without it the widget silently fails to load and every submit is rejected
    # for missing the token.
    turnstile_origin = "https://challenges.cloudflare.com"
    script_sources = [:self]
    script_sources << turnstile_origin if ENV["TURNSTILE_SITE_KEY"].present?
    policy.script_src(*script_sources)

    # Styles: self and unsafe-inline (needed for Turbo/Stimulus and inline styles)
    # TODO: Consider using nonces for inline styles in the future
    policy.style_src :self, :unsafe_inline

    # Frames: the Turnstile widget renders its challenge in an iframe served
    # from challenges.cloudflare.com.
    if ENV["TURNSTILE_SITE_KEY"].present?
      policy.frame_src :self, turnstile_origin
    end

    # Frames: prevent clickjacking by disallowing framing of OUR pages.
    policy.frame_ancestors :none
  end

  # Generate session nonces for permitted importmap and inline scripts
  # Note: Uncomment if you want to use nonces for scripts (requires updating views)
  # config.content_security_policy_nonce_generator = ->(request) { SecureRandom.base64(16) }
  # config.content_security_policy_nonce_directives = %w(script-src)

  # Report CSP violations to a specified URI (uncomment to enable reporting)
  # config.content_security_policy_report_only = true
end
