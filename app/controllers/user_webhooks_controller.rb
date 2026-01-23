# typed: false

class UserWebhooksController < ApplicationController
  before_action :require_login
  before_action :set_target_user
  before_action :authorize_webhook_management

  # Override to avoid model lookup issues (UserWebhook model doesn't exist)
  def current_resource_model
    nil
  end

  def index
    @page_title = "Webhooks for #{@target_user.handle}"
    # User webhooks have superagent_id = nil, so we must use unscoped to bypass the default_scope
    @webhooks = Webhook.unscoped.for_user(@target_user).where(tenant: @current_tenant)
  end

  def actions_index
    render_actions_index(ActionsHelper.actions_for_route("/u/:handle/settings/webhooks"))
  end

  def describe_create
    render_action_description(ActionsHelper.action_description("create_user_webhook", resource: nil))
  end

  def execute_create
    url = params[:url]
    events = parse_events(params[:events])

    if url.blank?
      return render_action_error({
        action_name: "create_user_webhook",
        resource: nil,
        error: "URL is required",
      })
    end

    webhook = Webhook.new(
      tenant: @current_tenant,
      user: @target_user,
      created_by: @current_user,
      name: params[:name].presence || "#{@target_user.handle} webhook",
      url: url,
      events: events,
      enabled: params[:enabled] != "false",
    )

    if webhook.save
      render_action_success({
        action_name: "create_user_webhook",
        resource: webhook,
        result: "Webhook created with ID: #{webhook.truncated_id}",
        redirect_to: webhook_index_path,
      })
    else
      render_action_error({
        action_name: "create_user_webhook",
        resource: nil,
        error: webhook.errors.full_messages.join(", "),
      })
    end
  end

  def describe_delete
    render_action_description(ActionsHelper.action_description("delete_user_webhook", resource: nil))
  end

  def execute_delete
    # User webhooks have superagent_id = nil, so we must use unscoped to bypass the default_scope
    webhook = Webhook.unscoped.for_user(@target_user)
      .where(tenant: @current_tenant)
      .find_by(truncated_id: params[:id])

    if webhook.nil?
      return render_action_error({
        action_name: "delete_user_webhook",
        resource: nil,
        error: "Webhook not found",
      })
    end

    webhook.destroy!

    render_action_success({
      action_name: "delete_user_webhook",
      resource: nil,
      result: "Webhook deleted",
      redirect_to: webhook_index_path,
    })
  end

  private

  def require_login
    return if @current_user

    respond_to do |format|
      format.html { redirect_to "/login" }
      format.json { render json: { error: "Unauthorized" }, status: :unauthorized }
      format.md { render plain: "# Error\n\nYou must be logged in to manage webhooks.", status: :unauthorized }
    end
  end

  def set_target_user
    if params[:handle]
      tu = @current_tenant.tenant_users.find_by(handle: params[:handle])
      raise ActiveRecord::RecordNotFound, "User not found" if tu.nil?
      @target_user = tu.user
    else
      @target_user = @current_user
    end
  end

  def authorize_webhook_management
    # User can manage their own webhooks
    return if @target_user == @current_user

    # Parent can manage subagent webhooks
    return if @target_user.parent == @current_user

    respond_to do |format|
      format.html { redirect_to "/", alert: "You don't have permission to manage webhooks for this user" }
      format.json { render json: { error: "You don't have permission to manage webhooks for this user" }, status: :forbidden }
      format.md { render plain: "# Error\n\nYou don't have permission to manage webhooks for this user.", status: :forbidden }
    end
  end

  def webhook_index_path
    "/u/#{@target_user.handle}/settings/webhooks"
  end

  def parse_events(events_param)
    return ["reminders.delivered"] if events_param.blank?

    if events_param.is_a?(Array)
      events_param
    elsif events_param.is_a?(String)
      events_param.split(",").map(&:strip).reject(&:blank?)
    else
      ["reminders.delivered"]
    end
  end
end
