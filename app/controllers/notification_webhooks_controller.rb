# typed: false

# Per-user notification webhook surface.
#
# Mounts at both /u/:handle/webhook and /ai-agents/:handle/webhook with a
# single shared controller. The URL prefix decides which user_type is
# expected; URL-prefix-aware target resolution prevents type confusion
# since `TenantUser.handle` is tenant-unique regardless of `user_type`.
#
# Authoring shape stored in AutomationRule.actions:
#   { webhook_url, payload_template }
# Signing secret lives in `AutomationRule#webhook_secret` (the same column
# the existing inbound-trigger flow uses). Notification webhooks are
# `trigger_type: "event"` and never receive inbound requests, so there's
# no collision with the inbound use of `webhook_secret`.
class NotificationWebhooksController < ApplicationController
  TRIGGER_CONFIG = T.let({ "event_types" => ["notifications.delivered", "reminders.delivered"] }.freeze, T::Hash[String, T.untyped])
  TEST_PAYLOAD_EVENT = "harmonic.webhook.test".freeze
  TEST_TIMEOUT_SECONDS = 30

  def current_resource_model
    AutomationRule
  end

  before_action :require_login
  before_action :set_target_user
  before_action :authorize_target_user
  before_action :set_webhook_rule, except: [:finalize]

  # GET /(u|ai-agents)/:handle/webhook
  # The webhook's canonical home — refreshable, bookmarkable. Renders the
  # create form when no rule exists; renders the manage view when it does.
  # After create/rotate, a plaintext secret arrives via flash[:reveal_secret]
  # (encrypted session cookie); refreshing this page clears the flash so the
  # secret can never be re-revealed by a refresh.
  def show
    if flash[:reveal_secret].present?
      @reveal_secret = flash[:reveal_secret]
      no_store_response!
    end
    @recent_deliveries = recent_deliveries
  end

  # PATCH /(u|ai-agents)/:handle/webhook
  # Creates the rule if it doesn't exist; updates the URL if it does.
  # On create, the secret is revealed once via @reveal_secret. On update,
  # we redirect to GET show so the URL is the canonical refreshable page.
  def update
    url = params[:webhook_url].to_s.strip
    @form_url = url
    return render_unprocessable("Webhook URL is required.") if url.blank?
    return render_unprocessable("Webhook URL must be a valid HTTPS URL.") unless valid_https_url?(url)

    @webhook_rule ? update_existing_webhook(url) : create_new_webhook(url)
  end

  # DELETE /(u|ai-agents)/:handle/webhook
  # After destroy the webhook page would show the "create new" form, which
  # is confusing right after a delete. Redirect to settings instead.
  def destroy
    @webhook_rule&.destroy!
    redirect_to settings_path_for_target, notice: "Webhook deleted."
  end

  # POST /(u|ai-agents)/:handle/webhook/toggle
  def toggle
    return redirect_to(show_path_for_target, alert: "No webhook to toggle.") if @webhook_rule.nil?

    @webhook_rule.update!(enabled: !@webhook_rule.enabled?, updated_by: @current_user)
    redirect_to show_path_for_target,
                notice: "Webhook #{@webhook_rule.enabled? ? "enabled" : "disabled"}."
  end

  # POST /(u|ai-agents)/:handle/webhook/test
  # JSON-only: the test button is JS-driven (Stimulus + fetch). A non-JS
  # client never reaches this action through the UI, so we don't render HTML.
  def test_delivery
    return render json: { ok: false, result: { error: "No webhook to test." } }, status: :not_found if @webhook_rule.nil?

    url = @webhook_rule.actions&.dig("webhook_url")
    secret = @webhook_rule.webhook_secret

    if url.blank? || secret.blank?
      return render json: { ok: false, result: { error: "Webhook URL or signing secret missing." } },
                    status: :unprocessable_entity
    end

    result = perform_test_delivery(url, secret)
    payload = result.except(:request_body).merge(request_body_preview: result[:request_body])
    render json: { ok: result[:status].to_i.between?(200, 299), result: payload }
  end

  # GET /(u|ai-agents)/:handle/webhook/finalize
  # After Stripe Checkout returns, the user's stripe_customer is active and
  # we can create the webhook from the params we stashed in session.
  def finalize
    pending = session[:pending_webhook_creation]
    if pending.nil? || pending["user_handle"] != @target_handle
      # No pending creation for this user — stale link or unrelated visit.
      # Silently bounce to the show page (matches api_tokens#finalize).
      return redirect_to show_path_for_target
    end

    if needs_stripe_setup_for_webhook? && !@target_user.stripe_customer&.active?
      # Stripe round-trip didn't activate billing (e.g. user canceled).
      session.delete(:pending_webhook_creation)
      flash[:alert] = "Webhook setup canceled — billing wasn't set up. Try again when ready."
      return redirect_to show_path_for_target
    end

    session.delete(:pending_webhook_creation)

    # Race: a webhook may already exist (e.g. user opened the create flow in
    # two tabs and both round-tripped through Stripe). Don't try to create a
    # second — the unique index would surface as a confusing validation error
    # right after a successful billing flow.
    set_webhook_rule
    if @webhook_rule
      sync_subscription_for_new_billable!
      return redirect_to show_path_for_target, notice: "Billing set up — your webhook is ready."
    end

    build_and_save_webhook!(url: pending["webhook_url"])
  end

  # POST /(u|ai-agents)/:handle/webhook/rotate_secret
  def rotate_secret
    return redirect_to(show_path_for_target, alert: "No webhook to rotate.") if @webhook_rule.nil?

    new_secret = generate_signing_secret
    @webhook_rule.update!(webhook_secret: new_secret, updated_by: @current_user)

    # Redirect to the canonical show URL so refresh works. The plaintext
    # secret travels through one flash round-trip in the encrypted session
    # cookie; refreshing the show page clears it.
    redirect_to show_path_for_target, flash: { reveal_secret: new_secret }
  end

  private

  def update_existing_webhook(url)
    actions = @webhook_rule.actions.to_h.merge("webhook_url" => url)
    if @webhook_rule.update(actions: actions, updated_by: @current_user)
      redirect_to show_path_for_target, notice: "Webhook URL updated."
    else
      render_unprocessable(@webhook_rule.errors.full_messages.join(", "))
    end
  end

  def create_new_webhook(url)
    # Human surface: same billing gate as personal API tokens. Adding a
    # webhook makes the human +1 billable (via `has_notification_webhook?`),
    # and they need an active Stripe subscription to cover it. Agents skip
    # the gate (agents are billed separately per active agent).
    if needs_stripe_setup_for_webhook?
      stash_pending_webhook_creation!(url)
      return redirect_to_stripe_for_webhook_creation
    end

    build_and_save_webhook!(url: url)
  end

  def build_and_save_webhook!(url:)
    secret = generate_signing_secret
    @webhook_rule = AutomationRule.new(
      tenant: @current_tenant,
      ai_agent: @target_user.ai_agent? ? @target_user : nil,
      user: @target_user.ai_agent? ? nil : @target_user,
      created_by: @current_user,
      name: default_name_for(url),
      trigger_type: "event",
      trigger_config: TRIGGER_CONFIG,
      actions: {
        "webhook_url" => url,
        "payload_template" => default_payload_template,
      },
      webhook_secret: secret,
      enabled: true
    )
    if @webhook_rule.save
      sync_subscription_for_new_billable!
      # Redirect so the URL bar lands on the canonical show URL — refresh-safe.
      # Secret rides through one flash round-trip in the encrypted session.
      redirect_to show_path_for_target, flash: { reveal_secret: secret }
    else
      render_unprocessable(@webhook_rule.errors.full_messages.join(", "))
    end
  rescue ActiveRecord::RecordNotUnique
    # The model's `one_notification_webhook_per_user` validation runs a SELECT
    # that can miss a concurrent insert from another tab — the partial unique
    # index on (tenant_id, COALESCE(ai_agent_id, user_id)) is the backstop.
    # If we land here, the user already has a webhook; bounce them to it.
    set_webhook_rule
    redirect_to show_path_for_target,
                notice: "You already have a notification webhook — taking you to it."
  end

  def require_login
    return if @current_user

    redirect_to "/login"
  end

  def set_target_user
    tu = @current_tenant.tenant_users.find_by(handle: params[:handle])
    return render(status: :not_found, plain: "404 Not Found") if tu.nil?

    @target_user = tu.user
    expected = request.path.start_with?("/ai-agents/") ? :ai_agent : :human
    return render(status: :not_found, plain: "404 Not Found") if expected == :ai_agent && !@target_user.external_ai_agent?
    return render(status: :not_found, plain: "404 Not Found") if expected == :human && !@target_user.human?

    @target_handle = params[:handle]
  end

  def authorize_target_user
    return if @target_user == @current_user
    return if @target_user.ai_agent? && @target_user.parent_id == @current_user&.id

    redirect_to "/", alert: "You don't have permission to manage this webhook."
  end

  def set_webhook_rule
    @webhook_rule = AutomationRule.tenant_scoped_only.notification_webhook_for(@target_user).first
  end

  # True when creating this webhook would make the human user newly billable
  # AND they have no active Stripe subscription. Mirrors api_tokens
  # `needs_stripe_setup_for_token?`. Agents skip this (billed separately).
  def needs_stripe_setup_for_webhook?
    return false unless @target_user.human?
    return false unless @current_tenant.feature_enabled?("stripe_billing")
    return false if @target_user.app_admin? || @target_user.sys_admin?
    return false if @target_user.billing_exempt?
    return false if @target_user.stripe_customer&.active?

    true
  end

  def stash_pending_webhook_creation!(url)
    session[:pending_webhook_creation] = {
      "user_handle" => @target_handle,
      "webhook_url" => url,
    }
  end

  def redirect_to_stripe_for_webhook_creation
    stripe_customer = StripeService.find_or_create_customer(@target_user)
    quantity = @target_user.billable_quantity + 1
    finalize_url = url_for(action: :finalize)
    success_url = "#{billing_show_url}?checkout_session_id={CHECKOUT_SESSION_ID}&return_to=#{CGI.escape(finalize_path_for_target)}"

    checkout_url = StripeService.create_checkout_session(
      stripe_customer: stripe_customer,
      success_url: success_url,
      cancel_url: finalize_url,
      quantity: quantity
    )
    redirect_to checkout_url, allow_other_host: true
  end

  # After saving the webhook, push the updated billable_quantity to Stripe so
  # the human is charged proration immediately. No-op for agents (skipped by
  # the human? gate) and for humans without an active subscription (the
  # Stripe-Checkout-first path handles charging before save).
  def sync_subscription_for_new_billable!
    return unless @target_user.human?
    return unless @target_user.stripe_customer&.active?

    StripeService.sync_subscription_quantity!(@target_user)
  end

  def perform_test_delivery(url, secret)
    # Bind body early so the rescue clause can always reference it, even if
    # `test_payload_for` or `.to_json` raised before assignment.
    body = nil
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

  def valid_https_url?(url)
    uri = URI.parse(url)
    return false unless uri.is_a?(URI::HTTPS) && uri.host.present?
    return false if uri.userinfo.present? # URLs with embedded credentials in the host component are rejected

    true
  rescue URI::InvalidURIError
    false
  end

  def generate_signing_secret
    "whsec_#{SecureRandom.hex(32)}"
  end

  def default_name_for(url)
    URI.parse(url).host.to_s.presence || "Webhook"
  rescue URI::InvalidURIError
    "Webhook"
  end

  # All identity fields use {{...}} placeholders so the payload reflects the
  # current handle/name at delivery time, not whatever the recipient's handle
  # was when the webhook was first created.
  def default_payload_template
    {
      "event" => "{{event.type}}",
      "recipient" => { "id" => "{{recipient.id}}", "handle" => "{{recipient.handle}}" },
      "notification" => {
        "type" => "{{notification.type}}",
        "title" => "{{notification.title}}",
        "body" => "{{notification.body}}",
        "url" => "{{notification.url}}",
        "created_at" => "{{notification.created_at}}",
      },
      "actor" => { "id" => "{{actor.id}}", "handle" => "{{actor.handle}}" },
      "collective" => { "handle" => "{{collective.handle}}" },
    }
  end

  def test_payload_for(_rule)
    {
      "event" => TEST_PAYLOAD_EVENT,
      "recipient" => {
        "id" => @target_user.id,
        "handle" => @target_handle,
        "type" => @target_user.ai_agent? ? "ai_agent" : "human",
      },
      "sent_at" => Time.current.iso8601,
    }
  end

  def settings_path_for_target
    if @target_user.ai_agent?
      ai_agent_settings_path(@target_handle)
    else
      settings_user_path(@target_handle)
    end
  end
  helper_method :settings_path_for_target

  def show_path_for_target
    if @target_user.ai_agent?
      ai_agent_notification_webhook_path(@target_handle)
    else
      user_notification_webhook_path(@target_handle)
    end
  end
  helper_method :show_path_for_target

  def toggle_path_for_target
    @target_user.ai_agent? ? toggle_ai_agent_notification_webhook_path(@target_handle) : toggle_user_notification_webhook_path(@target_handle)
  end
  helper_method :toggle_path_for_target

  def test_path_for_target
    @target_user.ai_agent? ? test_ai_agent_notification_webhook_path(@target_handle) : test_user_notification_webhook_path(@target_handle)
  end
  helper_method :test_path_for_target

  def rotate_secret_path_for_target
    if @target_user.ai_agent?
      rotate_secret_ai_agent_notification_webhook_path(@target_handle)
    else
      rotate_secret_user_notification_webhook_path(@target_handle)
    end
  end
  helper_method :rotate_secret_path_for_target

  def finalize_path_for_target
    @target_user.ai_agent? ? finalize_ai_agent_notification_webhook_path(@target_handle) : finalize_user_notification_webhook_path(@target_handle)
  end
  helper_method :finalize_path_for_target

  def no_store_response!
    response.headers["Cache-Control"] = "no-store, no-cache, must-revalidate, private"
    response.headers["Pragma"] = "no-cache"
  end

  # Renders the canonical show page (create form or manage view) with an
  # inline alert. Critically: a failed-save AutomationRule.new is NOT shown
  # as if it were an existing rule — clear @webhook_rule unless it's
  # persisted, so the view branches the same way GET show would.
  def render_unprocessable(message)
    flash.now[:alert] = message
    @webhook_rule = nil unless @webhook_rule&.persisted?
    @recent_deliveries = recent_deliveries
    render :show, status: :unprocessable_entity
  end

  def recent_deliveries
    return [] unless @webhook_rule&.persisted?

    WebhookDelivery
      .where(automation_rule_run_id: @webhook_rule.automation_rule_runs.select(:id))
      .order(created_at: :desc)
      .limit(10)
      .to_a
  end
end
