class CreateDataImports < ActiveRecord::Migration[7.2]
  def change
    create_table :data_imports, id: :uuid do |t|
      t.references :tenant, type: :uuid, null: false, foreign_key: true
      t.references :collective, type: :uuid, null: true, foreign_key: true
      t.references :user, type: :uuid, null: false, foreign_key: true
      t.string :status, null: false, default: "pending"
      t.jsonb :source_manifest, default: {}
      t.jsonb :user_mapping, default: {}
      t.jsonb :record_counts, default: {}
      t.text :error_message
      t.datetime :started_at
      t.datetime :completed_at
      t.timestamps
    end

    add_index :data_imports, [:user_id, :status]
  end
end
