# typed: true

# Populates the ViewContext with resources based on the route.
#
# ResourceLoader mirrors the resource loading logic from controllers, ensuring
# that templates have access to the same instance variables they would have
# in a normal controller context.
#
# Each controller has a corresponding load method:
# - {#load_home_resources} - Loads user's studios list
# - {#load_studio_resources} - Loads pinned items, team members, cycles
# - {#load_note_resources} - Loads note and note_reader
# - {#load_decision_resources} - Loads decision and decision_participant
# - {#load_commitment_resources} - Loads commitment and commitment_participant
# - {#load_notification_resources} - Loads user's notifications
# - {#load_cycle_resources} - Loads cycles list
#
# @example Loading resources for a note page
#   loader = ResourceLoader.new(
#     context: view_context,
#     route_info: { controller: "notes", action: "show", params: { id: "abc123" } }
#   )
#   loader.load_resources
#   # context.note is now populated
#   # context.note_reader is now populated (if user is logged in)
#
# @see MarkdownUiService::ViewContext For the variables being populated
#
class MarkdownUiService
  class ResourceLoader
    extend T::Sig

    sig { returns(MarkdownUiService::ViewContext) }
    attr_reader :context

    sig { returns(T::Hash[Symbol, T.untyped]) }
    attr_reader :route_info

    sig do
      params(
        context: MarkdownUiService::ViewContext,
        route_info: T::Hash[Symbol, T.untyped]
      ).void
    end
    def initialize(context:, route_info:)
      @context = context
      @route_info = route_info
    end

    sig { void }
    def load_resources
      controller = route_info[:controller]
      action = route_info[:action]
      params = route_info[:params]

      case controller
      when "home"
        load_home_resources(action)
      when "studios"
        load_studio_resources(action, params)
      when "pulse"
        load_pulse_resources(action, params)
      when "notes"
        load_note_resources(action, params)
      when "decisions"
        load_decision_resources(action, params)
      when "commitments"
        load_commitment_resources(action, params)
      when "notifications"
        load_notification_resources(action)
      when "users"
        load_user_resources(action, params)
      when "cycles"
        load_cycle_resources(action, params)
      end
    end

    private

    sig { params(action: String).void }
    def load_home_resources(action)
      context.page_title = "Home"

      # Load user's studios
      if context.current_user
        context.studios = T.must(context.current_user).superagents.where(superagent_type: "studio").order(created_at: :desc).to_a
      else
        context.studios = []
      end
    end

    sig { params(action: String, params: T::Hash[Symbol, T.untyped]).void }
    def load_studio_resources(action, params)
      superagent = context.current_superagent

      case action
      when "show"
        context.page_title = superagent.name
        context.pinned_items = superagent.pinned_items
        context.team = superagent.users.to_a
      when "index"
        context.page_title = "Studios"
      when "new"
        context.page_title = "New Studio"
      when "join"
        context.page_title = "Join #{superagent.name}"
      when "settings"
        context.page_title = "Settings | #{superagent.name}"
      when "team"
        context.page_title = "Team | #{superagent.name}"
        context.team = superagent.users.to_a
      when "cycles"
        context.page_title = "Cycles | #{superagent.name}"
        context.cycles = T.unsafe(superagent).cycles.order(start_date: :desc).limit(20).to_a
      when "backlinks"
        context.page_title = "Backlinks | #{superagent.name}"
      end
    end

    sig { params(action: String, params: T::Hash[Symbol, T.untyped]).void }
    def load_note_resources(action, params)
      superagent = context.current_superagent

      case action
      when "new"
        context.page_title = "New Note"
      when "show", "edit"
        note_id = params[:id] || params[:note_id]
        return unless note_id

        note = Note.find_by(truncated_id: note_id)
        return unless note

        context.note = note
        context.page_title = note.title.present? ? note.title : "Note #{note.truncated_id}"

        if context.current_user
          context.note_reader = NoteReader.new(note: note, user: T.must(context.current_user))
        end
      end
    end

    sig { params(action: String, params: T::Hash[Symbol, T.untyped]).void }
    def load_decision_resources(action, params)
      superagent = context.current_superagent

      case action
      when "new"
        context.page_title = "New Decision"
      when "show", "settings"
        decision_id = params[:id] || params[:decision_id]
        return unless decision_id

        decision = Decision.find_by(truncated_id: decision_id)
        return unless decision

        context.decision = decision
        context.page_title = decision.question.present? ? decision.question : "Decision #{decision.truncated_id}"

        if context.current_user
          context.decision_participant = DecisionParticipantManager.new(
            decision: decision,
            user: T.must(context.current_user)
          ).find_or_create_participant
        end
      end
    end

    sig { params(action: String, params: T::Hash[Symbol, T.untyped]).void }
    def load_commitment_resources(action, params)
      superagent = context.current_superagent

      case action
      when "new"
        context.page_title = "New Commitment"
      when "show", "settings"
        commitment_id = params[:id] || params[:commitment_id]
        return unless commitment_id

        commitment = Commitment.find_by(truncated_id: commitment_id)
        return unless commitment

        context.commitment = commitment
        context.page_title = commitment.title.present? ? commitment.title : "Commitment #{commitment.truncated_id}"

        if context.current_user
          context.commitment_participant = CommitmentParticipantManager.new(
            commitment: commitment,
            user: T.must(context.current_user)
          ).find_or_create_participant
        end
      end
    end

    sig { params(action: String).void }
    def load_notification_resources(action)
      context.page_title = "Notifications"

      if context.current_user
        context.notifications = NotificationRecipient
          .where(user: context.current_user)
          .includes(:notification)
          .order(created_at: :desc)
          .limit(50)
          .to_a
      end
    end

    sig { params(action: String, params: T::Hash[Symbol, T.untyped]).void }
    def load_user_resources(action, params)
      handle = params[:handle]
      context.page_title = handle ? "User: #{handle}" : "User"
    end

    sig { params(action: String, params: T::Hash[Symbol, T.untyped]).void }
    def load_cycle_resources(action, params)
      context.page_title = "Cycles"
      context.cycles = T.unsafe(context.current_superagent).cycles.order(start_date: :desc).limit(20).to_a
    end

    sig { params(action: String, params: T::Hash[Symbol, T.untyped]).void }
    def load_pulse_resources(action, params)
      superagent = context.current_superagent

      context.page_title = superagent.name

      # Get the current cycle
      cycle = superagent.current_cycle
      context.cycle = cycle
      context.is_viewing_current_cycle = cycle.is_current_cycle?

      # Load team and pinned items
      context.team = superagent.users.to_a
      context.pinned_items = superagent.pinned_items

      # Build feed items
      context.feed_items = build_feed_items(cycle)
    end

    sig { params(cycle: T.nilable(Cycle)).returns(T::Array[T::Hash[Symbol, T.untyped]]) }
    def build_feed_items(cycle)
      return [] unless cycle

      cycle_start = cycle.start_date

      notes = cycle.notes
        .where("notes.created_at >= ?", cycle_start)
        .includes(:created_by)
        .limit(100)
        .map do |note|
        { type: "Note", item: note, created_at: note.created_at, created_by: note.created_by }
      end

      decisions = cycle.decisions
        .where("decisions.created_at >= ?", cycle_start)
        .includes(:created_by)
        .limit(100)
        .map do |decision|
        { type: "Decision", item: decision, created_at: decision.created_at, created_by: decision.created_by }
      end

      commitments = cycle.commitments
        .where("commitments.created_at >= ?", cycle_start)
        .includes(:created_by)
        .limit(100)
        .map do |commitment|
        { type: "Commitment", item: commitment, created_at: commitment.created_at, created_by: commitment.created_by }
      end

      (notes + decisions + commitments).sort_by { |item| -item[:created_at].to_i }
    end
  end
end
