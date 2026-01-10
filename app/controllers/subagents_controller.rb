# typed: false

class SubagentsController < ApplicationController
  def new
    respond_to do |format|
      format.html
      format.md
    end
  end

  def create
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
    @page_title = "Actions | New Subagent"
    render_actions_index(ActionsHelper.actions_for_route('/u/:handle/settings/subagents/new'))
  end

  def describe_create_subagent
    render_action_description({
      action_name: 'create_subagent',
      resource: @current_user,
      description: 'Create a new subagent',
      params: [
        { name: 'name', type: 'string', description: 'The name of the subagent' },
        { name: 'generate_token', type: 'boolean', description: 'If true, automatically generate an API token for this subagent (default: false)' },
      ],
    })
  end

  def execute_create_subagent
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
end
