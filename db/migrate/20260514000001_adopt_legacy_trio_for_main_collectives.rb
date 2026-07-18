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
  # Frozen after the trio→cadence persona rename: the TrioActivator this
  # adoption delegated to no longer exists. No-ops on a clean chain (no
  # legacy trio users exist at this point); fails fast on a restored
  # pre-2026-05 backup.
  def up
    legacy_exists = User.where(system_role: "trio").exists?
    return unless legacy_exists

    raise "AdoptLegacyTrioForMainCollectives cannot replay after the trio→cadence rename. "           "Finish the migration chain (the rename migration converts legacy trio users), "           "then reconcile personas via PersonaActivator.reconcile!."
  end

  def down
    raise ActiveRecord::IrreversibleMigration,
          "Adopted trios cannot be unlinked automatically — would require " \
          "deciding whether to also destroy seeded automation rules. " \
          "Revert by setting trio_user_id = NULL on affected collectives " \
          "and deleting the seeded AutomationRule rows manually."
  end
end
