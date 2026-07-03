# typed: false

# Goal 2 of handle-model-unification: a collective and its identity user now
# share one handle. Existing identity users were minted with a random hex handle
# (`SecureRandom.hex(16)`), so backfill each to its collective's handle.
#
# The desired handle is derived exactly as `TenantUser.identity_handle_for`
# derives it for live collectives, so this backfill produces the same result a
# fresh `create_identity_user!` would: the collective handle is run through
# `parameterize(preserve_case: true)`, and the identity user takes a numeric
# `-XX` suffix when that handle is already held by another user in the same
# tenant (legacy data from before the namespaces were unified) OR is reserved.
# The reserved case is genuinely reachable, not just defensive: collective
# validation only forbids `Collective::RESERVED_HANDLES` (["main"]), whereas the
# identity user lives in the `tenant_users` namespace and may not hold a handle
# in `TenantUser::RESERVED_HANDLES` ({"trio"=>"trio"}). A collective named "trio"
# is therefore permitted, and without this check the backfill would let its
# identity user claim the reserved "trio" handle that the runtime path suffixes
# away (the collision check alone only catches it in tenants that already have a
# live "trio" tenant_user).
# Raw SQL is used for the reads/writes so the backfill is independent of model
# validations/callbacks and tenant scoping (Tenant.current_id is nil inside
# migrations); the only model reference is the frozen `RESERVED_HANDLES`
# constant, kept as the single source of truth so the two paths can't diverge.
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
      # Mirror TenantUser.identity_handle_for's base derivation, so a backfilled
      # handle matches what creating the collective today would mint.
      desired = row["collective_handle"].to_s.parameterize(preserve_case: true)
      next if desired.blank?
      # handle is citext, so compare case-insensitively: already unified -> skip.
      next if row["current_handle"].to_s.casecmp?(desired)

      candidate = desired
      # An identity user can't hold a reserved handle (e.g. "trio"); suffix it
      # just as identity_handle_for and a live rename would.
      candidate = "#{desired}-#{SecureRandom.hex(2)}" if TenantUser::RESERVED_HANDLES.key?(desired.downcase)
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
