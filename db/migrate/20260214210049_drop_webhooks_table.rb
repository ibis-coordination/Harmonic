class DropWebhooksTable < ActiveRecord::Migration[7.0]
  def change
    # Remove foreign key constraint from webhook_deliveries
    remove_foreign_key :webhook_deliveries, :webhooks, if_exists: true

    # Remove webhook_id column from webhook_deliveries
    remove_column :webhook_deliveries, :webhook_id, :uuid

    # Drop the webhooks table
    drop_table :webhooks do |t|
      t.uuid :tenant_id, null: false
      t.uuid :superagent_id
      t.uuid :user_id
      t.string :name
      t.string :url
      t.string :secret
      t.jsonb :events, default: []
      t.boolean :enabled, default: true
      t.jsonb :metadata, default: {}
      t.uuid :created_by_id
      t.string :truncated_id
      t.timestamps
    end
  end
end
