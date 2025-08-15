class HomeController < ApplicationController

  before_action :redirect_representing

  def index
    @page_title = 'Home'
    @studios_and_scenes = @current_user.studios
      .joins(
        "LEFT JOIN heartbeats ON heartbeats.studio_id = studios.id AND " +
        "heartbeats.user_id = '#{@current_user.id}' AND " +
        "heartbeats.expires_at > '#{Time.current}'"
      )
      .select("studios.*, heartbeats.id IS NOT NULL AS has_heartbeat")
      .where.not(id: @current_tenant.main_studio_id)
      .order(:has_heartbeat, :name)
    @scenes = @studios_and_scenes.where(studio_type: 'scene')
    @studios = @studios_and_scenes.where(studio_type: 'studio')
    @public_tenants = Tenant.all_public_tenants
    @other_tenants = TenantUser.unscoped
      .where(user: @current_user)
      .where.not(tenant_id: [@current_tenant.id] + @public_tenants.pluck(:id))
      .includes(:tenant)
      .map(&:tenant)
    @other_tenants = (
      (@other_tenants + @public_tenants) - [@current_tenant]
    ).sort_by(&:subdomain)
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
