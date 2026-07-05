# typed: false

class HomeController < ApplicationController
  include FeedPage

  def index
    @page_title = 'Home'
    @page_scope = "visibility:public"
    @sidebar_mode = 'none'
    @hide_breadcrumb = true
    return if @current_user.nil?

    # The home feed is a search: fixed scope visibility:public, default
    # query list:tuned_in (the people you tune in to, plus yourself) minus
    # comments — both visible and removable in the query input.
    resolve_feed_query("list:tuned_in -subtype:comment")
    @search = build_feed_search(fixed_params: { visibility: "public" })
    @feed_items = SearchFeedItems.build(@search.paginated_results)
    @feed_items = interleave_reminder_events(@feed_items, author_ids: home_reminder_author_ids) if default_feed_view?

    @tuned_in_count = @current_user.primary_user_list_in!(@current_tenant).user_list_members.count
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

  # The default home view's reminder authors: the tuned-in list plus the
  # viewer, minus block-related users.
  def home_reminder_author_ids
    member_ids = @current_user.primary_user_list_in!(@current_tenant).user_list_members.pluck(:user_id)
    (member_ids - block_related_user_ids.to_a) << @current_user.id
  end
end
