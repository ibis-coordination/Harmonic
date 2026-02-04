# typed: false

class ApiTokensController < ApplicationController
  layout "pulse", only: [:new, :show, :create]
  before_action :set_user
  before_action :set_sidebar_mode, only: [:new, :show, :create]

  def show
    # Never show internal tokens
    @token = @showing_user.api_tokens.external.find_by(id: params[:id])
    return render status: :not_found, plain: "404 not token found" if @token.nil?

    respond_to do |format|
      format.html
      format.md
    end
  end

  def new
    # Only person accounts can create API tokens (for themselves or their subagents)
    return render status: :forbidden, plain: "403 Unauthorized - Only person accounts can create API tokens" unless current_user&.person?
    # Internal subagents cannot have API tokens
    return render status: :forbidden, plain: "403 Forbidden - Internal subagents cannot have API tokens" if @showing_user.internal_subagent?

    @token = @showing_user.api_tokens.new(user: @showing_user)
    respond_to do |format|
      format.html
      format.md
    end
  end

  def create
    # Only person accounts can create API tokens (for themselves or their subagents)
    return render status: :forbidden, plain: "403 Unauthorized - Only person accounts can create API tokens" unless current_user&.person?
    # Internal subagents cannot have API tokens
    return render status: :forbidden, plain: "403 Forbidden - Internal subagents cannot have API tokens" if @showing_user.internal_subagent?

    @token = @showing_user.api_tokens.new
    @token.name = token_params[:name]
    @token.scopes = ApiToken.read_scopes
    @token.scopes += ApiToken.write_scopes if token_params[:read_write] == "write"
    @token.expires_at = Time.current + [duration_param, 1.year].min
    @token.save!
    # Render show page directly instead of redirecting so plaintext_token is available
    flash.now[:notice] = "Token created successfully. Save the token value now - you will not be able to see it again."
    render "show"
  end

  def destroy
    # Never allow deleting internal tokens
    @token = @showing_user.api_tokens.external.find_by(id: params[:id])
    return render status: :not_found, plain: "404 not token found" if @token.nil?

    @token.delete!
    redirect_to "#{@showing_user.path}/settings"
  end

  # Markdown API actions

  def actions_index
    # Only person accounts can create API tokens
    return render status: :forbidden, plain: "403 Unauthorized - Only person accounts can create API tokens" unless current_user&.person?

    @page_title = "Actions | New API Token"
    render_actions_index(ActionsHelper.actions_for_route("/u/:handle/settings/tokens/new"))
  end

  def describe_create_api_token
    # Only person accounts can create API tokens
    return render status: :forbidden, plain: "403 Unauthorized - Only person accounts can create API tokens" unless current_user&.person?

    render_action_description(ActionsHelper.action_description("create_api_token", resource: @showing_user))
  end

  def execute_create_api_token
    # Only person accounts can create API tokens
    unless current_user&.person?
      return render_action_error({
                                   action_name: "create_api_token",
                                   resource: @showing_user,
                                   error: "Only person accounts can create API tokens.",
                                 })
    end
    # Internal subagents cannot have API tokens
    if @showing_user.internal_subagent?
      return render_action_error({
                                   action_name: "create_api_token",
                                   resource: @showing_user,
                                   error: "Internal subagents cannot have API tokens.",
                                 })
    end
    @token = @showing_user.api_tokens.new
    @token.name = params[:name]
    @token.scopes = ApiToken.read_scopes
    @token.scopes += ApiToken.write_scopes if params[:read_write] == "write"
    @token.expires_at = Time.current + [duration_param, 1.year].min
    @token.save!

    respond_to do |format|
      format.md { render "show" }
      format.html { redirect_to @token.path }
    end
  end

  private

  def set_sidebar_mode
    @sidebar_mode = "minimal"
  end

  def token_params
    # duration_param is defined in the ApplicationController
    params.require(:api_token).permit(:name, :read_write).merge(user: @showing_user)
  end

  def set_user
    handle = params[:user_handle] || params[:handle]
    tu = current_tenant.tenant_users.find_by(handle: handle)
    tu ||= current_tenant.tenant_users.find_by(user_id: handle)
    return render status: :not_found, plain: "404 not user found" if tu.nil?
    return render status: :forbidden, plain: "403 Unauthorized" unless current_user.can_edit?(tu.user)

    @showing_user = tu.user
    @showing_user.tenant_user = tu
  end
end
