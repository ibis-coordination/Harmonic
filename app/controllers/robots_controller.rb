# typed: false

# Serves /robots.txt per-tenant. Inherits from ActionController::Base (not
# ApplicationController) so it skips the auth/tenant/billing pipeline — this
# is a meta-file for crawlers, not a user-facing page.
class RobotsController < ActionController::Base # rubocop:disable Rails/ApplicationController
  PRIVATE_BODY = "User-agent: *\nDisallow: /\n".freeze

  def show
    tenant = Tenant.find_by(subdomain: request.subdomain)
    expires_in 1.hour, public: false
    response.set_header("X-Robots-Tag", "noindex")

    body = if tenant&.public_main_collective?
             public_body(sitemap_url_for(tenant))
           else
             PRIVATE_BODY
           end
    render plain: body, content_type: "text/plain"
  end

  private

  # Build the canonical sitemap URL from the configured HOSTNAME + tenant
  # subdomain — NOT request.host_with_port, which can carry internal values
  # (e.g. an upstream port) when behind a reverse proxy/CDN.
  def sitemap_url_for(tenant)
    protocol = ENV["HOSTNAME"].to_s.include?("localhost") ? "http" : "https"
    "#{protocol}://#{tenant.subdomain}.#{ENV.fetch('HOSTNAME', nil)}/sitemap.xml"
  end

  def public_body(sitemap_url)
    <<~TXT
      User-agent: *
      Disallow: /

      Allow: /n/
      Allow: /d/
      Allow: /c/
      Allow: /u/
      Allow: /help
      Allow: /help/

      Sitemap: #{sitemap_url}
    TXT
  end
end
