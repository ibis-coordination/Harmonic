# typed: true

# Makes the two implicit dimensions of automation rules explicit columns:
#
#   rule_type      — "automation" (general rules) vs "notification_webhook"
#                    (the one-per-recipient notification forwarder). Until
#                    now the forwarders were recognized by their actions
#                    shape (`actions->>'webhook_url'`), which every listing,
#                    gate, and uniqueness check had to re-sniff.
#   system_managed — true when a platform process owns the rule's lifecycle
#                    (persona defaults seeded and toggled by
#                    PersonaActivator). Without a marker, deactivation
#                    disabled every rule on the agent, including
#                    user-authored ones.
#
# The unique notification-webhook index re-keys from the actions shape to
# rule_type. Pending bridge rules (minted without a URL) now count toward
# uniqueness, which is the intended invariant: at most one notification-
# webhook rule per recipient, pending or registered.
class AddRuleTypeAndSystemManagedToAutomationRules < ActiveRecord::Migration[7.2]
  def up
    change_table :automation_rules, bulk: true do |t|
      t.string :rule_type, null: false, default: "automation"
      t.boolean :system_managed, null: false, default: false
    end

    # Forwarders are rows with the webhook_url actions shape, plus URL-less
    # pending rules minted by a bridge setup (previously marked only by the
    # "harmonic-bridge (pending setup)" name convention — the setup
    # reference is the reliable marker).
    execute <<~SQL
      UPDATE automation_rules
      SET rule_type = 'notification_webhook'
      WHERE (actions->>'webhook_url') IS NOT NULL
         OR id IN (
           SELECT automation_rule_id FROM harmonic_bridge_setups
           WHERE automation_rule_id IS NOT NULL
             AND webhook_registered_at IS NULL
         )
    SQL

    # Persona-seeded defaults: rules on a persona agent (users.system_role)
    # created by the agent itself. PersonaActivator.seed_default_automations!
    # sets created_by_id to the agent; human automators set themselves.
    execute <<~SQL
      UPDATE automation_rules
      SET system_managed = TRUE
      WHERE ai_agent_id IS NOT NULL
        AND ai_agent_id = created_by_id
        AND ai_agent_id IN (SELECT id FROM users WHERE system_role IS NOT NULL)
    SQL

    # A pending (URL-less) bridge rule whose recipient also has a registered
    # webhook would collide in the re-keyed unique index. The hourly
    # CleanupAbandonedBridgeSetupsJob removes such leftovers once their
    # setup expires; soft-delete them now so the index builds.
    execute <<~SQL
      UPDATE automation_rules p
      SET deleted_at = NOW(), enabled = FALSE
      WHERE p.rule_type = 'notification_webhook'
        AND (p.actions->>'webhook_url') IS NULL
        AND p.deleted_at IS NULL
        AND EXISTS (
          SELECT 1 FROM automation_rules r
          WHERE r.tenant_id = p.tenant_id
            AND COALESCE(r.ai_agent_id, r.user_id) = COALESCE(p.ai_agent_id, p.user_id)
            AND r.id <> p.id
            AND (r.actions->>'webhook_url') IS NOT NULL
            AND r.deleted_at IS NULL
        )
    SQL

    remove_index :automation_rules, name: :uniq_notification_webhook_per_user
    execute <<~SQL
      CREATE UNIQUE INDEX uniq_notification_webhook_per_user
      ON automation_rules (tenant_id, COALESCE(ai_agent_id, user_id))
      WHERE rule_type = 'notification_webhook' AND deleted_at IS NULL
    SQL
  end

  def down
    remove_index :automation_rules, name: :uniq_notification_webhook_per_user
    execute <<~SQL
      CREATE UNIQUE INDEX uniq_notification_webhook_per_user
      ON automation_rules (tenant_id, COALESCE(ai_agent_id, user_id))
      WHERE (actions->>'webhook_url') IS NOT NULL AND deleted_at IS NULL
    SQL
    change_table :automation_rules, bulk: true do |t|
      t.remove :rule_type
      t.remove :system_managed
    end
  end
end
