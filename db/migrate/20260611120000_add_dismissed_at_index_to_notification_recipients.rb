# typed: true

# Supports PurgeDismissedNotificationsJob's batched delete
# (WHERE dismissed_at < cutoff), which would otherwise seq-scan the table
# once per batch. Partial: only dismissed rows enter the index.
class AddDismissedAtIndexToNotificationRecipients < ActiveRecord::Migration[7.2]
  def change
    add_index :notification_recipients, :dismissed_at,
              name: "index_notification_recipients_on_dismissed_at",
              where: "dismissed_at IS NOT NULL"
  end
end
