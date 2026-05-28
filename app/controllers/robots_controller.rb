# typed: false

# Serves /robots.txt per-tenant. Inherits from ActionController::Base (not
# ApplicationController) so it skips the auth/tenant/billing pipeline — this
# is a meta-file for crawlers, not a user-facing page.
class RobotsController < ActionController::Base # rubocop:disable Rails/ApplicationController
  PRIVATE_BODY = "User-agent: *\nDisallow: /\n".freeze

  PUBLIC_BODY = <<~TXT.freeze
    User-agent: *
    Disallow: /

    Allow: /n/
    Allow: /d/
    Allow: /c/
    Allow: /u/
    Allow: /help
    Allow: /help/
  TXT

  def show
    tenant = Tenant.find_by(subdomain: request.subdomain)
    expires_in 1.hour, public: false
    response.set_header("X-Robots-Tag", "noindex")
    body = tenant&.public_main_collective? ? PUBLIC_BODY : PRIVATE_BODY
    render plain: body, content_type: "text/plain"
  end
end
