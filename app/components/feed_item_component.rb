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
      block_related_user_ids: T::Set[String]
    ).void
  end
  def initialize(item:, type:, created_by:, created_at:, current_user: nil, blocked_user_ids: Set.new, block_related_user_ids: Set.new)
    super()
    @item = item
    @type = type
    @created_by = created_by
    @created_at = created_at
    @current_user = current_user
    @blocked_user_ids = blocked_user_ids
    @block_related_user_ids = block_related_user_ids
  end

  private

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

  sig { returns(String) }
  def display_type
    is_comment? ? "Comment" : @type
  end

  sig { returns(T.nilable(String)) }
  def item_status
    return unless @type == "Decision" || @type == "Commitment"

    @item.closed? ? "closed" : "open"
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
    if @type == "Note"
      @item.title.to_s.strip != T.cast(@item, Note).text.to_s.strip
    else
      true
    end
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
