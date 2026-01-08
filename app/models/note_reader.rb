# typed: false

class NoteReader
  # This model is not persisted to the database. It is used to render notes in the view.
  attr_accessor :note, :user

  def initialize(note:, user:)
    @note = note
    @user = user
  end

  def history_events
    return @history_events if defined?(@history_events)
    @history_events = note.history_events.where(
      note: @note,
      user: @user,
      event_type: 'read_confirmation'
    ).order(:happened_at)
  end

  def last_read_at
    return @last_read_at if defined?(@last_read_at)
    @last_read_at = history_events.last&.happened_at
  end

  def confirmed_read_but_note_updated?
    confirmed_read? && last_read_at < @note.updated_at
  end

  def confirmed_read?
    last_read_at.present?
  end

  def name
    @user&.name || 'Anonymous'
  end
end