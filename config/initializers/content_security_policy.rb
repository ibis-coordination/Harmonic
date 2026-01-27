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

    # Allow form submissions to self and all harmonic subdomains
    # This is needed for auth flows that cross subdomains
    hostname = ENV.fetch("HOSTNAME", "harmonic.local")
    policy.form_action :self, "https://*.#{hostname}"

    # Images: allow self, data URIs, and DigitalOcean Spaces (for uploaded files)
    if ENV["DO_SPACES_ENDPOINT"].present?
      # Extract the host from the endpoint URL
      # Allow both path-style (endpoint/bucket) and virtual-hosted (bucket.endpoint) URLs
      spaces_host = URI.parse(ENV["DO_SPACES_ENDPOINT"]).host rescue nil
      if spaces_host
        policy.img_src :self, :data, "https://#{spaces_host}", "https://#{ENV['DO_SPACES_BUCKET']}.#{spaces_host}"
      else
        policy.img_src :self, :data
      end
    else
      policy.img_src :self, :data
    end

    # Scripts: self only (no inline scripts without nonce)
    policy.script_src :self

    # Styles: self and unsafe-inline (needed for Turbo/Stimulus and inline styles)
    # TODO: Consider using nonces for inline styles in the future
    policy.style_src :self, :unsafe_inline

    # Connect: allow self (for fetch/XHR requests)
    policy.connect_src :self

    # Frames: prevent clickjacking by disallowing framing
    policy.frame_ancestors :none
  end

  # Generate session nonces for permitted importmap and inline scripts
  # Note: Uncomment if you want to use nonces for scripts (requires updating views)
  # config.content_security_policy_nonce_generator = ->(request) { SecureRandom.base64(16) }
  # config.content_security_policy_nonce_directives = %w(script-src)

  # Report CSP violations to a specified URI (uncomment to enable reporting)
  # config.content_security_policy_report_only = true
end
