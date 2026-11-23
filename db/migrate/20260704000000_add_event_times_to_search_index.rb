# typed: false

class AddEventTimesToSearchIndex < ActiveRecord::Migration[7.2]
  def up
    add_column :search_index, :starts_at, :timestamp
    add_column :search_index, :ends_at, :timestamp

    # Backfill calendar-event rows from their commitments so existing events
    # get the widened feed window without waiting for a full reindex.
    execute <<-SQL.squish
      UPDATE search_index si
      SET starts_at = c.starts_at, ends_at = c.ends_at
      FROM commitments c
      WHERE si.item_type = 'Commitment'
        AND si.item_id = c.id
        AND c.subtype = 'calendar_event'
    SQL
  end

  def down
    remove_column :search_index, :starts_at
    remove_column :search_index, :ends_at
  end
end
