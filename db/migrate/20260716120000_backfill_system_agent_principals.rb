# System agents (trio) were created with no principal (parent_id NULL); the
# collective itself is now the accountable principal, so each trio gets its
# collective's identity user as parent. The collective is found through the
# trio's CollectiveMember row rather than collectives.trio_user_id, which is
# nulled while trio is deactivated. New trios get the parent at creation
# (now PersonaSeeder); this covers rows that predate that.
class BackfillSystemAgentPrincipals < ActiveRecord::Migration[7.2]
  def up
    execute <<~SQL.squish
      UPDATE users u
      SET parent_id = c.identity_user_id
      FROM collective_members cm
      JOIN collectives c ON c.id = cm.collective_id AND c.collective_type = 'standard'
      WHERE cm.user_id = u.id
        AND u.system_role IS NOT NULL
        AND u.parent_id IS NULL
        AND c.identity_user_id IS NOT NULL
    SQL
  end

  def down
    execute <<~SQL.squish
      UPDATE users SET parent_id = NULL WHERE system_role IS NOT NULL
    SQL
  end
end
