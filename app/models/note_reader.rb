# typed: true

class NoteReader
  extend T::Sig

  # This model is not persisted to the database. It is used to render notes in the view.
  attr_accessor :note, :user

  sig { params(note: Note, user: User).void }
  def initialize(note:, user:)
    @note = note
    @user = user
  end

  sig { returns(ActiveRecord::Relation) }
  def history_events
    return T.must(@history_events) if defined?(@history_events) && @history_events
    @history_events = T.let(T.must(note).history_events.where(
      note: @note,
      user: @user,
      event_type: 'read_confirmation'
    ).order(:happened_at), T.nilable(ActiveRecord::Relation))
    T.must(@history_events)
  end

  sig { returns(T.nilable(ActiveSupport::TimeWithZone)) }
  def last_read_at
    return @last_read_at if defined?(@last_read_at)
    @last_read_at = T.let(history_events.last&.happened_at, T.nilable(ActiveSupport::TimeWithZone))
  end

  sig { returns(T::Boolean) }
  def confirmed_read_but_note_updated?
    confirmed_read? && T.must(last_read_at) < T.must(@note).updated_at
  end

  sig { returns(T::Boolean) }
  def confirmed_read?
    last_read_at.present?
  end

  # Reminder acknowledgment state

  sig { returns(T::Boolean) }
  def acknowledged_reminder?
    last_acknowledged_at.present?
  end

  sig { returns(T::Boolean) }
  def acknowledged_but_note_updated?
    acknowledged_reminder? && T.must(last_acknowledged_at) < T.must(@note).updated_at
  end

  sig { returns(T.nilable(ActiveSupport::TimeWithZone)) }
  def last_acknowledged_at
    return @last_acknowledged_at if defined?(@last_acknowledged_at)
    @last_acknowledged_at = T.let(
      T.must(note).history_events.where(
        user: @user,
        event_type: "reminder_acknowledged"
      ).order(:happened_at).last&.happened_at,
      T.nilable(ActiveSupport::TimeWithZone)
    )
  end

  sig { returns(String) }
  def name
    @user.name
  end
end