# typed: false

# Backfills CollectiveMember rows for ai_agent users that are members of a
# tenant but missing membership in that tenant's main collective. The
# create_ai_agent flow previously only added agents to the tenant, leaving
# them invisible to collective-scoped queries (autocomplete, member lists,
# chat search) and unable to access main collective routes.
class BackfillAiAgentMainCollectiveMembership < ActiveRecord::Migration[7.2]
  def up
    execute(<<~SQL)
      INSERT INTO collective_members (tenant_id, collective_id, user_id, created_at, updated_at)
      SELECT tu.tenant_id, t.main_collective_id, tu.user_id, NOW(), NOW()
      FROM tenant_users tu
      JOIN users u ON u.id = tu.user_id
      JOIN tenants t ON t.id = tu.tenant_id
      WHERE u.user_type = 'ai_agent'
        AND t.main_collective_id IS NOT NULL
      ON CONFLICT (tenant_id, collective_id, user_id) DO NOTHING
    SQL
  end

  def down
    # Not reversible: we cannot tell which memberships were created by this
    # backfill versus by subsequent normal use.
  end
end
