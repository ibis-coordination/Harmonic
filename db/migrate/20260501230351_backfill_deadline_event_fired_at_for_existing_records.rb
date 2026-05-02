# Backfill deadline_event_fired_at for decisions and commitments whose
# deadlines have already passed. Without this, the first run of
# DeadlineEventJob would fire events for every historical record.
class BackfillDeadlineEventFiredAtForExistingRecords < ActiveRecord::Migration[7.2]
  def up
    execute <<~SQL
      UPDATE decisions
      SET deadline_event_fired_at = deadline
      WHERE deadline < NOW()
        AND deadline_event_fired_at IS NULL
        AND deleted_at IS NULL
    SQL

    execute <<~SQL
      UPDATE commitments
      SET deadline_event_fired_at = deadline
      WHERE deadline < NOW()
        AND deadline_event_fired_at IS NULL
        AND deleted_at IS NULL
    SQL
  end

  def down
    execute "UPDATE decisions SET deadline_event_fired_at = NULL"
    execute "UPDATE commitments SET deadline_event_fired_at = NULL"
  end
end
