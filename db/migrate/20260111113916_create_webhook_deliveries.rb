class CreateWebhookDeliveries < ActiveRecord::Migration[7.0]
  def change
    create_table :webhook_deliveries, id: :uuid do |t|
      t.references :webhook, type: :uuid, null: false, foreign_key: true
      t.references :event, type: :uuid, null: false, foreign_key: true
      t.string :status, null: false, default: 'pending'
      t.integer :attempt_count, null: false, default: 0
      t.text :request_body
      t.integer :response_code
      t.text :response_body
      t.text :error_message
      t.datetime :delivered_at
      t.datetime :next_retry_at

      t.timestamps
    end

    add_index :webhook_deliveries, :status
    add_index :webhook_deliveries, [:status, :next_retry_at]
  end
end
