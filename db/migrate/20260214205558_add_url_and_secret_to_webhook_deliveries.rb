class AddUrlAndSecretToWebhookDeliveries < ActiveRecord::Migration[7.0]
  def change
    add_column :webhook_deliveries, :url, :string
    add_column :webhook_deliveries, :secret, :string
  end
end
