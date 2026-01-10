# typed: false

class SubagentsController < ApplicationController
  def new
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

  def current_resource_model
    User
  end
end
