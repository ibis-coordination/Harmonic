class AddDeletionReminderSentAt < ActiveRecord::Migration[7.2]
  def change
    # Stamped when the pre-scrub reminder email goes out, so the daily job
    # sends it exactly once per deletion request even if a run is missed.
    # Cleared when a new deletion request starts a fresh cycle.
    add_column :users, :deletion_reminder_sent_at, :datetime
    add_column :tenant_users, :deletion_reminder_sent_at, :datetime
  end
end
