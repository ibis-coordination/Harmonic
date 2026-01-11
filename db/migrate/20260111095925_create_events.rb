class CreateEvents < ActiveRecord::Migration[7.0]
  def change
    create_table :events, id: :uuid do |t|
      t.references :tenant, null: false, foreign_key: true, type: :uuid
      t.references :studio, null: false, foreign_key: true, type: :uuid
      t.string :event_type, null: false
      t.references :actor, foreign_key: { to_table: :users }, type: :uuid
      t.string :subject_type
      t.uuid :subject_id
      t.jsonb :metadata, default: {}

      t.timestamps
    end

    add_index :events, :event_type
    add_index :events, [:subject_type, :subject_id]
    add_index :events, :created_at
  end
end
