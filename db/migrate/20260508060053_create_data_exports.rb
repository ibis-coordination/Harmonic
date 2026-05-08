class CreateDataExports < ActiveRecord::Migration[7.2]
  def change
    create_table :data_exports, id: :uuid do |t|
      t.references :tenant, type: :uuid, null: false, foreign_key: true
      t.references :collective, type: :uuid, null: false, foreign_key: true
      t.references :user, type: :uuid, null: false, foreign_key: true
      t.string :status, null: false, default: "pending"
      t.jsonb :record_counts, default: {}
      t.text :error_message
      t.datetime :expires_at
      t.datetime :started_at
      t.datetime :completed_at
      t.timestamps
    end

    add_index :data_exports, [:user_id, :status]
  end
end
