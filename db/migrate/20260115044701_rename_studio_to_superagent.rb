# Renames Studio model to Superagent throughout the database.
# This is a backend-only change - users still see "studios" in the UI.
#
# Tables renamed:
#   - studios → superagents
#   - studio_users → superagent_members
#   - studio_invites → invites
#
# Columns renamed:
#   - studio_type → superagent_type
#   - studio_id → superagent_id (in all tables)
#   - main_studio_id → main_superagent_id (in tenants)
#   - resource_studio_id → resource_superagent_id (in links, representation_session_associations)
#
class RenameStudioToSuperagent < ActiveRecord::Migration[7.0]
  def up
    # 1. Drop views that depend on studio_id columns
    execute <<-SQL
      DROP VIEW IF EXISTS cycle_data;
      DROP VIEW IF EXISTS cycle_data_notes;
      DROP VIEW IF EXISTS cycle_data_decisions;
      DROP VIEW IF EXISTS cycle_data_commitments;
    SQL

    # 2. Rename main tables
    rename_table :studios, :superagents
    rename_table :studio_users, :superagent_members
    rename_table :studio_invites, :invites

    # 2b. Rename indices that would be too long after column rename (63 char limit)
    # PostgreSQL auto-renames indexes when table is renamed, so we look for the new names
    # index_superagent_members_on_tenant_id_and_studio_id_and_user_id -> idx_members_tenant_superagent_user
    if index_name_exists?(:superagent_members, 'index_superagent_members_on_tenant_id_and_studio_id_and_user_id')
      rename_index :superagent_members, 'index_superagent_members_on_tenant_id_and_studio_id_and_user_id', 'idx_members_tenant_superagent_user'
    end
    if index_name_exists?(:superagent_members, 'index_superagent_members_on_studio_id')
      rename_index :superagent_members, 'index_superagent_members_on_studio_id', 'idx_members_superagent_id'
    end

    # 3. Rename studio_type column to superagent_type
    rename_column :superagents, :studio_type, :superagent_type

    # 4. Rename main_studio_id in tenants
    rename_column :tenants, :main_studio_id, :main_superagent_id

    # 5. Rename studio_id to superagent_id in all tables
    tables_with_studio_id = %i[
      attachments
      commitment_participants
      commitments
      cycle_data_rows
      decision_participants
      decisions
      events
      heartbeats
      invites
      links
      note_history_events
      notes
      options
      representation_session_associations
      representation_sessions
      superagent_members
      votes
      webhooks
    ]

    tables_with_studio_id.each do |table|
      next unless table_exists?(table)
      rename_column table, :studio_id, :superagent_id
    end

    # 6. Rename resource_studio_id columns (only in representation_session_associations)
    rename_column :representation_session_associations, :resource_studio_id, :resource_superagent_id

    # 7. Recreate views with superagent_id
    execute <<-SQL
      CREATE VIEW cycle_data_notes AS
        SELECT
          n.tenant_id,
          n.superagent_id,
          'Note' AS item_type,
          n.id AS item_id,
          n.title,
          n.created_at,
          n.updated_at,
          n.created_by_id,
          n.updated_by_id,
          n.deadline,
          COUNT(DISTINCT nl.id)::int AS link_count,
          COUNT(DISTINCT nbl.id)::int AS backlink_count,
          COUNT(DISTINCT nhe.user_id)::int AS participant_count,
          NULL::int AS voter_count,
          NULL::int AS option_count
        FROM notes n
        LEFT JOIN note_history_events nhe ON n.id = nhe.note_id AND nhe.event_type = 'confirmed_read'
        LEFT JOIN links nl ON n.id = nl.from_linkable_id AND nl.from_linkable_type = 'Note'
        LEFT JOIN links nbl ON n.id = nbl.to_linkable_id AND nbl.to_linkable_type = 'Note'
        GROUP BY n.tenant_id, n.superagent_id, n.id
        ORDER BY n.tenant_id, n.superagent_id, n.created_at DESC
    SQL

    execute <<-SQL
      CREATE VIEW cycle_data_decisions AS
        SELECT
          d.tenant_id,
          d.superagent_id,
          'Decision' AS item_type,
          d.id AS item_id,
          d.question AS title,
          d.created_at,
          d.updated_at,
          d.created_by_id,
          d.updated_by_id,
          d.deadline,
          COUNT(DISTINCT dl.id)::int AS link_count,
          COUNT(DISTINCT dbl.id)::int AS backlink_count,
          COUNT(DISTINCT a.decision_participant_id)::int AS participant_count,
          COUNT(DISTINCT a.decision_participant_id)::int AS voter_count,
          COUNT(DISTINCT o.id)::int AS option_count
        FROM decisions d
        LEFT JOIN votes a ON d.id = a.decision_id
        LEFT JOIN options o ON d.id = o.decision_id
        LEFT JOIN links dl ON d.id = dl.from_linkable_id AND dl.from_linkable_type = 'Decision'
        LEFT JOIN links dbl ON d.id = dbl.to_linkable_id AND dbl.to_linkable_type = 'Decision'
        GROUP BY d.tenant_id, d.superagent_id, d.id
        ORDER BY d.tenant_id, d.superagent_id, d.created_at DESC
    SQL

    execute <<-SQL
      CREATE VIEW cycle_data_commitments AS
        SELECT
          c.tenant_id,
          c.superagent_id,
          'Commitment' AS item_type,
          c.id AS item_id,
          c.title,
          c.created_at,
          c.updated_at,
          c.created_by_id,
          c.updated_by_id,
          c.deadline,
          COUNT(DISTINCT cl.id)::int AS link_count,
          COUNT(DISTINCT cbl.id)::int AS backlink_count,
          COUNT(DISTINCT p.user_id)::int AS participant_count,
          NULL::int AS voter_count,
          NULL::int AS option_count
        FROM commitments c
        LEFT JOIN commitment_participants p ON c.id = p.commitment_id
        LEFT JOIN links cl ON c.id = cl.from_linkable_id AND cl.from_linkable_type = 'Commitment'
        LEFT JOIN links cbl ON c.id = cbl.to_linkable_id AND cbl.to_linkable_type = 'Commitment'
        GROUP BY c.tenant_id, c.superagent_id, c.id
        ORDER BY c.tenant_id, c.superagent_id, c.created_at DESC
    SQL

    execute <<-SQL
      CREATE VIEW cycle_data AS
        SELECT *
        FROM cycle_data_notes n
        UNION ALL
        SELECT *
        FROM cycle_data_decisions
        UNION ALL
        SELECT *
        FROM cycle_data_commitments
        ORDER BY tenant_id, superagent_id, created_at DESC
    SQL
  end

  def down
    # 1. Drop views
    execute <<-SQL
      DROP VIEW IF EXISTS cycle_data;
      DROP VIEW IF EXISTS cycle_data_notes;
      DROP VIEW IF EXISTS cycle_data_decisions;
      DROP VIEW IF EXISTS cycle_data_commitments;
    SQL

    # 2. Rename columns back (superagent_id -> studio_id)
    tables_with_superagent_id = %i[
      attachments
      commitment_participants
      commitments
      cycle_data_rows
      decision_participants
      decisions
      events
      heartbeats
      invites
      links
      note_history_events
      notes
      options
      representation_session_associations
      representation_sessions
      superagent_members
      votes
      webhooks
    ]

    tables_with_superagent_id.each do |table|
      next unless table_exists?(table)
      rename_column table, :superagent_id, :studio_id
    end

    # 3. Rename resource_superagent_id back (only in representation_session_associations)
    rename_column :representation_session_associations, :resource_superagent_id, :resource_studio_id

    # 4. Rename superagent_type back to studio_type
    rename_column :superagents, :superagent_type, :studio_type

    # 5. Rename main_superagent_id back
    rename_column :tenants, :main_superagent_id, :main_studio_id

    # 6. Rename tables back
    rename_table :superagents, :studios
    rename_table :superagent_members, :studio_users
    rename_table :invites, :studio_invites

    # 6b. Rename indices back to original names
    if index_name_exists?(:studio_users, 'idx_members_tenant_superagent_user')
      rename_index :studio_users, 'idx_members_tenant_superagent_user', 'index_studio_users_on_tenant_id_and_studio_id_and_user_id'
    end
    if index_name_exists?(:studio_users, 'idx_members_superagent_id')
      rename_index :studio_users, 'idx_members_superagent_id', 'index_studio_users_on_studio_id'
    end

    # 7. Recreate views with studio_id
    execute <<-SQL
      CREATE VIEW cycle_data_notes AS
        SELECT
          n.tenant_id,
          n.studio_id,
          'Note' AS item_type,
          n.id AS item_id,
          n.title,
          n.created_at,
          n.updated_at,
          n.created_by_id,
          n.updated_by_id,
          n.deadline,
          COUNT(DISTINCT nl.id)::int AS link_count,
          COUNT(DISTINCT nbl.id)::int AS backlink_count,
          COUNT(DISTINCT nhe.user_id)::int AS participant_count,
          NULL::int AS voter_count,
          NULL::int AS option_count
        FROM notes n
        LEFT JOIN note_history_events nhe ON n.id = nhe.note_id AND nhe.event_type = 'confirmed_read'
        LEFT JOIN links nl ON n.id = nl.from_linkable_id AND nl.from_linkable_type = 'Note'
        LEFT JOIN links nbl ON n.id = nbl.to_linkable_id AND nbl.to_linkable_type = 'Note'
        GROUP BY n.tenant_id, n.studio_id, n.id
        ORDER BY n.tenant_id, n.studio_id, n.created_at DESC
    SQL

    execute <<-SQL
      CREATE VIEW cycle_data_decisions AS
        SELECT
          d.tenant_id,
          d.studio_id,
          'Decision' AS item_type,
          d.id AS item_id,
          d.question AS title,
          d.created_at,
          d.updated_at,
          d.created_by_id,
          d.updated_by_id,
          d.deadline,
          COUNT(DISTINCT dl.id)::int AS link_count,
          COUNT(DISTINCT dbl.id)::int AS backlink_count,
          COUNT(DISTINCT a.decision_participant_id)::int AS participant_count,
          COUNT(DISTINCT a.decision_participant_id)::int AS voter_count,
          COUNT(DISTINCT o.id)::int AS option_count
        FROM decisions d
        LEFT JOIN votes a ON d.id = a.decision_id
        LEFT JOIN options o ON d.id = o.decision_id
        LEFT JOIN links dl ON d.id = dl.from_linkable_id AND dl.from_linkable_type = 'Decision'
        LEFT JOIN links dbl ON d.id = dbl.to_linkable_id AND dbl.to_linkable_type = 'Decision'
        GROUP BY d.tenant_id, d.studio_id, d.id
        ORDER BY d.tenant_id, d.studio_id, d.created_at DESC
    SQL

    execute <<-SQL
      CREATE VIEW cycle_data_commitments AS
        SELECT
          c.tenant_id,
          c.studio_id,
          'Commitment' AS item_type,
          c.id AS item_id,
          c.title,
          c.created_at,
          c.updated_at,
          c.created_by_id,
          c.updated_by_id,
          c.deadline,
          COUNT(DISTINCT cl.id)::int AS link_count,
          COUNT(DISTINCT cbl.id)::int AS backlink_count,
          COUNT(DISTINCT p.user_id)::int AS participant_count,
          NULL::int AS voter_count,
          NULL::int AS option_count
        FROM commitments c
        LEFT JOIN commitment_participants p ON c.id = p.commitment_id
        LEFT JOIN links cl ON c.id = cl.from_linkable_id AND cl.from_linkable_type = 'Commitment'
        LEFT JOIN links cbl ON c.id = cbl.to_linkable_id AND cbl.to_linkable_type = 'Commitment'
        GROUP BY c.tenant_id, c.studio_id, c.id
        ORDER BY c.tenant_id, c.studio_id, c.created_at DESC
    SQL

    execute <<-SQL
      CREATE VIEW cycle_data AS
        SELECT *
        FROM cycle_data_notes n
        UNION ALL
        SELECT *
        FROM cycle_data_decisions
        UNION ALL
        SELECT *
        FROM cycle_data_commitments
        ORDER BY tenant_id, studio_id, created_at DESC
    SQL
  end
end
