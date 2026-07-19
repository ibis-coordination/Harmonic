# Workspace personas were created with no principal (parent_id NULL):
# PersonaSeeder pointed parent_id at the collective's identity user, and
# private workspaces mint no identity user. The workspace owner is the
# principal — they are the workspace's identity in every meaningful sense,
# and the one whose billing pays for the agents. New workspace personas get
# the owner as parent at creation (PersonaSeeder#principal_id); this covers
# rows that predate that.
class BackfillWorkspacePersonaPrincipals < ActiveRecord::Migration[7.2]
  def up
    execute <<~SQL.squish
      UPDATE users u
      SET parent_id = c.created_by_id
      FROM collective_members cm
      JOIN collectives c ON c.id = cm.collective_id AND c.collective_type = 'private_workspace'
      WHERE cm.user_id = u.id
        AND u.system_role IS NOT NULL
        AND u.parent_id IS NULL
        AND c.created_by_id IS NOT NULL
    SQL
  end

  def down
    execute <<~SQL.squish
      UPDATE users u
      SET parent_id = NULL
      FROM collective_members cm
      JOIN collectives c ON c.id = cm.collective_id AND c.collective_type = 'private_workspace'
      WHERE cm.user_id = u.id
        AND u.system_role IS NOT NULL
        AND u.parent_id = c.created_by_id
    SQL
  end
end
