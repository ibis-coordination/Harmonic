# typed: false

# Issue #477: collective-identity users are now first-class *members* of their
# tenant's main collective, minted alongside the identity in
# `Collective#create_identity_user!`. Existing identities predate that hook, so
# backfill the missing main-collective `CollectiveMember` rows.
#
# Scope mirrors the creation hook exactly:
#   - only non-workspace/non-chat collectives have an identity user at all
#     (those two types return early with no identity),
#   - the main collective itself is skipped — an identity has no parent-of-the-
#     parent to join, and counting it as its own member is meaningless,
#   - tenants without a main collective yet (mid-bootstrap fixtures) are skipped.
#
# Idempotent: the NOT EXISTS guard means re-running inserts nothing, and it
# respects the (tenant_id, collective_id, user_id) unique index. Raw SQL keeps
# the backfill independent of model validations/callbacks and tenant scoping
# (Tenant.current_id is nil inside migrations); `id` and `settings` fall to their
# column defaults (gen_random_uuid / '{}'), and identities hold no roles so the
# empty settings is exactly what a fresh membership would carry.
class BackfillCollectiveIdentityMainMemberships < ActiveRecord::Migration[7.2]
  def up
    execute(<<~SQL)
      INSERT INTO collective_members (tenant_id, collective_id, user_id, created_at, updated_at)
      SELECT c.tenant_id, t.main_collective_id, c.identity_user_id, now(), now()
      FROM collectives c
      JOIN tenants t ON t.id = c.tenant_id
      WHERE c.identity_user_id IS NOT NULL
        AND c.collective_type NOT IN ('private_workspace', 'chat')
        AND t.main_collective_id IS NOT NULL
        AND c.id <> t.main_collective_id
        AND NOT EXISTS (
          SELECT 1 FROM collective_members cm
          WHERE cm.collective_id = t.main_collective_id
            AND cm.user_id = c.identity_user_id
        )
    SQL
  end

  def down
    # No-op: we can't distinguish backfilled rows from memberships an admin may
    # have since curated, and dropping identities from the main collective would
    # reintroduce the very special-casing this issue removed.
  end
end
