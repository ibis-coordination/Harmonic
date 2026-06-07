# Backfills the new `automations` feature flag.
#
# Behavior: tenants that already have at least one AutomationRule on the
# automation_rules table get `automations = true`, so existing users keep
# their authoring UI. New tenants and tenants without rules default to
# `false` (the YAML default).
#
# The flag gates the AUTHORING UI — the dispatcher and executor stay
# flag-agnostic, so pre-existing rules continue to fire when the flag is off.
class EnableAutomationsFlagForExistingUsers < ActiveRecord::Migration[7.2]
  def up
    execute <<-SQL
      UPDATE tenants
      SET settings = jsonb_set(
        settings,
        '{feature_flags,automations}',
        'true'::jsonb,
        true
      )
      WHERE EXISTS (
        SELECT 1 FROM automation_rules WHERE automation_rules.tenant_id = tenants.id
      )
    SQL
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
