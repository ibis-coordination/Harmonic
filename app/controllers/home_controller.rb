# typed: false

class HomeController < ApplicationController
  before_action :redirect_representing

  def index
    @page_title = 'Home'
    @sidebar_mode = 'none'
    @hide_breadcrumb = true
    @studios_and_scenes = @current_user.superagents
      .joins(
        "LEFT JOIN heartbeats ON heartbeats.superagent_id = superagents.id AND " +
        "heartbeats.user_id = '#{@current_user.id}' AND " +
        "heartbeats.expires_at > '#{Time.current}'"
      )
      .select("superagents.*, heartbeats.id IS NOT NULL AS has_heartbeat")
      .where.not(id: @current_tenant.main_superagent_id)
      .order(:has_heartbeat, :name)
    @scenes = @studios_and_scenes.where(superagent_type: 'scene')
    @studios = @studios_and_scenes.where(superagent_type: 'studio')
    @public_tenants = Tenant.all_public_tenants
    @other_tenants = TenantUser.unscoped
      .where(user: @current_user)
      .where.not(tenant_id: [@current_tenant.id] + @public_tenants.pluck(:id))
      .includes(:tenant)
      .where(tenant: { archived_at: nil })
      .map(&:tenant)
    @other_tenants = (
      (@other_tenants + @public_tenants) - [@current_tenant]
    ).sort_by(&:subdomain)
  end

  def about
    @page_title = 'About'
    @sidebar_mode = 'minimal'
  end

  def help
    @page_title = 'Help'
    @sidebar_mode = 'minimal'
    respond_to do |format|
      format.html
      format.md
    end
  end

  def contact
    @page_title = 'Contact'
    @sidebar_mode = 'minimal'
  end

  def actions_index
    @page_title = 'Actions | Home'
    @sidebar_mode = 'minimal'
    @routes_and_actions = ActionsHelper.routes_and_actions_for_user(@current_user)
    render 'actions'
  end

  def page_not_found
    @sidebar_mode = 'minimal'
    render 'shared/404', status: 404
  end

  private

  def redirect_representing
    if current_representation_session
      return redirect_to "/representing"
    end
  end

end
