# typed: true

class ReminderFeedItemComponent < ViewComponent::Base
  extend T::Sig

  sig do
    params(
      note: Note,
      happened_at: ActiveSupport::TimeWithZone,
    ).void
  end
  def initialize(note:, happened_at:)
    super()
    @note = note
    @happened_at = happened_at
  end

  sig { returns(String) }
  def note_title
    @note.title.to_s
  end

  sig { returns(String) }
  def note_path
    T.must(@note.path)
  end

  sig { returns(ActiveSupport::TimeWithZone) }
  def happened_at
    @happened_at
  end
end
