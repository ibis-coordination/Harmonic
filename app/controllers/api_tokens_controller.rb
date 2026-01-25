# typed: false

class ApiTokensController < ApplicationController
  layout 'pulse', only: [:new, :show]
  before_action :set_user
  before_action :set_sidebar_mode, only: [:new, :show]

  def new
    # Block subagents from creating their own tokens (parents can still create tokens for their subagents)
    if @showing_user == current_user && current_user.subagent?
      return render status: 403, plain: '403 Unauthorized - Subagents cannot create their own API tokens'
    end
    @token = @showing_user.api_tokens.new(user: @showing_user)
    respond_to do |format|
      format.html
      format.md
    end
  end

  def create
    # Block subagents from creating their own tokens (parents can still create tokens for their subagents)
    if @showing_user == current_user && current_user.subagent?
      return render status: 403, plain: '403 Unauthorized - Subagents cannot create their own API tokens'
    end
    @token = @showing_user.api_tokens.new
    @token.name = token_params[:name]
    @token.scopes = ApiToken.read_scopes
    @token.scopes += ApiToken.write_scopes if token_params[:read_write] == 'write'
    @token.expires_at = Time.current + [duration_param, 1.year].min
    @token.save!
    redirect_to @token.path
  end

  def show
    @token = @showing_user.api_tokens.find_by(id: params[:id])
    return render status: 404, plain: '404 not token found' if @token.nil?
    respond_to do |format|
      format.html
      format.md
    end
  end

  def destroy
    @token = @showing_user.api_tokens.find_by(id: params[:id])
    return render status: 404, plain: '404 not token found' if @token.nil?
    @token.delete!
    redirect_to "#{@showing_user.path}/settings"
  end

  # Markdown API actions

  def actions_index
    # Block subagents from creating their own tokens
    if @showing_user == current_user && current_user.subagent?
      return render status: 403, plain: '403 Unauthorized - Subagents cannot create their own API tokens'
    end
    @page_title = "Actions | New API Token"
    render_actions_index(ActionsHelper.actions_for_route('/u/:handle/settings/tokens/new'))
  end

  def describe_create_api_token
    # Block subagents from creating their own tokens
    if @showing_user == current_user && current_user.subagent?
      return render status: 403, plain: '403 Unauthorized - Subagents cannot create their own API tokens'
    end
    render_action_description(ActionsHelper.action_description("create_api_token", resource: @showing_user))
  end

  def execute_create_api_token
    # Block subagents from creating their own tokens
    if @showing_user == current_user && current_user.subagent?
      return render_action_error({
        action_name: 'create_api_token',
        resource: @showing_user,
        error: 'Subagents cannot create their own API tokens.',
      })
    end
    @token = @showing_user.api_tokens.new
    @token.name = params[:name]
    @token.scopes = ApiToken.read_scopes
    @token.scopes += ApiToken.write_scopes if params[:read_write] == 'write'
    @token.expires_at = Time.current + [duration_param, 1.year].min
    @token.save!

    respond_to do |format|
      format.md { render 'show' }
      format.html { redirect_to @token.path }
    end
  end

  private

  def set_sidebar_mode
    @sidebar_mode = 'minimal'
  end

  def token_params
    # duration_param is defined in the ApplicationController
    params.require(:api_token).permit(:name, :read_write).merge(user: @showing_user)
  end

  def set_user
    handle = params[:user_handle] || params[:handle]
    tu = current_tenant.tenant_users.find_by(handle: handle)
    tu ||= current_tenant.tenant_users.find_by(user_id: handle)
    return render status: 404, plain: '404 not user found' if tu.nil?
    return render status: 403, plain: '403 Unauthorized' unless current_user.can_edit?(tu.user)
    @showing_user = tu.user
    @showing_user.tenant_user = tu
  end

end