class AddReminderScheduledForToNotes < ActiveRecord::Migration[7.2]
  def change
    add_column :notes, :reminder_scheduled_for, :datetime, null: true
  end
end
