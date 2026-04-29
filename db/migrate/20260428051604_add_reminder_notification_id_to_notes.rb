class AddReminderNotificationIdToNotes < ActiveRecord::Migration[7.2]
  def change
    add_column :notes, :reminder_notification_id, :uuid, null: true
    add_foreign_key :notes, :notifications, column: :reminder_notification_id
    add_index :notes, :reminder_notification_id, where: "reminder_notification_id IS NOT NULL"
  end
end
