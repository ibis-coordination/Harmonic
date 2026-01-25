# typed: false

class SubagentsController < ApplicationController
  layout 'pulse', only: [:new]
  before_action :verify_current_user_path
  before_action :set_sidebar_mode, only: [:new]

  def new
    return render status: 403, plain: '403 Unauthorized - Only person accounts can create subagents' unless current_user&.person?
    respond_to do |format|
      format.html
      format.md
    end
  end

  def create
    return render status: 403, plain: '403 Unauthorized - Only person accounts can create subagents' unless current_user&.person?
    @subagent = api_helper.create_subagent
    if params[:generate_token] == "true" || params[:generate_token] == "1"
      api_helper.generate_token(@subagent)
    end
    flash[:notice] = "Subagent #{@subagent.display_name} created successfully."
    redirect_to "#{@current_user.path}/settings"
  end

  def update
  end

  def destroy
  end

  # Markdown API actions

  def actions_index
    return render status: 403, plain: '403 Unauthorized - Only person accounts can create subagents' unless current_user&.person?
    @page_title = "Actions | New Subagent"
    render_actions_index(ActionsHelper.actions_for_route('/u/:handle/settings/subagents/new'))
  end

  def describe_create_subagent
    return render status: 403, plain: '403 Unauthorized - Only person accounts can create subagents' unless current_user&.person?
    render_action_description(ActionsHelper.action_description("create_subagent", resource: @current_user))
  end

  def execute_create_subagent
    unless current_user&.person?
      return render_action_error({
        action_name: 'create_subagent',
        resource: @current_user,
        error: 'Only person accounts can create subagents.',
      })
    end
    @subagent = api_helper.create_subagent
    if params[:generate_token] == true || params[:generate_token] == "true" || params[:generate_token] == "1"
      @token = api_helper.generate_token(@subagent)
    end

    respond_to do |format|
      format.md { render 'show' }
      format.html do
        flash[:notice] = "Subagent #{@subagent.display_name} created successfully."
        redirect_to "#{@current_user.path}/settings"
      end
    end
  end

  def current_resource_model
    User
  end

  private

  def set_sidebar_mode
    @sidebar_mode = 'minimal'
  end

  def verify_current_user_path
    handle = params[:handle]
    return if handle.nil?
    tu = current_tenant.tenant_users.find_by(handle: handle)
    return render status: 404, plain: '404 Not Found' if tu.nil?
    return render status: 403, plain: '403 Unauthorized' unless tu.user == current_user
  end
end
