class DropSequences < ActiveRecord::Migration[7.0]
  def up
    drop_table :sequence_history_events
    remove_index :commitments, [:sequence_id, :sequence_position]
    remove_column :commitments, :sequence_position
    remove_column :commitments, :sequence_id
    remove_index :decisions, [:sequence_id, :sequence_position]
    remove_column :decisions, :sequence_position
    remove_column :decisions, :sequence_id
    remove_index :notes, [:sequence_id, :sequence_position]
    remove_column :notes, :sequence_position
    remove_column :notes, :sequence_id
    drop_table :sequences
  end

  def down
    create_table :sequences, id: :uuid do |t|
      t.references :tenant, null: false, foreign_key: true, type: :uuid
      t.references :studio, null: false, foreign_key: true, type: :uuid
      t.references :created_by, null: false, foreign_key: { to_table: :users }, type: :uuid
      t.references :updated_by, null: false, foreign_key: { to_table: :users }, type: :uuid
      t.string :truncated_id, null: false, as: 'LEFT(id::text, 8)', stored: true
      t.string :title, null: false
      t.text :description
      t.datetime :starts_at, null: false
      t.datetime :ends_at
      t.datetime :paused_at
      t.references :paused_by, foreign_key: { to_table: :users }, type: :uuid
      t.datetime :resumed_at
      t.references :resumed_by, foreign_key: { to_table: :users }, type: :uuid
      t.string :item_type, null: false # Note, Decision, Commitment
      t.jsonb :settings, null: false, default: {}

      t.timestamps
    end
    add_index :sequences, :truncated_id, unique: true

    add_column :notes, :sequence_id, :uuid, foreign_key: true, type: :uuid
    add_column :notes, :sequence_position, :integer
    add_index :notes, [:sequence_id, :sequence_position], unique: true

    add_column :decisions, :sequence_id, :uuid, foreign_key: true, type: :uuid
    add_column :decisions, :sequence_position, :integer
    add_index :decisions, [:sequence_id, :sequence_position], unique: true

    add_column :commitments, :sequence_id, :uuid, foreign_key: true, type: :uuid
    add_column :commitments, :sequence_position, :integer
    add_index :commitments, [:sequence_id, :sequence_position], unique: true

    create_table :sequence_history_events, id: :uuid do |t|
      t.references :tenant, null: false, foreign_key: true, type: :uuid
      t.references :studio, null: false, foreign_key: true, type: :uuid
      t.references :sequence, null: false, foreign_key: true, type: :uuid
      t.references :user, null: false, foreign_key: true, type: :uuid
      t.string :event_type, null: false
      t.datetime :happened_at, null: false
      t.jsonb :data, null: false, default: {}

      t.timestamps
    end
  end
end
