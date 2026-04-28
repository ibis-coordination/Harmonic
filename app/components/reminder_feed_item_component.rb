# typed: true

class ReminderFeedItemComponent < ViewComponent::Base
  extend T::Sig

  sig do
    params(
      event: NoteHistoryEvent,
      current_user: T.nilable(User),
    ).void
  end
  def initialize(event:, current_user: nil)
    super()
    @event = event
    @note = T.let(T.must(event.note), Note)
    @current_user = current_user
  end

  sig { returns(String) }
  def note_title
    @note.title
  end

  sig { returns(String) }
  def note_path
    T.must(@note.path)
  end

  sig { returns(ActiveSupport::TimeWithZone) }
  def happened_at
    T.must(@event.happened_at)
  end
end
