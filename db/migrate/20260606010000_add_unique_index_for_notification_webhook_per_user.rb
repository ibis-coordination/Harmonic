# Enforces "one notification webhook per recipient" at the DB level.
#
# A notification-webhook rule is owned by either a user (`user_id`) or an
# AI agent (`ai_agent_id`), and is identified by the presence of
# `actions->>'webhook_url'`. The unique index keys on
# `COALESCE(ai_agent_id, user_id)` so a single recipient can't have two
# webhook rules regardless of which owner column carries the FK.
#
# Loud-fails if any DB already has duplicate webhook rules for a single
# recipient (tenant_id, COALESCE(ai_agent_id, user_id)) — clean those up
# before re-running the migration.
class AddUniqueIndexForNotificationWebhookPerUser < ActiveRecord::Migration[7.2]
  def up
    dupes = ActiveRecord::Base.connection.execute(<<~SQL.squish).to_a
      SELECT tenant_id, COALESCE(ai_agent_id, user_id) AS recipient_id, COUNT(*) AS count
      FROM automation_rules
      WHERE (actions->>'webhook_url') IS NOT NULL
        AND COALESCE(ai_agent_id, user_id) IS NOT NULL
      GROUP BY tenant_id, COALESCE(ai_agent_id, user_id)
      HAVING COUNT(*) > 1
    SQL

    if dupes.any?
      raise ActiveRecord::IrreversibleMigration, <<~MSG
        Cannot create uniq_notification_webhook_per_user index — multiple
        webhook rules exist for these (tenant_id, recipient_id) pairs:
        #{dupes.map { |d| "  - tenant=#{d["tenant_id"]} recipient=#{d["recipient_id"]} count=#{d["count"]}" }.join("\n")}

        Clean up before re-running. Suggestion in a dev console:
          AutomationRule.where("(actions->>'webhook_url') IS NOT NULL").destroy_all
      MSG
    end

    execute <<~SQL.squish
      CREATE UNIQUE INDEX uniq_notification_webhook_per_user
      ON automation_rules (tenant_id, COALESCE(ai_agent_id, user_id))
      WHERE (actions->>'webhook_url') IS NOT NULL
    SQL
  end

  def down
    execute "DROP INDEX IF EXISTS uniq_notification_webhook_per_user"
  end
end
