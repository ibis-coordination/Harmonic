class HomeController < ApplicationController

  before_action :redirect_representing

  def index
    @page_title = 'Home'
    @studios = @current_user.studios
      .joins(
        "LEFT JOIN heartbeats ON heartbeats.studio_id = studios.id AND " +
        "heartbeats.user_id = '#{@current_user.id}' AND " +
        "heartbeats.expires_at > '#{Time.current}'"
      )
      .select("studios.*, heartbeats.id IS NOT NULL AS has_heartbeat")
      .where.not(id: @current_tenant.main_studio_id)
      .order(:has_heartbeat, :name)
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
