class RemoveActivityLogSystemFromRepresentationSessions < ActiveRecord::Migration[7.0]
  def up
    # Remove the old JSON-based activity_log column
    remove_column :representation_sessions, :activity_log, :jsonb

    # Drop the old associations table (replaced by representation_session_events)
    drop_table :representation_session_associations
  end

  def down
    # Restore activity_log column
    add_column :representation_sessions, :activity_log, :jsonb, default: {}

    # Restore associations table
    create_table :representation_session_associations, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :tenant, null: false, foreign_key: true, type: :uuid
      t.references :superagent, null: true, foreign_key: true, type: :uuid
      t.references :representation_session, null: false, foreign_key: true, type: :uuid
      t.references :resource, polymorphic: true, null: false, type: :uuid
      t.references :resource_superagent, null: false, foreign_key: { to_table: :superagents }, type: :uuid
      t.timestamps
    end
  end
end
