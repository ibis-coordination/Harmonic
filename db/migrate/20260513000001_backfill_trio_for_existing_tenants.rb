# Seeds the Trio system ai_agent into every existing tenant via TrioSeeder.
#
# Idempotent: TrioSeeder.ensure_for finds existing trio users by
# (tenant_id, system_role: "trio") and only creates when missing. Re-running
# this migration is safe.
class BackfillTrioForExistingTenants < ActiveRecord::Migration[7.2]
  def up
    Tenant.find_each do |tenant|
      next unless tenant.main_collective_id

      TrioSeeder.ensure_for(tenant)
    end
  end

  def down
    # Removing trio users requires cascading through ChatSession, ChatMessage,
    # AiAgentTaskRun, etc., which the test environment doesn't have set up
    # cleanly. Trio is harmless to leave in place; the system_role column
    # migration's down step is the real reversibility anchor.
    raise ActiveRecord::IrreversibleMigration,
          "Backfilled Trio users are not removed by reversing this migration. " \
          "Revert by deleting users with system_role = 'trio' manually if needed."
  end
end
