class HomeController < ApplicationController

  before_action :redirect_representing

  def index
    @page_title = 'Home'
    @studios = @current_user.studios.where.not(id: @current_tenant.main_studio_id)
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

  def scratchpad
    @page_title = 'Scratchpad'
    @hide_scratchpad_menu_options = true
    unless @current_user.tenant_user.dismissed_notices.include?('scratchpad')
      flash[:notice] = 'This is your personal scratchpad. What you write here is only visible to you. You can use your scratchpad for bookmarking links, keeping track of ideas, or anything else you want to jot down. It is always available through the top right menu.'
      @current_user.tenant_user.dismiss_notice!('scratchpad')
    end
  end

  def actions_index_scratchpad
    @page_title = 'Actions | Scratchpad'
    render_actions_index(ActionsHelper.actions_for_route('/scratchpad'))
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
