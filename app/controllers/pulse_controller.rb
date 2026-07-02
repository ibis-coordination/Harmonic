# typed: false

class PulseController < ApplicationController
  include FeedPage

  # Override to prevent ApplicationController from trying to find a Pulse model
  def current_resource_model
    nil
  end

  # The collective's default page: a feed — a search fixed to this
  # collective (private workspaces are additionally fixed to the private
  # zone), with the current week as the default query. The cycle
  # dashboard (#show) lives at /dashboard.
  def feed
    @page_title = @current_collective.name
    workspace = @current_collective.private_workspace?
    @page_scope = workspace ? "visibility:private" : "collective:#{@current_collective.handle}"

    resolve_feed_query("cycle:this-week")
    fixed = { collective_handle: @current_collective.handle }
    fixed[:visibility] = "private" if workspace
    # cycle "all" as the base: a cleared query means all time, not the
    # search page's implicit today-window.
    @search = build_feed_search(fixed_params: fixed, params_extra: { cycle: "all" })
    @feed_items = SearchFeedItems.build(@search.paginated_results)

    # Same sidebar as the dashboard, minus the dashboard-only sections:
    # activity type filters (their counts are dashboard state), the cycle
    # box, and recent cycles. @cycle is still needed for the heartbeat
    # banner and heartbeats box.
    @hide_cycle_sidebar = true
    @cycle = current_cycle
    load_collective_sidebar_data
  end

  def actions_index
    @page_title = "Actions | #{@current_collective.name}"
    @cycle = current_cycle
    @pinned_items = @current_collective.pinned_items
    @team = @current_collective.team
    @heartbeats = Heartbeat.where_in_cycle(@cycle)
    render "shared/actions_index_collective", locals: {
      base_path: @current_collective.path,
    }
  end

  def show
    @page_title = "#{@current_collective.name} Dashboard"
    @page_scope = if @current_collective.private_workspace?
                    "visibility:private"
                  else
                    "collective:#{@current_collective.handle}"
                  end

    # Cycle data - use param if provided, otherwise default to tempo-based cycle
    @cycle = cycle_from_param || current_cycle

    # Require heartbeat to view past cycles
    if @current_user && !@cycle.is_current_cycle? && @current_heartbeat.nil?
      redirect_to "#{@current_collective.path}/dashboard", notice: "Send a heartbeat to view past cycles."
      return
    end

    load_collective_sidebar_data

    # Cycle navigation state — dashboard-only sidebar sections key off it.
    @default_cycle = current_cycle
    @is_viewing_current_cycle = @cycle.is_current_cycle?
    @recent_cycle_summaries = Cycle.recent_summaries(
      collective: @current_collective,
      tenant: current_tenant
    )

    # Content scoped to current cycle
    @unread_notes = @cycle.unread_notes(@current_user) if @current_user
    @read_notes = @cycle.read_notes(@current_user) if @current_user
    @open_decisions = @cycle.open_decisions
    @closed_decisions = @cycle.closed_decisions
    @open_commitments = @cycle.open_commitments
    @closed_commitments = @cycle.closed_commitments

    # Build unified feed (sorted by created_at desc)
    build_unified_feed

    # Counts for sidebar nav
    @notes_count = @feed_items.count { |item| item[:type] == "Note" }
    @decisions_count = @feed_items.count { |item| item[:type] == "Decision" }
    @commitments_count = @feed_items.count { |item| item[:type] == "Commitment" }
  end

  private

  # The collective sidebar sections shared by the feed and the dashboard
  # (heartbeats, pinned items). Expects @cycle to be set. The dashboard
  # additionally sets cycle-navigation state (@default_cycle etc.), which
  # the cycle box and recent-cycles sections key off.
  def load_collective_sidebar_data
    @team = @current_collective.team
    @heartbeats = Heartbeat.where_in_cycle(@cycle)
    @pinned_items = @current_collective.pinned_items
  end

  def cycle_from_param
    return nil unless params[:cycle].present?

    return nil unless valid_cycle_name?(params[:cycle])

    Cycle.new(name: params[:cycle], tenant: current_tenant, collective: current_collective)
  end

  def valid_cycle_name?(name)
    # Named cycles
    return true if ["today", "yesterday", "this-week", "last-week", "this-month", "last-month"].include?(name)

    # N-units-ago patterns (e.g., 2-days-ago, 3-weeks-ago, 2-months-ago)
    return true if name.match?(/^\d+-days-ago$/)
    return true if name.match?(/^\d+-weeks-ago$/)
    return true if name.match?(/^\d+-months-ago$/)

    false
  end

  def build_unified_feed
    cycle_start = @cycle.start_date

    # Calendar event commitments are scoped to a cycle by their event start
    # time (handled in Cycle#commitments), not their creation time — so the
    # standard `created_at >= cycle_start` filter does not apply to them.
    commitments_scope = @cycle.commitments.where(
      "commitments.created_at >= ? OR commitments.subtype = ?",
      cycle_start, "calendar_event"
    )

    @feed_items = FeedBuilder.new(
      notes_scope: @cycle.notes.where("notes.created_at >= ?", cycle_start),
      decisions_scope: @cycle.decisions.where("decisions.created_at >= ?", cycle_start),
      commitments_scope: commitments_scope,
      reminder_events_scope: NoteHistoryEvent
        .where(event_type: "reminder", collective_id: @current_collective.id)
        .where("note_history_events.happened_at >= ?", cycle_start),
      limit: 100
    ).feed_items
  end
end
