# typed: false

# Public endpoint for receiving external webhook triggers for automation rules.
# This controller handles incoming webhooks without requiring user authentication -
# security is enforced via HMAC signature verification.
#
# Tenant context is derived from the subdomain, like all other controllers.
# Webhook URLs are in the format: https://{subdomain}.harmonic.app/hooks/{webhook_path}
#
# Inherits from ActionController::Base to skip user session/authentication handling,
# but still sets up tenant context from subdomain.
# rubocop:disable Rails/ApplicationController
class IncomingWebhooksController < ActionController::Base
  # rubocop:enable Rails/ApplicationController
  # Skip CSRF since these are external webhook requests
  skip_before_action :verify_authenticity_token

  before_action :set_tenant_context

  # Timestamp tolerance for replay attack prevention (5 minutes)
  TIMESTAMP_TOLERANCE = 5.minutes

  # POST /hooks/:webhook_path
  def receive
    @automation_rule = find_automation_rule
    return render_not_found unless @automation_rule

    # Check signature first (includes missing timestamp/signature check)
    return render_invalid_signature unless signature_present?
    return render_timestamp_expired if timestamp_expired?
    return render_invalid_signature unless verify_signature

    return render_ip_not_allowed unless ip_allowed?
    return render_rule_disabled unless @automation_rule.enabled?

    run = create_rule_run
    queue_execution(run)

    render json: { status: "accepted", run_id: run.id }, status: :ok
  end

  private

  def set_tenant_context
    # Set up tenant context from subdomain
    @current_tenant = Tenant.scope_thread_to_tenant(subdomain: request.subdomain)
  rescue StandardError
    render json: { error: "not_found", message: "Invalid subdomain" }, status: :not_found
  end

  def find_automation_rule
    # Find within the current tenant's automation rules
    AutomationRule.tenant_scoped_only(@current_tenant.id)
      .where(trigger_type: "webhook")
      .find_by(webhook_path: params[:webhook_path])
  end

  def signature_present?
    timestamp = request.headers["X-Harmonic-Timestamp"]
    signature = request.headers["X-Harmonic-Signature"]

    timestamp.present? && signature.present?
  end

  def verify_signature
    timestamp = request.headers["X-Harmonic-Timestamp"]
    signature = request.headers["X-Harmonic-Signature"]

    body = request.raw_post
    WebhookDeliveryService.verify_signature(body, timestamp, signature, @automation_rule.webhook_secret)
  end

  def timestamp_expired?
    timestamp = request.headers["X-Harmonic-Timestamp"]
    return false if timestamp.blank? # Let signature_present? handle blank case

    Time.zone.at(timestamp.to_i) < Time.current - TIMESTAMP_TOLERANCE
  end

  def ip_allowed?
    @automation_rule.ip_allowed?(request.remote_ip)
  end

  def create_rule_run
    AutomationRuleRun.create!(
      automation_rule: @automation_rule,
      tenant_id: @current_tenant.id,
      collective_id: @automation_rule.collective_id,
      trigger_source: "webhook",
      status: "pending",
      trigger_data: {
        "webhook_path" => params[:webhook_path],
        "payload" => parsed_payload,
        "received_at" => Time.current.iso8601,
        "source_ip" => request.remote_ip,
      }
    )
  end

  def parsed_payload
    return nil if request.raw_post.blank?

    JSON.parse(request.raw_post)
  rescue JSON::ParserError
    # For non-JSON payloads, store as raw string
    request.raw_post
  end

  def queue_execution(run)
    AutomationRuleExecutionJob.perform_later(
      automation_rule_run_id: run.id,
      tenant_id: run.tenant_id
    )
  end

  def render_not_found
    render json: { error: "not_found", message: "Webhook path not found" }, status: :not_found
  end

  def render_invalid_signature
    render json: { error: "invalid_signature", message: "Invalid or missing signature" }, status: :unauthorized
  end

  def render_timestamp_expired
    render json: { error: "timestamp_expired", message: "Timestamp is too old" }, status: :unauthorized
  end

  def render_rule_disabled
    render json: { error: "rule_disabled", message: "Automation rule is disabled" }, status: :unprocessable_entity
  end

  def render_ip_not_allowed
    render json: { error: "ip_not_allowed", message: "IP address not in allowlist" }, status: :forbidden
  end
end
