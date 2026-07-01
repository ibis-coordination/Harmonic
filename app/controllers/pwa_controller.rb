# typed: true

# Serves the service worker and the offline fallback page. Does not inherit
# from ApplicationController: both routes must be public (the browser
# re-fetches /service-worker.js outside any session; /offline is pre-cached
# and shown when the network is down), and neither needs tenant
# thread-scoping — the feature flag check resolves the tenant directly from
# the request subdomain.
class PwaController < ActionController::Base # rubocop:disable Rails/ApplicationController
  extend T::Sig

  # Forgery protection's same-origin check rejects plain (non-XHR) GETs for
  # JavaScript, which is exactly how browsers fetch a service worker script.
  # The check exists to keep user-specific JS from being <script>-embedded
  # cross-site; nothing here is user-specific.
  skip_forgery_protection

  def service_worker
    # Browsers honor HTTP caching for SW script update checks; no-cache makes
    # a deploy (new CACHE_VERSION) and a flag flip (unregister stub) take
    # effect on the next check instead of after a stale-cache window.
    response.headers["Cache-Control"] = "no-cache"

    template = service_worker_enabled? ? :service_worker : :unregister
    render template, layout: false, content_type: "text/javascript"
  end

  def offline
    render layout: false
  end

  private

  sig { returns(T::Boolean) }
  def service_worker_enabled?
    tenant = Tenant.find_by(subdomain: request.subdomain)
    tenant.present? && FeatureFlagService.enabled?("service_worker", tenant: tenant)
  end
end
