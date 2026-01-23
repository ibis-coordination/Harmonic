# typed: false

class PulseController < ApplicationController
  layout "pulse"

  # Override to prevent ApplicationController from trying to find a Pulse model
  def current_resource_model
    nil
  end

  def show
    return render "shared/404", status: :not_found unless @current_superagent.superagent_type == "studio"

    @page_title = "Pulse | #{@current_superagent.name}"

    # Cycle data - use param if provided, otherwise default to tempo-based cycle
    @cycle = cycle_from_param || current_cycle
    @default_cycle = current_cycle
    @is_viewing_current_cycle = @cycle.is_current_cycle?

    # Content scoped to current cycle
    @unread_notes = @cycle.unread_notes(@current_user) if @current_user
    @read_notes = @cycle.read_notes(@current_user) if @current_user
    @open_decisions = @cycle.open_decisions
    @closed_decisions = @cycle.closed_decisions
    @open_commitments = @cycle.open_commitments
    @closed_commitments = @cycle.closed_commitments

    # Studio data
    @team = @current_superagent.team
    @heartbeats = Heartbeat.where_in_cycle(@cycle)
    @pinned_items = @current_superagent.pinned_items

    # Build unified feed (sorted by created_at desc)
    build_unified_feed
  end

  private

  def cycle_from_param
    return nil unless params[:cycle].present?

    return nil unless valid_cycle_name?(params[:cycle])

    Cycle.new(name: params[:cycle], tenant: current_tenant, superagent: current_superagent)
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
    # Filter for items created within the current cycle (not just deadline overlapping)
    cycle_start = @cycle.start_date

    notes = @cycle.notes
      .where("notes.created_at >= ?", cycle_start)
      .includes(:created_by)
      .limit(100)
      .map do |note|
      { type: "Note", item: note, created_at: note.created_at, created_by: note.created_by }
    end

    decisions = @cycle.decisions
      .where("decisions.created_at >= ?", cycle_start)
      .includes(:created_by)
      .limit(100)
      .map do |decision|
      { type: "Decision", item: decision, created_at: decision.created_at, created_by: decision.created_by }
    end

    commitments = @cycle.commitments
      .where("commitments.created_at >= ?", cycle_start)
      .includes(:created_by)
      .limit(100)
      .map do |commitment|
      { type: "Commitment", item: commitment, created_at: commitment.created_at, created_by: commitment.created_by }
    end

    @feed_items = (notes + decisions + commitments).sort_by { |item| -item[:created_at].to_i }
  end
end
