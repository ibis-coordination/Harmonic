# typed: false

class HomeController < ApplicationController
  before_action :redirect_representing

  def index
    @page_title = 'Home'
    @sidebar_mode = 'none'
    @hide_breadcrumb = true

    # Build main collective timeline, proximity-ranked
    main_cid = @current_tenant.main_collective_id
    tid = @current_tenant.id
    scores = @current_user.proximity_scores(tenant_id: tid)

    @feed_items = FeedBuilder.new(
      notes_scope: Note.unscope_collective.where(collective_id: main_cid),
      decisions_scope: Decision.unscope_collective.where(collective_id: main_cid),
      commitments_scope: Commitment.unscope_collective.where(collective_id: main_cid),
      proximity_scores: scores,
    ).feed_items
  end

  def subdomains
    @page_title = "Subdomains"
    @sidebar_mode = "minimal"
    @public_tenants = Tenant.all_public_tenants
    @other_tenants = (
      (@current_user.own_tenants + @public_tenants) - [@current_tenant]
    ).uniq.sort_by(&:subdomain)
    respond_to do |format|
      format.html
      format.md
    end
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
