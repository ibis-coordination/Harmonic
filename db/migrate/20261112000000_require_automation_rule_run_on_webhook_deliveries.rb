# typed: true

class RequireAutomationRuleRunOnWebhookDeliveries < ActiveRecord::Migration[7.2]
  def up
    # Destroying a run used to nullify its deliveries, leaving rows the model
    # treats as invalid (belongs_to :automation_rule_run is required). A
    # delivery without its run has no rule, secret owner, or history to belong
    # to, so these orphans are removed before the column becomes NOT NULL.
    execute "DELETE FROM webhook_deliveries WHERE automation_rule_run_id IS NULL"
    change_column_null :webhook_deliveries, :automation_rule_run_id, false
  end

  def down
    change_column_null :webhook_deliveries, :automation_rule_run_id, true
  end
end
