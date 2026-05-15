# Adopts each tenant's legacy per-tenant Trio user as the trio_user for its
# main collective, sets the trio feature flag ON for that main collective,
# and seeds default automation rules. Non-destructive: the legacy User row,
# its TenantUser (handle "trio"), its CollectiveMember in the main
# collective, and any /trio ChatSessions remain intact — only the
# trio_user_id link is added and rules are inserted.
#
# This is the bridge between the old per-tenant Trio model and the new
# per-collective opt-in model: existing tenants get grandfathered in with
# Trio active in their main collective; other collectives must still opt
# in via the flag.
#
# Idempotent: skips tenants whose main collective already has trio_user_id
# set, and skips automation rules whose (ai_agent_id, event_type) already
# exists.
class AdoptLegacyTrioForMainCollectives < ActiveRecord::Migration[7.2]
  def up
    Tenant.find_each do |tenant|
      next unless tenant.main_collective_id

      main = tenant.main_collective
      next if main.trio_user_id

      legacy_trio = User.where(system_role: "trio")
        .joins(:tenant_users)
        .where(tenant_users: { tenant_id: tenant.id })
        .first
      next unless legacy_trio

      main.set_feature_flag!("trio", true)
      main.update!(trio_user_id: legacy_trio.id)

      TrioActivator.seed_default_automations!(legacy_trio, tenant.id)
    end
  end

  def down
    raise ActiveRecord::IrreversibleMigration,
          "Adopted trios cannot be unlinked automatically — would require " \
          "deciding whether to also destroy seeded automation rules. " \
          "Revert by setting trio_user_id = NULL on affected collectives " \
          "and deleting the seeded AutomationRule rows manually."
  end
end
