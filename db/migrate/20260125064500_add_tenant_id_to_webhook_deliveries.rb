class AddTenantIdToWebhookDeliveries < ActiveRecord::Migration[7.0]
  def up
    # Add column as nullable first
    add_reference :webhook_deliveries, :tenant, null: true, foreign_key: true, type: :uuid

    # Backfill tenant_id from associated webhook
    execute <<-SQL
      UPDATE webhook_deliveries
      SET tenant_id = webhooks.tenant_id
      FROM webhooks
      WHERE webhook_deliveries.webhook_id = webhooks.id
    SQL

    # Now make it not null
    change_column_null :webhook_deliveries, :tenant_id, false
  end

  def down
    remove_reference :webhook_deliveries, :tenant
  end
end
