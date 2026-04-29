# typed: true

class NoteReminderService
  extend T::Sig

  sig { params(note: Note).void }
  def initialize(note)
    @note = note
    raise "Not a reminder note" unless @note.is_reminder?
  end

  # State queries

  sig { returns(T::Boolean) }
  def pending?
    nr = recipient
    nr.present? && nr.status == "pending"
  end

  sig { returns(T::Boolean) }
  def delivered?
    nr = recipient
    nr.present? && nr.status == "delivered"
  end

  sig { returns(T::Boolean) }
  def cancelled?
    @note.reminder_notification_id.nil? && @note.reminder_scheduled_for.present?
  end

  sig { returns(T::Boolean) }
  def editable?
    pending?
  end

  # Accessors

  sig { returns(T.nilable(ActiveSupport::TimeWithZone)) }
  def scheduled_for
    @note.reminder_scheduled_for
  end

  sig { returns(T.nilable(NotificationRecipient)) }
  def recipient
    return nil unless @note.reminder_notification_id.present?

    @note.reminder_notification&.notification_recipients&.first
  end

  sig { returns(Integer) }
  def acknowledgments
    @note.note_history_events.where(event_type: "reminder_acknowledged").select(:user_id).distinct.count
  end

  # Actions

  sig { void }
  def cancel!
    return unless @note.reminder_notification_id.present?

    notification = @note.reminder_notification
    @note.reminder_notification_id = nil
    @note.save!

    if notification
      notification.notification_recipients.destroy_all
      notification.destroy!
    end
  end

  sig { params(user: User).returns(NoteHistoryEvent) }
  def acknowledge!(user)
    existing = NoteHistoryEvent.find_by(
      note: @note,
      user: user,
      event_type: "reminder_acknowledged"
    )
    return existing if existing && T.must(existing.happened_at) > T.must(@note.updated_at)

    NoteHistoryEvent.create!(
      note: @note,
      user: user,
      event_type: "reminder_acknowledged",
      happened_at: Time.current
    )
  end
end
