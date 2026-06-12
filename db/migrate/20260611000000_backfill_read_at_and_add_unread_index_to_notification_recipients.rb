# typed: true

# Notification recipients gain a read state (unread -> read -> dismissed),
# derived from `read_at` / `dismissed_at`. Dismissing implies reading, so
# historical dismissed rows are backfilled with read_at = dismissed_at.
#
# The partial index serves the unread-badge count query:
# (user, tenant) filtered to in_app rows that are neither read nor dismissed.
class BackfillReadAtAndAddUnreadIndexToNotificationRecipients < ActiveRecord::Migration[7.2]
  def up
    execute <<~SQL.squish
      UPDATE notification_recipients
      SET read_at = dismissed_at
      WHERE dismissed_at IS NOT NULL AND read_at IS NULL
    SQL

    add_index :notification_recipients, [:user_id, :tenant_id],
              name: "index_notification_recipients_unread",
              where: "read_at IS NULL AND dismissed_at IS NULL AND channel = 'in_app'"
  end

  def down
    remove_index :notification_recipients, name: "index_notification_recipients_unread"
    # The read_at backfill is intentionally not reverted: before this
    # migration the column was unwritten, and "dismissed implies read"
    # remains true either way.
  end
end
