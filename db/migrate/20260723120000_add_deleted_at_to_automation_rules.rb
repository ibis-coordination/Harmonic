# "Delete" on an automation rule becomes archive: the rule row stays so
# run history, task-run attribution, and bridge-setup references survive
# (hard destroy cascades through automation_rule_runs and is blocked by
# FKs from harmonic_bridge_setups and ai_agent_task_runs anyway).
#
# The one-notification-webhook-per-recipient unique index must ignore
# archived rows, or a recipient could never create a replacement webhook
# after deleting one.
class AddDeletedAtToAutomationRules < ActiveRecord::Migration[7.2]
  def up
    add_column :automation_rules, :deleted_at, :datetime

    execute "DROP INDEX IF EXISTS uniq_notification_webhook_per_user"
    execute <<~SQL.squish
      CREATE UNIQUE INDEX uniq_notification_webhook_per_user
      ON automation_rules (tenant_id, COALESCE(ai_agent_id, user_id))
      WHERE (actions->>'webhook_url') IS NOT NULL AND deleted_at IS NULL
    SQL
  end

  def down
    execute "DROP INDEX IF EXISTS uniq_notification_webhook_per_user"
    execute <<~SQL.squish
      CREATE UNIQUE INDEX uniq_notification_webhook_per_user
      ON automation_rules (tenant_id, COALESCE(ai_agent_id, user_id))
      WHERE (actions->>'webhook_url') IS NOT NULL
    SQL

    remove_column :automation_rules, :deleted_at
  end
end
