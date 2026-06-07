# typed: false

# Form-based webhook authoring UI for external AI agents.
# Pings a parent's external service when their external agent is @-mentioned
# or receives a comment on their content.
#
# Authors AutomationRule records with the external-agent shape:
#   { webhook_url, payload_template, signing_secret } in actions.
class AgentWebhooksController < ApplicationController
  TRIGGERS = {
    "mention_in_note" => { event_type: "note.created", mention_filter: "self" },
    "mention_in_comment" => { event_type: "comment.created", mention_filter: "self" },
    "comment_on_my_content" => { event_type: "comment.created", mention_filter: "self_or_reply" },
  }.freeze

  TRIGGER_LABELS = {
    "mention_in_note" => "When @-mentioned in a note",
    "mention_in_comment" => "When @-mentioned in a comment",
    "comment_on_my_content" => "When someone comments on my content",
  }.freeze

  TEST_PAYLOAD_EVENT = "harmonic.webhook.test".freeze
  TEST_TIMEOUT_SECONDS = 30

  def current_resource_model
    AutomationRule
  end

  before_action :require_login
  before_action :set_ai_agent
  before_action :authorize_parent_user
  before_action :require_external_agent
  before_action :set_webhook_rule, only: [:edit, :update, :destroy, :test_delivery, :rotate_secret, :toggle]

  # GET /ai-agents/:handle/webhooks
  def index
    @page_title = "Webhooks - #{@ai_agent.display_name}"
    @webhook_rules = webhook_rules_scope.order(created_at: :desc)
  end

  # GET /ai-agents/:handle/webhooks/new
  def new
    @page_title = "New Webhook - #{@ai_agent.display_name}"
    @form = build_form_defaults
  end

  # GET /ai-agents/:handle/webhooks/:id/edit
  def edit
    @page_title = "Edit Webhook - #{@ai_agent.display_name}"
    @form = form_from_rule(@webhook_rule)
    @recent_deliveries = recent_deliveries_for(@webhook_rule)
  end

  # POST /ai-agents/:handle/webhooks
  def create
    @form = form_params
    trigger_config = validate_form_and_resolve_trigger(@form, on_error: :new)
    return unless trigger_config

    secret = generate_signing_secret
    rule = build_webhook_rule(@form, trigger_config, secret)

    if rule.save
      @reveal_secret = secret
      @webhook_rule = rule
      flash.now[:notice] = "Webhook created. Save the signing secret below — it won't be shown again."
      no_store_response!
      render :show_secret
    else
      flash.now[:alert] = rule.errors.full_messages.join(", ")
      render :new, status: :unprocessable_entity
    end
  end

  # PATCH /ai-agents/:handle/webhooks/:id
  def update
    @form = form_params
    trigger_config = validate_form_and_resolve_trigger(@form, on_error: :edit)
    return unless trigger_config

    name = @form[:name].presence || default_name_for(@form[:webhook_url])
    actions = (@webhook_rule.actions || {}).merge("webhook_url" => @form[:webhook_url])

    if @webhook_rule.update(
      name: name,
      trigger_config: trigger_config,
      actions: actions,
      updated_by: @current_user
    )
      redirect_to webhooks_index_path, notice: "Webhook updated."
    else
      flash.now[:alert] = @webhook_rule.errors.full_messages.join(", ")
      render :edit, status: :unprocessable_entity
    end
  end

  # DELETE /ai-agents/:handle/webhooks/:id
  def destroy
    @webhook_rule.destroy!
    redirect_to webhooks_index_path, notice: "Webhook deleted."
  end

  # POST /ai-agents/:handle/webhooks/:id/test
  # Synchronously delivers a test payload and renders the response inline.
  def test_delivery
    url = @webhook_rule.actions&.dig("webhook_url")
    secret = @webhook_rule.actions&.dig("signing_secret").presence || @webhook_rule.webhook_secret

    if url.blank? || secret.blank?
      flash[:alert] = "Webhook URL or signing secret missing."
      return redirect_to edit_webhook_path
    end

    @test_result = perform_test_delivery(url, secret)

    @form = form_from_rule(@webhook_rule)
    @recent_deliveries = recent_deliveries_for(@webhook_rule)
    @page_title = "Edit Webhook - #{@ai_agent.display_name}"
    render :edit
  end

  # POST /ai-agents/:handle/webhooks/:id/rotate_secret
  def rotate_secret
    new_secret = generate_signing_secret
    actions = (@webhook_rule.actions || {}).merge("signing_secret" => new_secret)
    @webhook_rule.update!(actions: actions, updated_by: @current_user)

    @reveal_secret = new_secret
    flash.now[:notice] = "Signing secret rotated. Save the new secret below — it won't be shown again."
    no_store_response!
    render :show_secret
  end

  # POST /ai-agents/:handle/webhooks/:id/toggle
  def toggle
    @webhook_rule.update!(enabled: !@webhook_rule.enabled?, updated_by: @current_user)
    redirect_to webhooks_index_path,
                notice: "Webhook #{@webhook_rule.enabled? ? "enabled" : "disabled"}."
  end

  private

  # Validates webhook_url + trigger from the form. Returns trigger_config hash
  # on success, nil on failure (after rendering an error response).
  def validate_form_and_resolve_trigger(form, on_error:)
    if form[:webhook_url].blank?
      flash.now[:alert] = "Webhook URL is required."
      render on_error, status: :unprocessable_entity
      return nil
    end

    unless valid_https_url?(form[:webhook_url])
      flash.now[:alert] = "Webhook URL must be a valid HTTPS URL."
      render on_error, status: :unprocessable_entity
      return nil
    end

    trigger_config = trigger_config_for(form[:trigger])
    if trigger_config.nil?
      flash.now[:alert] = "Please choose a trigger."
      render on_error, status: :unprocessable_entity
      return nil
    end

    trigger_config
  end

  def build_webhook_rule(form, trigger_config, secret)
    AutomationRule.new(
      tenant: @current_tenant,
      ai_agent: @ai_agent,
      created_by: @current_user,
      name: form[:name].presence || default_name_for(form[:webhook_url]),
      trigger_type: "event",
      trigger_config: trigger_config,
      actions: {
        "webhook_url" => form[:webhook_url],
        "payload_template" => default_payload_template,
        "signing_secret" => secret,
      },
      enabled: true
    )
  end

  def perform_test_delivery(url, secret)
    body = test_payload_for(@webhook_rule).to_json
    timestamp = Time.current.to_i
    signature = WebhookDeliveryService.sign(body, timestamp, secret)

    response = SsrfFilter.post(
      url,
      body: body,
      headers: {
        "Content-Type" => "application/json",
        "X-Harmonic-Signature" => "sha256=#{signature}",
        "X-Harmonic-Timestamp" => timestamp.to_s,
        "X-Harmonic-Event" => TEST_PAYLOAD_EVENT,
      },
      timeout: TEST_TIMEOUT_SECONDS
    )
    { status: response.code.to_i, body: response.body.to_s.truncate(2000), request_body: body }
  rescue StandardError => e
    { error: e.message, request_body: body }
  end

  def recent_deliveries_for(rule)
    WebhookDelivery
      .where(automation_rule_run_id: rule.automation_rule_runs.select(:id))
      .order(created_at: :desc)
      .limit(10)
  end

  # Prevent caching of any response that includes the plaintext signing secret.
  def no_store_response!
    response.headers["Cache-Control"] = "no-store, no-cache, must-revalidate, private"
    response.headers["Pragma"] = "no-cache"
  end

  def webhook_rules_scope
    AutomationRule.tenant_scoped_only
      .where(ai_agent_id: @ai_agent.id)
      .where("(actions->>'webhook_url') IS NOT NULL")
  end

  def require_login
    return if @current_user

    redirect_to "/login"
  end

  def set_ai_agent
    agent_tu = @current_tenant.tenant_users.find_by(handle: params[:handle])
    raise ActiveRecord::RecordNotFound, "AI Agent not found" if agent_tu.nil?

    @ai_agent = agent_tu.user
    raise ActiveRecord::RecordNotFound, "AI Agent not found" unless @ai_agent&.ai_agent?

    @agent_handle = params[:handle]
  end

  def authorize_parent_user
    return if @ai_agent.parent_id == @current_user&.id

    redirect_to "/", alert: "You don't have permission to manage webhooks for this AI agent."
  end

  def require_external_agent
    return if @ai_agent.external_ai_agent?

    render status: :not_found, plain: "404 Not Found"
  end

  def set_webhook_rule
    @webhook_rule = webhook_rules_scope.find_by!(truncated_id: params[:id])
  end

  def form_params
    params.permit(:name, :webhook_url, :trigger).to_h.symbolize_keys
  end

  def build_form_defaults
    {
      name: "",
      webhook_url: "",
      trigger: TRIGGERS.keys.first,
    }
  end

  def form_from_rule(rule)
    {
      name: rule.name,
      webhook_url: rule.actions&.dig("webhook_url").to_s,
      trigger: trigger_key_for(rule),
    }
  end

  # Reverse-lookup which TRIGGERS key matches the rule's current event/filter.
  def trigger_key_for(rule)
    event = rule.event_type
    filter = rule.mention_filter
    TRIGGERS.find { |_, cfg| cfg[:event_type] == event && cfg[:mention_filter] == filter }&.first || TRIGGERS.keys.first
  end

  def trigger_config_for(trigger_key)
    cfg = TRIGGERS[trigger_key.to_s]
    return nil unless cfg

    {
      "event_type" => cfg[:event_type],
      "mention_filter" => cfg[:mention_filter],
    }
  end

  def default_name_for(url)
    URI.parse(url).host.to_s.presence || "Webhook"
  rescue URI::InvalidURIError
    "Webhook"
  end

  def valid_https_url?(url)
    uri = URI.parse(url)
    uri.is_a?(URI::HTTPS) && uri.host.present?
  rescue URI::InvalidURIError
    false
  end

  def generate_signing_secret
    "whsec_#{SecureRandom.hex(32)}"
  end

  def default_payload_template
    {
      "event" => "{{event.type}}",
      "agent" => { "id" => @ai_agent.id, "handle" => @ai_agent.handle },
      "actor" => { "id" => "{{event.actor.id}}", "handle" => "{{event.actor.handle}}" },
      "subject" => {
        "type" => "{{subject.type}}",
        "path" => "{{subject.path}}",
        "text" => "{{subject.text}}",
      },
      "collective" => { "handle" => "{{collective.handle}}" },
    }
  end

  def test_payload_for(rule)
    {
      "event" => TEST_PAYLOAD_EVENT,
      "rule_id" => rule.truncated_id,
      "agent" => { "id" => @ai_agent.id, "handle" => @ai_agent.handle },
      "sent_at" => Time.current.iso8601,
    }
  end

  def webhooks_index_path
    "/ai-agents/#{@agent_handle}/webhooks"
  end

  def edit_webhook_path
    "/ai-agents/#{@agent_handle}/webhooks/#{@webhook_rule.truncated_id}/edit"
  end
end
