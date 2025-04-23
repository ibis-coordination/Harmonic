class SimulatedUsersController < ApplicationController
  def new
  end

  def create
    @simulated_user = api_helper.create_simulated_user
    if params[:generate_token] == 'true' || params[:generate_token] == '1'
      api_helper.generate_token(@simulated_user)
    end
    flash[:notice] = "Simulated user #{@simulated_user.display_name} created successfully."
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