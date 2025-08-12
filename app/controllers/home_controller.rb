class HomeController < ApplicationController

  before_action :redirect_representing

  def index
    @page_title = 'Home'
    @studios = @current_user.studios.where.not(id: @current_tenant.main_studio_id).order(:name)
  end

  def settings
    @page_title = 'Settings'
  end

  def about
    @page_title = 'About'
  end

  def help
    @page_title = 'Help'
  end

  def contact
  end

  def actions_index
    @page_title = 'Actions | Home'
    @routes_and_actions = ActionsHelper.routes_and_actions
    render 'actions'
  end

  private

  def redirect_representing
    if current_representation_session
      return redirect_to "/representing"
    end
  end

end
