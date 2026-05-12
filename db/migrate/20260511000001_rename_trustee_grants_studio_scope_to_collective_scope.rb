# typed: true

# Cleanup from the studio→collective rename that landed previously: the
# trustee_grants.studio_scope column and its `studio_ids` JSON sub-key
# were missed. This migration renames both:
#
# - Column: trustee_grants.studio_scope → trustee_grants.collective_scope
# - JSON key inside the jsonb value: "studio_ids" → "collective_ids"
#
# The default value (`{"mode": "all"}`) carries over to the renamed column.
class RenameTrusteeGrantsStudioScopeToCollectiveScope < ActiveRecord::Migration[7.2]
  def up
    rename_column :trustee_grants, :studio_scope, :collective_scope

    execute(<<~SQL)
      UPDATE trustee_grants
      SET collective_scope = jsonb_set(
        collective_scope - 'studio_ids',
        '{collective_ids}',
        collective_scope -> 'studio_ids'
      )
      WHERE collective_scope ? 'studio_ids'
    SQL
  end

  def down
    execute(<<~SQL)
      UPDATE trustee_grants
      SET collective_scope = jsonb_set(
        collective_scope - 'collective_ids',
        '{studio_ids}',
        collective_scope -> 'collective_ids'
      )
      WHERE collective_scope ? 'collective_ids'
    SQL

    rename_column :trustee_grants, :collective_scope, :studio_scope
  end
end
