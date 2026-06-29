# typed: false

# Goal 2 of handle-model-unification: a collective and its identity user now
# share one handle. Existing identity users were minted with a random hex handle
# (`SecureRandom.hex(16)`), so backfill each to its collective's handle.
#
# Where a collective's handle is already held by another user in the same tenant
# (legacy data from before the namespaces were unified), the identity user takes
# a numeric `-XX` suffix instead — the resolution policy chosen for this case.
# Raw SQL throughout so the backfill is independent of model code/validations and
# is unaffected by tenant scoping (Tenant.current_id is nil inside migrations).
class BackfillCollectiveIdentityHandles < ActiveRecord::Migration[7.2]
  def up
    rows = exec_query(<<~SQL).to_a
      SELECT c.tenant_id      AS tenant_id,
             c.handle::text   AS collective_handle,
             tu.id            AS tenant_user_id,
             tu.handle::text  AS current_handle
      FROM collectives c
      JOIN tenant_users tu
        ON tu.user_id = c.identity_user_id
       AND tu.tenant_id = c.tenant_id
      WHERE c.identity_user_id IS NOT NULL
        AND c.handle IS NOT NULL
    SQL

    rows.each do |row|
      tenant_id = row["tenant_id"]
      desired   = row["collective_handle"].to_s
      next if desired.blank?
      # handle is citext, so compare case-insensitively: already unified -> skip.
      next if row["current_handle"].to_s.casecmp?(desired)

      candidate = desired
      candidate = "#{desired}-#{SecureRandom.hex(2)}" until handle_free?(tenant_id, candidate, row["tenant_user_id"])

      execute(<<~SQL)
        UPDATE tenant_users
        SET handle = #{quote(candidate)}, updated_at = now()
        WHERE id = #{quote(row["tenant_user_id"])}
      SQL
    end
  end

  def down
    # Irreversible in practice: the original random hex handles are not recorded.
    # The unified handles remain valid, so rolling back is a no-op rather than an
    # error that would block `db:rollback` in development.
  end

  private

  def handle_free?(tenant_id, candidate, exclude_id)
    exec_query(<<~SQL).rows.empty?
      SELECT 1 FROM tenant_users
      WHERE tenant_id = #{quote(tenant_id)}
        AND handle = #{quote(candidate)}
        AND id <> #{quote(exclude_id)}
      LIMIT 1
    SQL
  end
end
