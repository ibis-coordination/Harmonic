# typed: true
# frozen_string_literal: true

# Daily sweeper that deletes notification recipients dismissed more than
# RETENTION_PERIOD ago, then deletes notifications left with no recipients.
# Without this, dismissed rows accumulate forever.
#
# Notifications referenced by a reminder note (notes.reminder_notification_id
# has an FK to notifications) are kept even when orphaned. The orphan sweep
# also skips recently created notifications: NotificationService creates the
# notification before its recipients, so a brand-new notification can be
# legitimately recipient-less for a moment.
class PurgeDismissedNotificationsJob < SystemJob
  extend T::Sig

  queue_as :low_priority

  RETENTION_PERIOD = 90.days
  ORPHAN_GRACE_PERIOD = 1.day

  sig { void }
  def perform
    NotificationRecipient.unscoped_for_system_job
      .where(dismissed_at: ...RETENTION_PERIOD.ago)
      .in_batches(of: 1_000)
      .delete_all

    Notification.unscoped_for_system_job
      .where.missing(:notification_recipients)
      .where(created_at: ...ORPHAN_GRACE_PERIOD.ago)
      .where.not(
        id: Note.unscoped_for_system_job
          .where.not(reminder_notification_id: nil)
          .select(:reminder_notification_id)
      )
      .in_batches(of: 1_000)
      .delete_all
  end
end
