# typed: false

class WebhooksController < ApplicationController
  before_action :require_user
  before_action :require_studio_admin
  before_action :set_webhook, only: [:show, :actions_index, :describe_update_webhook, :execute_update_webhook,
                                     :describe_delete_webhook, :execute_delete_webhook,
                                     :describe_test_webhook, :execute_test_webhook]

  def index
    @page_title = "Webhooks"
    @webhooks = Webhook.where(tenant_id: @current_tenant.id)
      .where("superagent_id IS NULL OR superagent_id = ?", @current_superagent.id)
      .order(created_at: :desc)
  end

  def show
    @page_title = "Webhook: #{@webhook.name}"
    @recent_deliveries = @webhook.webhook_deliveries.order(created_at: :desc).limit(20)
  end

  def new
    @page_title = "New Webhook"
    @webhook = Webhook.new
  end

  def actions_index
    render_actions_index(ActionsHelper.actions_for_route('/studios/:studio_handle/settings/webhooks/:id'))
  end

  def actions_index_new
    render_actions_index(ActionsHelper.actions_for_route('/studios/:studio_handle/settings/webhooks/new'))
  end

  def describe_create_webhook
    render_action_description(ActionsHelper.action_description("create_webhook", resource: nil))
  end

  def execute_create_webhook
    webhook = Webhook.new(
      tenant_id: @current_tenant.id,
      superagent_id: @current_superagent.id,
      name: params[:name],
      url: params[:url],
      events: parse_events(params[:events]),
      enabled: params[:enabled] != "false",
      created_by: @current_user,
    )

    if webhook.save
      render_action_success({
        action_name: "create_webhook",
        resource: webhook,
        result: "Webhook created successfully.",
        redirect_to: webhook_path(webhook),
      })
    else
      render_action_error({
        action_name: "create_webhook",
        resource: nil,
        error: webhook.errors.full_messages.join(", "),
      })
    end
  end

  def describe_update_webhook
    render_action_description(ActionsHelper.action_description("update_webhook", resource: @webhook))
  end

  def execute_update_webhook
    updates = {}
    updates[:name] = params[:name] if params[:name].present?
    updates[:url] = params[:url] if params[:url].present?
    updates[:events] = parse_events(params[:events]) if params[:events].present?
    updates[:enabled] = params[:enabled] != "false" if params.key?(:enabled)

    if @webhook.update(updates)
      render_action_success({
        action_name: "update_webhook",
        resource: @webhook,
        result: "Webhook updated successfully.",
      })
    else
      render_action_error({
        action_name: "update_webhook",
        resource: @webhook,
        error: @webhook.errors.full_messages.join(", "),
      })
    end
  end

  def describe_delete_webhook
    render_action_description(ActionsHelper.action_description("delete_webhook", resource: @webhook))
  end

  def execute_delete_webhook
    @webhook.destroy!
    render_action_success({
      action_name: "delete_webhook",
      resource: nil,
      result: "Webhook deleted successfully.",
      redirect_to: webhooks_path,
    })
  end

  def describe_test_webhook
    render_action_description(ActionsHelper.action_description("test_webhook", resource: @webhook))
  end

  def execute_test_webhook
    WebhookTestService.send_test!(@webhook, @current_user)
    render_action_success({
      action_name: "test_webhook",
      resource: @webhook,
      result: "Test webhook sent. Check recent deliveries for result.",
    })
  end

  private

  def require_user
    return if current_user

    respond_to do |format|
      format.html { redirect_to "/login" }
      format.json { render json: { error: "Unauthorized" }, status: :unauthorized }
      format.md { render plain: "# Error\n\nYou must be logged in to manage webhooks.", status: :unauthorized }
    end
  end

  def require_studio_admin
    unless @current_user.superagent_member&.is_admin?
      respond_to do |format|
        format.html { redirect_to @current_superagent.path, alert: "You must be a studio admin to manage webhooks." }
        format.json { render json: { error: "Unauthorized" }, status: :forbidden }
        format.md { render plain: "# Error\n\nYou must be a studio admin to manage webhooks.", status: :forbidden }
      end
    end
  end

  def set_webhook
    @webhook = if params[:id].to_s.length == 8
      Webhook.find_by(truncated_id: params[:id], tenant_id: @current_tenant.id)
    else
      Webhook.find_by(id: params[:id], tenant_id: @current_tenant.id)
    end

    unless @webhook
      respond_to do |format|
        format.html { redirect_to webhooks_path, alert: "Webhook not found." }
        format.json { render json: { error: "Webhook not found" }, status: :not_found }
        format.md { render plain: "# Error\n\nWebhook not found.", status: :not_found }
      end
    end
  end

  def webhook_path(webhook)
    "/studios/#{@current_superagent.handle}/settings/webhooks/#{webhook.truncated_id}"
  end

  def webhooks_path
    "/studios/#{@current_superagent.handle}/settings/webhooks"
  end

  def parse_events(events_param)
    return ["*"] if events_param.blank?

    if events_param.is_a?(Array)
      events_param
    elsif events_param.is_a?(String)
      events_param.split(",").map(&:strip).reject(&:blank?)
    else
      ["*"]
    end
  end
end
