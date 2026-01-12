class CreateWebhooksNew < ActiveRecord::Migration[7.0]
  def change
    # Drop old webhooks table if it exists (was never used)
    drop_table :webhooks if table_exists?(:webhooks)

    create_table :webhooks, id: :uuid do |t|
      t.references :tenant, type: :uuid, null: false, foreign_key: true
      t.references :studio, type: :uuid, null: true, foreign_key: true
      t.string :name, null: false
      t.string :url, null: false
      t.string :secret, null: false
      t.jsonb :events, null: false, default: []
      t.boolean :enabled, null: false, default: true
      t.references :created_by, type: :uuid, null: false, foreign_key: { to_table: :users }
      t.jsonb :metadata, null: false, default: {}

      t.timestamps
    end

    add_index :webhooks, [:tenant_id, :enabled]
    add_index :webhooks, [:studio_id, :enabled]
  end
end
