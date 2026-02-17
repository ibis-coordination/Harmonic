class AddAutomationRuleRunToWebhookDeliveries < ActiveRecord::Migration[7.0]
  def change
    # Add automation_rule_run reference for traceability
    add_reference :webhook_deliveries, :automation_rule_run, type: :uuid, foreign_key: true, index: true

    # Make webhook_id optional (deliveries can now come from automation rules)
    change_column_null :webhook_deliveries, :webhook_id, true

    # Make event_id optional (scheduled automations may not have a triggering event)
    change_column_null :webhook_deliveries, :event_id, true
  end
end
