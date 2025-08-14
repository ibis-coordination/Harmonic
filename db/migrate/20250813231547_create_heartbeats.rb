class CreateHeartbeats < ActiveRecord::Migration[7.0]
  def change
    create_table :heartbeats, id: :uuid do |t|
      t.references :tenant, null: false, foreign_key: true, type: :uuid
      t.references :studio, null: false, foreign_key: true, type: :uuid
      t.references :user, null: false, foreign_key: true, type: :uuid
      t.datetime :expires_at, null: false
      t.jsonb :activity_log, null: false, default: {}
      t.string :truncated_id, null: false, as: 'LEFT(id::text, 8)', stored: true

      t.timestamps
    end
    add_index :heartbeats, :truncated_id, unique: true
    add_index :heartbeats, [:tenant_id, :studio_id, :user_id, :expires_at], unique: true, name: 'index_heartbeats_on_tenant_studio_user_expires_at'
  end
end
