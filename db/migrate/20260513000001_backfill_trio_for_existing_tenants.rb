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

  def up
    Tenant.find_each do |tenant|
      main = tenant.main_collective
      next unless main
      next if existing_trio?(tenant)

      with_tenant_scope(tenant) do
        ActiveRecord::Base.transaction do
          trio = User.create!(
            name: NAME,
            email: "trio-#{tenant.subdomain}-#{SecureRandom.hex(4)}@system.harmonic.local",
            user_type: "ai_agent",
            system_role: "trio",
            parent_id: nil,
            agent_configuration: { "mode" => "internal" }
          )
          tenant.add_user!(trio, handle: pick_handle(tenant))
          main.add_user!(trio)
        end
      end
    end
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
