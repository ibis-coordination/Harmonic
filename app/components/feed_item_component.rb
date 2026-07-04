# typed: true

class FeedItemComponent < ViewComponent::Base
  extend T::Sig

  sig do
    params(
      item: T.any(Note, Decision, Commitment),
      type: String,
      created_by: T.nilable(User),
      created_at: ActiveSupport::TimeWithZone,
      current_user: T.nilable(User),
      blocked_user_ids: T::Set[String],
      block_related_user_ids: T::Set[String],
      voted_decision_ids: T.nilable(T::Set[String])
    ).void
  end
  def initialize(item:, type:, created_by:, created_at:, current_user: nil, blocked_user_ids: Set.new, block_related_user_ids: Set.new,
                 voted_decision_ids: nil)
    super()
    @item = item
    @type = type
    @created_by = created_by
    @created_at = created_at
    @current_user = current_user
    @blocked_user_ids = blocked_user_ids
    @block_related_user_ids = block_related_user_ids
    # When the parent feed view passes a precomputed set of decision IDs the
    # viewer has voted on, skip the per-card EXISTS query in
    # show_decision_results?. Falls back to the Decision#user_has_voted?
    # query when nil (component used in isolation or in older callers).
    @voted_decision_ids = voted_decision_ids
  end

  private

  # Where clicking the card (or its title) lands. Notes use display_path so
  # a comment opens its thread with the comment marked (?comment_id=) —
  # the same URL its notification links to — rather than the isolated
  # comment page. Action endpoints keep building from @item.path, the
  # canonical bare resource URL.
  sig { returns(T.nilable(String)) }
  def navigate_path
    @item.is_a?(Note) ? @item.display_path : @item.path
  end

  sig { returns(T::Boolean) }
  def author_blocked?
    @created_by.present? && @blocked_user_ids.include?(@created_by.id)
  end

  sig { returns(T::Boolean) }
  def block_exists_with_author?
    @created_by.present? && @block_related_user_ids.include?(@created_by.id)
  end

  sig { returns(T::Boolean) }
  def is_comment?
    @type == "Note" && @item.is_a?(Note) && @item.is_comment?
  end

  sig { returns(T::Boolean) }
  def is_statement?
    @type == "Note" && @item.is_a?(Note) && @item.is_statement?
  end

  sig { returns(T::Boolean) }
  def is_summary?
    @type == "Note" && @item.is_a?(Note) && @item.is_summary?
  end

  sig { returns(String) }
  def display_type
    return "Comment" if is_comment?
    return "Statement" if is_statement?
    return "Summary" if is_summary?
    return "Table" if @type == "Note" && @item.is_a?(Note) && @item.is_table?
    return "Reminder" if @type == "Note" && @item.is_a?(Note) && @item.is_reminder?
    return "Executive Decision" if @type == "Decision" && @item.is_a?(Decision) && @item.is_executive?
    return "Lottery" if @type == "Decision" && @item.is_a?(Decision) && @item.is_lottery?
    return "Event" if @type == "Commitment" && @item.is_a?(Commitment) && @item.is_calendar_event?
    return "Policy" if @type == "Commitment" && @item.is_a?(Commitment) && @item.is_policy?

    @type
  end

  sig { returns(T::Boolean) }
  def is_policy_commitment?
    @type == "Commitment" && @item.is_a?(Commitment) && @item.is_policy?
  end

  sig { returns(T::Boolean) }
  def is_calendar_event_commitment?
    @type == "Commitment" && @item.is_a?(Commitment) && @item.is_calendar_event?
  end

  sig { returns(String) }
  def join_action_label
    return "Sign" if is_policy_commitment?
    return "RSVP" if is_calendar_event_commitment?

    "Join"
  end

  sig { returns(String) }
  def joined_label
    return "Signed" if is_policy_commitment?
    return "RSVP'd" if is_calendar_event_commitment?

    "Joined"
  end

  sig { returns(String) }
  def join_action_icon
    return "check" if is_policy_commitment?
    return "calendar" if is_calendar_event_commitment?

    "person-add"
  end

  sig { returns(T.nilable(String)) }
  def item_status
    return unless @type == "Decision" || @type == "Commitment"

    @item.closed? ? "closed" : "open"
  end

  # True when the current viewer has voted on this Decision card. Used by
  # both `show_decision_results?` (gate the tally display) and the footer
  # branch that renders the disabled "Voted" button. Prefers the
  # precomputed `voted_decision_ids` set passed from the parent feed view
  # (eliminates the per-card EXISTS query); falls back to the model method
  # for callers using the component in isolation.
  sig { returns(T::Boolean) }
  def user_has_voted?
    return false unless @type == "Decision" && @item.is_a?(Decision) && @current_user

    if @voted_decision_ids
      @voted_decision_ids.include?(@item.id)
    else
      @item.user_has_voted?(@current_user)
    end
  end

  # Vote tallies are a blind-taste-test data leak when shown to users who
  # haven't voted yet — same rule the show page enforces via
  # @show_results = closed? || current_user_has_voted
  # (decisions_controller.rb:109). Executive and lottery decisions never
  # show tallies in the card (different branch in the template).
  sig { returns(T::Boolean) }
  def show_decision_results?
    return false unless @type == "Decision" && @item.is_a?(Decision)

    @item.closed? || user_has_voted?
  end

  sig { returns(T.nilable(String)) }
  def item_title
    case @type
    when "Decision" then T.cast(@item, Decision).question
    else @item.title
    end
  end

  sig { returns(T.nilable(String)) }
  def item_content
    case @type
    when "Note" then T.cast(@item, Note).text
    else T.unsafe(@item).description
    end
  end

  sig { returns(T::Boolean) }
  def show_title?
    # Note#title falls back to the first line of text when persisted_title is
    # blank — without this gate, a titleless multi-line note would render its
    # first line as the title AND the full text as the body, duplicating the
    # first line. Only render the title row when the user actually typed one.
    return false if is_statement? || is_summary?
    return T.cast(@item, Note).persisted_title.present? if @type == "Note"

    true
  end

  sig { returns(T::Boolean) }
  def representation?
    @item.respond_to?(:created_via_representation?) &&
      T.unsafe(@item).created_via_representation? &&
      T.unsafe(@item).representative_user.present?
  end

  sig { returns(T.nilable(User)) }
  def display_author
    representation? ? T.unsafe(@item).representative_user : @created_by
  end

  sig { returns(T.nilable(User)) }
  def representative
    T.unsafe(@item).representative_user if representation?
  end

  # NOTE: read confirmation data

  sig { returns(T::Boolean) }
  def user_has_read?
    return false unless @current_user && @item.is_a?(Note)

    @item.user_has_read?(@current_user)
  end

  sig { returns(Integer) }
  def read_count
    return 0 unless @item.is_a?(Note)

    read_confirmations_scope.select(:user_id).distinct.count
  end

  sig { returns(T.untyped) }
  def read_confirmations_scope
    @read_confirmations_scope ||= (@item.note_history_events.where(event_type: "read_confirmation") if @item.is_a?(Note))
  end

  # Commitment: participation data

  sig { returns(T::Boolean) }
  def user_has_joined?
    return false unless @current_user && @item.is_a?(Commitment)

    @item.participants.where(user: @current_user).where.not(committed_at: nil).exists?
  end

  sig { returns(Integer) }
  def participant_count
    return 0 unless @item.is_a?(Commitment)

    @item.participant_count
  end

  sig { returns(Integer) }
  def critical_mass
    return 0 unless @item.is_a?(Commitment)

    T.must(@item.critical_mass)
  end

  sig { returns(Integer) }
  def progress_percent
    return 0 if critical_mass.zero?

    [(participant_count.to_f / critical_mass * 100).to_i, 100].min
  end

  sig { returns(Integer) }
  def remaining
    [critical_mass - participant_count, 0].max
  end
end
