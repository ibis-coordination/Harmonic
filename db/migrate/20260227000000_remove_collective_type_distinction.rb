class RemoveCollectiveTypeDistinction < ActiveRecord::Migration[7.2]
  def up
    # Make collective_type nullable, remove default (leave existing values intact)
    change_column_null :collectives, :collective_type, true
    change_column_default :collectives, :collective_type, nil

    # Backfill: ensure all collectives have timezone, tempo, synchronization_mode in settings
    # Scenes may not have had these set.
    execute <<-SQL
      UPDATE collectives
      SET settings = settings || '{"timezone": "UTC", "tempo": "weekly", "synchronization_mode": "improv"}'::jsonb
      WHERE NOT (settings ? 'timezone')
         OR NOT (settings ? 'tempo')
         OR NOT (settings ? 'synchronization_mode')
    SQL

    # Remove open_scene from settings for all collectives
    execute <<-SQL
      UPDATE collectives
      SET settings = settings - 'open_scene'
      WHERE settings ? 'open_scene'
    SQL
  end

  def down
    change_column_default :collectives, :collective_type, "studio"
    execute "UPDATE collectives SET collective_type = 'studio' WHERE collective_type IS NULL"
    change_column_null :collectives, :collective_type, false, "studio"
  end
end
