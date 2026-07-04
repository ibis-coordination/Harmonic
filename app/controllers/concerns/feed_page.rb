# typed: false

# Shared mechanics for feed pages (docs/NAVIGATION_DESIGN.md "Feeds are
# queries"): every feed is a search with a fixed page scope and a default
# query the viewer owns. `?q` absent applies the default; `?q` present —
# even empty — is the viewer's own refinement.
module FeedPage
  extend ActiveSupport::Concern

  FEED_LIMIT = 30

  included do
    helper_method :default_feed_view?
  end

  private

  # Sets @feed_query (what the search runs), @feed_default_query (what ?q
  # absence means), and @page_query (markdown frontmatter `query:`).
  def resolve_feed_query(default)
    @feed_default_query = default
    @feed_query = params.key?(:q) ? params[:q].to_s : default
    @page_query = @feed_query.strip.presence
    @feed_query
  end

  def default_feed_view?
    @feed_query.strip == @feed_default_query
  end

  # No hidden filters: a feed's comment exclusion lives in its visible
  # default query (`-subtype:comment`), where the viewer can see it and
  # remove it. A viewer-supplied query gets raw search semantics, same as
  # /search.
  def build_feed_search(fixed_params:, params_extra: {}, query: @feed_query)
    SearchQuery.new(
      tenant: @current_tenant,
      current_user: @current_user,
      raw_query: query,
      params: { per_page: FEED_LIMIT }.merge(params_extra),
      fixed_params: fixed_params
    )
  end

  # Fired reminders resurface on default feed views only (a refined query
  # is an explicit search; surprise reminders would be noise there).
  # Reminders are events, not indexed content, so they merge in here
  # rather than through SearchQuery.
  def interleave_reminder_events(feed_items, author_ids:)
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
