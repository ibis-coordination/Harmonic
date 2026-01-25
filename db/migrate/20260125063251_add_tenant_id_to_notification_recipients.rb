class AddTenantIdToNotificationRecipients < ActiveRecord::Migration[7.0]
  def up
    # Add column as nullable first
    add_reference :notification_recipients, :tenant, null: true, foreign_key: true, type: :uuid

    # Backfill tenant_id from associated notification
    execute <<-SQL
      UPDATE notification_recipients
      SET tenant_id = notifications.tenant_id
      FROM notifications
      WHERE notification_recipients.notification_id = notifications.id
    SQL

    # Now make it not null
    change_column_null :notification_recipients, :tenant_id, false
  end

  def down
    remove_reference :notification_recipients, :tenant
  end
end
