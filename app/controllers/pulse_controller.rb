# typed: false

class PulseController < ApplicationController
  # Override to prevent ApplicationController from trying to find a Pulse model
  def current_resource_model
    nil
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
    @page_title = @current_collective.name

    # Cycle data - use param if provided, otherwise default to tempo-based cycle
    @cycle = cycle_from_param || current_cycle
    @default_cycle = current_cycle
    @is_viewing_current_cycle = @cycle.is_current_cycle?

    # Require heartbeat to view past cycles
    if @current_user && !@is_viewing_current_cycle && @current_heartbeat.nil?
      redirect_to @current_collective.path, notice: "Send a heartbeat to view past cycles."
      return
    end

    # Content scoped to current cycle
    @unread_notes = @cycle.unread_notes(@current_user) if @current_user
    @read_notes = @cycle.read_notes(@current_user) if @current_user
    @open_decisions = @cycle.open_decisions
    @closed_decisions = @cycle.closed_decisions
    @open_commitments = @cycle.open_commitments
    @closed_commitments = @cycle.closed_commitments

    # Collective data
    @team = @current_collective.team
    @heartbeats = Heartbeat.where_in_cycle(@cycle)
    @pinned_items = @current_collective.pinned_items

    # Build unified feed (sorted by created_at desc)
    build_unified_feed

    # Counts for sidebar nav
    @notes_count = @feed_items.count { |item| item[:type] == "Note" }
    @decisions_count = @feed_items.count { |item| item[:type] == "Decision" }
    @commitments_count = @feed_items.count { |item| item[:type] == "Commitment" }
  end

  private

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

    @feed_items = FeedBuilder.new(
      notes_scope: @cycle.notes.where("notes.created_at >= ?", cycle_start),
      decisions_scope: @cycle.decisions.where("decisions.created_at >= ?", cycle_start),
      commitments_scope: @cycle.commitments.where("commitments.created_at >= ?", cycle_start),
      reminder_events_scope: NoteHistoryEvent
        .where(event_type: "reminder", collective_id: @current_collective.id)
        .where("note_history_events.happened_at >= ?", cycle_start),
      limit: 100,
    ).feed_items
  end
end
