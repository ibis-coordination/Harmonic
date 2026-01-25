class AddScheduledForToNotificationRecipients < ActiveRecord::Migration[7.0]
  def change
    add_column :notification_recipients, :scheduled_for, :datetime
    add_index :notification_recipients, :scheduled_for, where: "scheduled_for IS NOT NULL"
  end
end
