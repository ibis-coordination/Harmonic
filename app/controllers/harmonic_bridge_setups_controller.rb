# typed: false

# Public, one-time-use harmonic-bridge setup redemption endpoints.
#
# Both actions are unauthenticated — possession of the URL's :public_id is
# the credential. The URL is high-entropy, short-lived (15 min default), and
# single-use per action:
#
#   GET  /bridge-setups/:public_id          → mints the MCP token and the
#                                             signing secret, returns both
#                                             plus the metadata bundle. The
#                                             bridge needs the signing
#                                             secret on disk before its
#                                             daemon can validate the
#                                             verification POST that arrives
#                                             during the next step.
#   POST /bridge-setups/:public_id/webhook  → registers the notification
#                                             webhook, sends a synchronous
#                                             test delivery to the supplied
#                                             URL, returns 200 on success.
#                                             On verification failure, both
#                                             the token and the webhook
#                                             subscription are destroyed —
#                                             the bridge must start over
#                                             with a fresh setup URL.
#
# Tenant context comes from request.subdomain via ApplicationController's
# standard before_action chain — no special routing.
class HarmonicBridgeSetupsController < ApplicationController
  # No authenticity token: these endpoints are called by `harmonic-bridge add`, not
  # by browsers with session cookies. The URL itself is the credential.
  skip_before_action :verify_authenticity_token

  # The :public_id in the URL is the credential — these actions are
  # authenticated by URL possession, same shape as password-reset or
  # email-confirmation endpoints elsewhere in the app.
  def token_authenticated_action?
    true
  end

  def show
    setup = find_redeemable_setup
    return render_not_found if setup.nil?

    credentials = setup.redeem!

    render json: {
      harmonic_mcp_endpoint: mcp_endpoint_url,
      harmonic_token: credentials[:harmonic_token],
      signing_secret: credentials[:signing_secret],
      agent_handle: handle_for(setup.ai_agent_user),
      webhook_register_url: harmonic_bridge_setup_webhook_url(public_id: setup.public_id),
      events_recommended: setup.events_recommended,
    }
  rescue HarmonicBridgeSetup::Expired, HarmonicBridgeSetup::Redeemed
    render_not_found
  end

  def register_webhook
    return render_unprocessable("webhook_url is required") if params[:webhook_url].blank?
    return render_unprocessable("webhook_url must be https without embedded credentials") unless valid_https_url?(params[:webhook_url])

    setup = find_setup_awaiting_webhook
    return render_not_found if setup.nil?

    events = events_param.presence || setup.events_recommended
    setup.complete!(webhook_url: params[:webhook_url], events: events)

    verification = WebhookTestDelivery.deliver(url: params[:webhook_url], secret: setup.automation_rule.webhook_secret)
    unless verification.ok
      setup.revert_completion!
      return render status: :unprocessable_entity,
                    json: { error: "webhook_unreachable", detail: verification.error.to_s }
    end

    render json: { ok: true }
  rescue HarmonicBridgeSetup::Expired, HarmonicBridgeSetup::NotYetRedeemed, HarmonicBridgeSetup::WebhookAlreadyRegistered
    render_not_found
  end

  private

  def find_redeemable_setup
    setup = HarmonicBridgeSetup.find_by(public_id: params[:public_id])
    return nil if setup.nil? || !setup.redeemable?

    setup
  end

  def find_setup_awaiting_webhook
    setup = HarmonicBridgeSetup.find_by(public_id: params[:public_id])
    return nil if setup.nil? || !setup.webhook_registerable?

    setup
  end

  def render_not_found
    render status: :not_found, json: { error: "not found" }
  end

  def render_unprocessable(message)
    render status: :unprocessable_entity, json: { error: message }
  end

  def events_param
    value = params[:events]
    return [] if value.blank?

    Array(value).map(&:to_s)
  end

  def mcp_endpoint_url
    "#{request.protocol}#{request.host_with_port}/mcp"
  end

  def valid_https_url?(url)
    uri = URI.parse(url)
    return false unless uri.is_a?(URI::HTTPS) && uri.host.present?
    return false if uri.userinfo.present?

    true
  rescue URI::InvalidURIError
    false
  end

  def handle_for(user)
    user.tenant_users.find_by(tenant_id: current_tenant.id)&.handle
  end
end
