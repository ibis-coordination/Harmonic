# The trio persona role on the CollectiveMember row is now the single source
# of truth for "who is this collective's trio" (Collective#persona_user);
# the trio_user_id column goes away. Three steps, order-dependent:
#
#   1. Backfill the persona role onto every ACTIVE trio's member row
#      (active = trio_user_id set — the column's own semantics).
#   2. Rename legacy trio handles ("trio", "trio-<hex4>") to the
#      trio-<collective handle> pattern, suffixing on collision with a
#      legacy squatter.
#   3. Drop the column.
class DropTrioUserIdFromCollectives < ActiveRecord::Migration[7.2]
  def up
    say_with_time "backfilling trio persona roles" do
      execute(<<~SQL.squish)
        UPDATE collective_members cm
        SET settings = jsonb_set(
          COALESCE(cm.settings, '{}'::jsonb),
          '{roles}',
          COALESCE(cm.settings->'roles', '[]'::jsonb) || '["trio"]'::jsonb
        )
        FROM collectives c
        WHERE c.id = cm.collective_id
          AND c.trio_user_id = cm.user_id
          AND NOT (COALESCE(cm.settings->'roles', '[]'::jsonb) ? 'trio')
      SQL
    end

    say_with_time "renaming trio handles to trio-<collective handle>" do
      renamed = 0
      trio_ids = User.unscoped_for_system_job.where(system_role: "trio").pluck(:id)
      CollectiveMember.unscoped_for_system_job.where(user_id: trio_ids).find_each do |cm|
        collective = Collective.unscoped_for_system_job.find_by(id: cm.collective_id)
        next unless collective&.standard? && collective.handle.present?

        tenant_user = TenantUser.unscoped_for_system_job.find_by(tenant_id: collective.tenant_id, user_id: cm.user_id)
        next unless tenant_user

        desired = "trio-#{collective.handle}"
        next if tenant_user.handle.to_s.casecmp?(desired)

        taken = TenantUser.unscoped_for_system_job
          .where(tenant_id: collective.tenant_id, handle: desired)
          .where.not(user_id: cm.user_id)
        desired = "#{desired}-#{SecureRandom.hex(2)}" if taken.exists?
        # update_columns: no validations/callbacks — legacy rows must rename
        # unconditionally, and nothing else may fire mid-migration.
        tenant_user.update_columns(handle: desired)
        renamed += 1
      end
      renamed
    end

    remove_column :collectives, :trio_user_id
  end

  def down
    add_column :collectives, :trio_user_id, :uuid

    # Recompute the link from the persona role (the source of truth going
    # forward, so nothing is lost). Handle renames are not reverted.
    execute(<<~SQL.squish)
      UPDATE collectives c
      SET trio_user_id = cm.user_id
      FROM collective_members cm
      WHERE cm.collective_id = c.id
        AND cm.archived_at IS NULL
        AND COALESCE(cm.settings->'roles', '[]'::jsonb) ? 'trio'
    SQL
  end
end
