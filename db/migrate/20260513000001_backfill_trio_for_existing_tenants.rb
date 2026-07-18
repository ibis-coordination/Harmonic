# Seeds a legacy per-tenant Trio system ai_agent into every existing tenant.
#
# The next-day migrations (20260514000000 + 20260514000001) add the
# Collective#trio_user_id column and then adopt these per-tenant trios as
# the trio_user for each tenant's main collective. This migration must NOT
# touch trio_user_id — the column does not exist yet.
#
# Inlined here rather than delegated to TrioSeeder because the seeder has
# since been rewritten for the per-collective model and now writes
# trio_user_id directly, which would fail at this point in the migration
# chain. Migrations should be self-contained against the schema as it
# exists at their version.
#
# Idempotent: skips tenants that already have a system_role: "trio" user.
class BackfillTrioForExistingTenants < ActiveRecord::Migration[7.2]
  HANDLE = "trio".freeze
  NAME = "Trio".freeze

  # Frozen after the trio→cadence persona rename: system_role "trio" no
  # longer passes User validation, so the original seeding cannot replay.
  # No-ops on a clean chain (no tenants exist at this point); fails fast on
  # a restored pre-2026-05 backup, where the operator should complete the
  # chain and then activate personas via PersonaActivator instead.
  def up
    needs_seeding = Tenant.find_each.any? { |tenant| tenant.main_collective && !existing_trio?(tenant) }
    return unless needs_seeding

    raise "BackfillTrioForExistingTenants cannot replay after the trio→cadence rename. "           "Finish the migration chain, then activate personas via PersonaActivator.reconcile! "           "for the collectives that need them."
  end

  def down
    raise ActiveRecord::IrreversibleMigration,
          "Backfilled Trio users are not removed by reversing this migration. " \
          "Revert by deleting users with system_role = 'trio' manually if needed."
  end

  private

  def with_tenant_scope(tenant)
    previous_id = Tenant.current_id
    Tenant.set_thread_context(tenant)
    yield
  ensure
    if previous_id
      Tenant.set_thread_context(Tenant.find(previous_id))
    else
      Tenant.clear_thread_scope
    end
  end

  def existing_trio?(tenant)
    User.joins(:tenant_users)
      .exists?(tenant_users: { tenant_id: tenant.id }, system_role: "trio")
  end

  def pick_handle(tenant)
    return HANDLE unless handle_taken?(tenant, HANDLE)

    loop do
      candidate = "#{HANDLE}-#{SecureRandom.hex(2)}"
      return candidate unless handle_taken?(tenant, candidate)
    end
  end

  def handle_taken?(tenant, handle)
    TenantUser.exists?(tenant_id: tenant.id, handle: handle)
  end
end
