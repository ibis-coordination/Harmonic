# typed: false

class HomeController < ApplicationController
  before_action :redirect_representing

  FEED_LIMIT = 30

  def index
    @page_title = 'Home'
    @page_scope = "visibility:public"
    @sidebar_mode = 'none'
    @hide_breadcrumb = true
    return if @current_user.nil?

    # The home feed is a search: fixed scope visibility:public, default
    # query list:tuned_in (the people you tune in to, plus yourself). ?q
    # absent applies the default; ?q present — even empty — is the viewer's
    # own refinement (empty means "cleared": the whole public space).
    @feed_default_query = "list:tuned_in"
    @feed_query = params.key?(:q) ? params[:q].to_s : @feed_default_query
    @page_query = @feed_query.strip.presence

    @search = SearchQuery.new(
      tenant: @current_tenant,
      current_user: @current_user,
      raw_query: @feed_query,
      params: { exclude_subtypes: ["comment"], per_page: FEED_LIMIT },
      fixed_params: { visibility: "public" }
    )
    @feed_items = SearchFeedItems.build(@search.paginated_results)
    @feed_items = interleave_reminder_events(@feed_items) if default_feed_view?

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

  def redirect_representing
    if current_representation_session
      return redirect_to "/representing"
    end
  end

  def default_feed_view?
    @feed_query.strip == @feed_default_query
  end
  helper_method :default_feed_view?

  # Fired reminders resurface on the default home view only (parity with
  # the pre-search feed). A refined query is an explicit search; surprise
  # reminders would be noise there.
  def interleave_reminder_events(feed_items)
    member_ids = @current_user.primary_user_list_in!(@current_tenant).user_list_members.pluck(:user_id)
    author_ids = (member_ids - block_related_user_ids.to_a) << @current_user.id

    reminders = NoteHistoryEvent
      .main_collective_scope(@current_tenant)
      .where(event_type: "reminder")
      .joins(:note).where(notes: { created_by_id: author_ids })
      .includes(note: :created_by)
      .order(happened_at: :desc)
      .limit(FEED_LIMIT)
      .filter_map do |event|
        note = event.note
        next nil unless note

        { type: "Reminder", item: note, created_at: event.happened_at, created_by: note.created_by }
      end

    (feed_items + reminders).sort_by { |item| -item[:created_at].to_i }.first(FEED_LIMIT)
  end
end
