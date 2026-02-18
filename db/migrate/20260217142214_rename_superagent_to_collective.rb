# frozen_string_literal: true

# Rename all "superagent" references to "collective" throughout the database.
#
# Tables renamed:
#   - superagents → collectives
#   - superagent_members → collective_members
#
# Columns renamed:
#   - superagent_id → collective_id (18 tables)
#   - resource_superagent_id → resource_collective_id (3 tables)
#   - superagent_type → collective_type (collectives table)
#   - main_superagent_id → main_collective_id (tenants table)
#
# Polymorphic type updates:
#   - active_storage_attachments.record_type: 'Superagent' → 'Collective'
#
# Enum value updates:
#   - users.user_type: 'superagent_proxy' → 'collective_proxy'
#
# Views recreated:
#   - cycle_data_notes, cycle_data_decisions, cycle_data_commitments, cycle_data
#
# Indexes renamed: ~122 total (25 regular + 96 partition + 1 parent)
#
# SAFETY NOTES:
# - Rails' rename_table auto-renames indexes matching index_<table>_on_<column> pattern
# - All operations use existence checks to be idempotent
# - Migration can be re-run safely if interrupted
#
class RenameSuperagentToCollective < ActiveRecord::Migration[7.0]
  # Must use up/down instead of change because raw SQL (execute) is not auto-reversible

  def up
    # 1. Drop views first (they depend on columns we're renaming)
    drop_cycle_views

    # 2. Rename main tables (Rails auto-renames matching indexes)
    safe_rename_table(:superagents, :collectives)
    safe_rename_table(:superagent_members, :collective_members)

    # 3. Rename superagent_id columns in core tables
    tables_with_superagent_id.each do |table|
      safe_rename_column(table, :superagent_id, :collective_id)
    end

    # 4. Rename resource_superagent_id columns
    safe_rename_column(:ai_agent_task_run_resources, :resource_superagent_id, :resource_collective_id)
    safe_rename_column(:automation_rule_run_resources, :resource_superagent_id, :resource_collective_id)
    safe_rename_column(:representation_session_events, :resource_superagent_id, :resource_collective_id)

    # 5. Rename in join table (use new table name after rename)
    safe_rename_column(:collective_members, :superagent_id, :collective_id)

    # 6. Rename special columns
    safe_rename_column(:tenants, :main_superagent_id, :main_collective_id)

    # 7. Handle partitioned search_index table
    safe_rename_column_raw(:search_index, :superagent_id, :collective_id)

    # 8. Update polymorphic type references
    execute "UPDATE active_storage_attachments SET record_type = 'Collective' WHERE record_type = 'Superagent';"

    # 9. Rename superagent_type column (use new table name after rename)
    safe_rename_column(:collectives, :superagent_type, :collective_type)

    # 10. Update user_type enum value
    execute "UPDATE users SET user_type = 'collective_proxy' WHERE user_type = 'superagent_proxy';"

    # 11. Recreate views with collective_id
    create_cycle_views(:collective_id)

    # 12. Rename indexes that don't follow Rails naming convention
    rename_custom_indexes_to_collective
  end

  def down
    # 1. Drop views first
    drop_cycle_views

    # 2. Rename indexes back first (before table renames)
    rename_custom_indexes_to_superagent

    # 3. Revert user_type enum value
    execute "UPDATE users SET user_type = 'superagent_proxy' WHERE user_type = 'collective_proxy';"

    # 4. Rename collective_type column back (use current table name)
    safe_rename_column(:collectives, :collective_type, :superagent_type)

    # 5. Revert polymorphic type references
    execute "UPDATE active_storage_attachments SET record_type = 'Superagent' WHERE record_type = 'Collective';"

    # 6. Revert partitioned search_index column
    safe_rename_column_raw(:search_index, :collective_id, :superagent_id)

    # 7. Revert special columns
    safe_rename_column(:tenants, :main_collective_id, :main_superagent_id)

    # 8. Revert join table column (use current table name before rename)
    safe_rename_column(:collective_members, :collective_id, :superagent_id)

    # 9. Revert resource_collective_id columns
    safe_rename_column(:representation_session_events, :resource_collective_id, :resource_superagent_id)
    safe_rename_column(:automation_rule_run_resources, :resource_collective_id, :resource_superagent_id)
    safe_rename_column(:ai_agent_task_run_resources, :resource_collective_id, :resource_superagent_id)

    # 10. Revert collective_id columns in core tables (reverse order)
    tables_with_superagent_id.reverse.each do |table|
      safe_rename_column(table, :collective_id, :superagent_id)
    end

    # 11. Rename tables back (Rails auto-renames matching indexes)
    safe_rename_table(:collective_members, :superagent_members)
    safe_rename_table(:collectives, :superagents)

    # 12. Recreate views with superagent_id
    create_cycle_views(:superagent_id)
  end

  private

  # Tables that have a superagent_id column (excluding collective_members which is handled separately)
  def tables_with_superagent_id
    %i[
      notes decisions commitments links options votes
      attachments events invites heartbeats
      decision_participants commitment_participants note_history_events
      automation_rules automation_rule_runs
      representation_sessions representation_session_events
    ]
  end

  # Safely rename a table only if source exists and target doesn't
  def safe_rename_table(old_name, new_name)
    if table_exists?(old_name) && !table_exists?(new_name)
      rename_table(old_name, new_name)
    elsif table_exists?(new_name)
      say "Table #{new_name} already exists, skipping rename from #{old_name}"
    else
      raise "Neither #{old_name} nor #{new_name} exists!"
    end
  end

  # Safely rename a column only if source exists and target doesn't
  def safe_rename_column(table, old_name, new_name)
    return unless table_exists?(table)

    if column_exists?(table, old_name) && !column_exists?(table, new_name)
      rename_column(table, old_name, new_name)
    elsif column_exists?(table, new_name)
      say "Column #{table}.#{new_name} already exists, skipping rename from #{old_name}"
    else
      raise "Neither #{table}.#{old_name} nor #{table}.#{new_name} exists!"
    end
  end

  # For partitioned tables, use raw SQL (column rename propagates to partitions)
  def safe_rename_column_raw(table, old_name, new_name)
    return unless table_exists?(table)

    if column_exists?(table, old_name) && !column_exists?(table, new_name)
      execute "ALTER TABLE #{table} RENAME COLUMN #{old_name} TO #{new_name};"
    elsif column_exists?(table, new_name)
      say "Column #{table}.#{new_name} already exists, skipping rename from #{old_name}"
    else
      raise "Neither #{table}.#{old_name} nor #{table}.#{new_name} exists!"
    end
  end

  # Safely rename an index only if source exists
  def safe_rename_index(old_name, new_name)
    if index_name_exists?(old_name)
      execute "ALTER INDEX #{quote_column_name(old_name)} RENAME TO #{quote_column_name(new_name)};"
    elsif index_name_exists?(new_name)
      say "Index #{new_name} already exists, skipping rename from #{old_name}"
    else
      say "Warning: Neither index #{old_name} nor #{new_name} exists, skipping"
    end
  end

  # Check if an index exists by name (schema-wide)
  def index_name_exists?(name)
    result = execute("SELECT 1 FROM pg_indexes WHERE schemaname = 'public' AND indexname = '#{name}' LIMIT 1")
    result.count > 0
  end

  def drop_cycle_views
    execute "DROP VIEW IF EXISTS cycle_data CASCADE;"
    execute "DROP VIEW IF EXISTS cycle_data_notes CASCADE;"
    execute "DROP VIEW IF EXISTS cycle_data_decisions CASCADE;"
    execute "DROP VIEW IF EXISTS cycle_data_commitments CASCADE;"
  end

  def create_cycle_views(col)
    execute <<-SQL
      CREATE VIEW cycle_data_notes AS
        SELECT n.tenant_id, n.#{col}, 'Note' AS item_type, n.id AS item_id,
               n.title, n.created_at, n.updated_at, n.created_by_id, n.updated_by_id, n.deadline,
               COUNT(DISTINCT nl.id)::int AS link_count,
               COUNT(DISTINCT nbl.id)::int AS backlink_count,
               COUNT(DISTINCT nhe.user_id)::int AS participant_count,
               NULL::int AS voter_count, NULL::int AS option_count
        FROM notes n
        LEFT JOIN note_history_events nhe ON n.id = nhe.note_id AND nhe.event_type = 'confirmed_read'
        LEFT JOIN links nl ON n.id = nl.from_linkable_id AND nl.from_linkable_type = 'Note'
        LEFT JOIN links nbl ON n.id = nbl.to_linkable_id AND nbl.to_linkable_type = 'Note'
        GROUP BY n.tenant_id, n.#{col}, n.id;

      CREATE VIEW cycle_data_decisions AS
        SELECT d.tenant_id, d.#{col}, 'Decision' AS item_type, d.id AS item_id,
               d.question AS title, d.created_at, d.updated_at, d.created_by_id, d.updated_by_id, d.deadline,
               COUNT(DISTINCT dl.id)::int AS link_count,
               COUNT(DISTINCT dbl.id)::int AS backlink_count,
               COUNT(DISTINCT v.decision_participant_id)::int AS participant_count,
               COUNT(DISTINCT v.decision_participant_id)::int AS voter_count,
               COUNT(DISTINCT o.id)::int AS option_count
        FROM decisions d
        LEFT JOIN votes v ON d.id = v.decision_id
        LEFT JOIN options o ON d.id = o.decision_id
        LEFT JOIN links dl ON d.id = dl.from_linkable_id AND dl.from_linkable_type = 'Decision'
        LEFT JOIN links dbl ON d.id = dbl.to_linkable_id AND dbl.to_linkable_type = 'Decision'
        GROUP BY d.tenant_id, d.#{col}, d.id;

      CREATE VIEW cycle_data_commitments AS
        SELECT c.tenant_id, c.#{col}, 'Commitment' AS item_type, c.id AS item_id,
               c.title, c.created_at, c.updated_at, c.created_by_id, c.updated_by_id, c.deadline,
               COUNT(DISTINCT cl.id)::int AS link_count,
               COUNT(DISTINCT cbl.id)::int AS backlink_count,
               COUNT(DISTINCT p.user_id)::int AS participant_count,
               NULL::int AS voter_count, NULL::int AS option_count
        FROM commitments c
        LEFT JOIN commitment_participants p ON c.id = p.commitment_id
        LEFT JOIN links cl ON c.id = cl.from_linkable_id AND cl.from_linkable_type = 'Commitment'
        LEFT JOIN links cbl ON c.id = cbl.to_linkable_id AND cbl.to_linkable_type = 'Commitment'
        GROUP BY c.tenant_id, c.#{col}, c.id;

      CREATE VIEW cycle_data AS
        SELECT * FROM cycle_data_notes
        UNION ALL SELECT * FROM cycle_data_decisions
        UNION ALL SELECT * FROM cycle_data_commitments;
    SQL
  end

  def rename_custom_indexes_to_collective
    # NOTE: Rails' rename_table auto-renames indexes matching index_<table>_on_<column> pattern.
    # We only manually rename indexes with non-standard names.

    # Non-standard indexes on renamed tables
    safe_rename_index("idx_members_superagent_id", "idx_members_collective_id")
    safe_rename_index("idx_members_tenant_superagent_user", "idx_members_tenant_collective_user")

    # Indexes on other tables (not renamed, so no auto-rename)
    safe_rename_index("index_tenants_on_main_superagent_id", "index_tenants_on_main_collective_id")
    safe_rename_index("index_attachments_on_superagent_id", "index_attachments_on_collective_id")
    safe_rename_index("index_automation_rules_on_superagent_id", "index_automation_rules_on_collective_id")
    safe_rename_index("index_automation_rules_on_tenant_superagent_enabled", "index_automation_rules_on_tenant_collective_enabled")
    safe_rename_index("index_automation_rule_runs_on_superagent_id", "index_automation_rule_runs_on_collective_id")
    safe_rename_index("index_automation_rule_runs_on_superagent_and_created", "index_automation_rule_runs_on_collective_and_created")
    safe_rename_index("index_automation_rule_run_resources_on_resource_superagent_id", "index_automation_rule_run_resources_on_resource_collective_id")
    safe_rename_index("idx_task_run_resources_on_resource_superagent", "idx_task_run_resources_on_resource_collective")
    safe_rename_index("index_commitment_participants_on_superagent_id", "index_commitment_participants_on_collective_id")
    safe_rename_index("index_commitments_on_superagent_id", "index_commitments_on_collective_id")
    safe_rename_index("index_decision_participants_on_superagent_id", "index_decision_participants_on_collective_id")
    safe_rename_index("index_decisions_on_superagent_id", "index_decisions_on_collective_id")
    safe_rename_index("index_events_on_superagent_id", "index_events_on_collective_id")
    safe_rename_index("index_heartbeats_on_superagent_id", "index_heartbeats_on_collective_id")
    safe_rename_index("index_invites_on_superagent_id", "index_invites_on_collective_id")
    safe_rename_index("index_links_on_superagent_id", "index_links_on_collective_id")
    safe_rename_index("index_note_history_events_on_superagent_id", "index_note_history_events_on_collective_id")
    safe_rename_index("index_notes_on_superagent_id", "index_notes_on_collective_id")
    safe_rename_index("index_options_on_superagent_id", "index_options_on_collective_id")
    safe_rename_index("index_representation_sessions_on_superagent_id", "index_representation_sessions_on_collective_id")
    safe_rename_index("index_representation_session_events_on_superagent_id", "index_representation_session_events_on_collective_id")
    safe_rename_index("idx_rep_events_resource_superagent", "idx_rep_events_resource_collective")
    safe_rename_index("index_votes_on_superagent_id", "index_votes_on_collective_id")

    # search_index partition indexes (96 indexes across 16 partitions)
    (0..15).each do |p|
      safe_rename_index("search_index_p#{p}_tenant_id_superagent_id_idx", "search_index_p#{p}_tenant_id_collective_id_idx")
      safe_rename_index("search_index_p#{p}_tenant_id_superagent_id_created_at_idx", "search_index_p#{p}_tenant_id_collective_id_created_at_idx")
      safe_rename_index("search_index_p#{p}_tenant_id_superagent_id_deadline_idx", "search_index_p#{p}_tenant_id_collective_id_deadline_idx")
      safe_rename_index("search_index_p#{p}_tenant_id_superagent_id_item_type_idx", "search_index_p#{p}_tenant_id_collective_id_item_type_idx")
      safe_rename_index("search_index_p#{p}_tenant_id_superagent_id_sort_key_idx", "search_index_p#{p}_tenant_id_collective_id_sort_key_idx")
      safe_rename_index("search_index_p#{p}_tenant_id_superagent_id_subtype_idx", "search_index_p#{p}_tenant_id_collective_id_subtype_idx")
    end

    # Parent search_index index
    safe_rename_index("idx_search_index_tenant_superagent", "idx_search_index_tenant_collective")
  end

  def rename_custom_indexes_to_superagent
    # Parent search_index index
    safe_rename_index("idx_search_index_tenant_collective", "idx_search_index_tenant_superagent")

    # search_index partition indexes (reverse)
    (0..15).each do |p|
      safe_rename_index("search_index_p#{p}_tenant_id_collective_id_idx", "search_index_p#{p}_tenant_id_superagent_id_idx")
      safe_rename_index("search_index_p#{p}_tenant_id_collective_id_created_at_idx", "search_index_p#{p}_tenant_id_superagent_id_created_at_idx")
      safe_rename_index("search_index_p#{p}_tenant_id_collective_id_deadline_idx", "search_index_p#{p}_tenant_id_superagent_id_deadline_idx")
      safe_rename_index("search_index_p#{p}_tenant_id_collective_id_item_type_idx", "search_index_p#{p}_tenant_id_superagent_id_item_type_idx")
      safe_rename_index("search_index_p#{p}_tenant_id_collective_id_sort_key_idx", "search_index_p#{p}_tenant_id_superagent_id_sort_key_idx")
      safe_rename_index("search_index_p#{p}_tenant_id_collective_id_subtype_idx", "search_index_p#{p}_tenant_id_superagent_id_subtype_idx")
    end

    # Indexes on other tables
    safe_rename_index("index_votes_on_collective_id", "index_votes_on_superagent_id")
    safe_rename_index("idx_rep_events_resource_collective", "idx_rep_events_resource_superagent")
    safe_rename_index("index_representation_session_events_on_collective_id", "index_representation_session_events_on_superagent_id")
    safe_rename_index("index_representation_sessions_on_collective_id", "index_representation_sessions_on_superagent_id")
    safe_rename_index("index_options_on_collective_id", "index_options_on_superagent_id")
    safe_rename_index("index_notes_on_collective_id", "index_notes_on_superagent_id")
    safe_rename_index("index_note_history_events_on_collective_id", "index_note_history_events_on_superagent_id")
    safe_rename_index("index_links_on_collective_id", "index_links_on_superagent_id")
    safe_rename_index("index_invites_on_collective_id", "index_invites_on_superagent_id")
    safe_rename_index("index_heartbeats_on_collective_id", "index_heartbeats_on_superagent_id")
    safe_rename_index("index_events_on_collective_id", "index_events_on_superagent_id")
    safe_rename_index("index_decisions_on_collective_id", "index_decisions_on_superagent_id")
    safe_rename_index("index_decision_participants_on_collective_id", "index_decision_participants_on_superagent_id")
    safe_rename_index("index_commitments_on_collective_id", "index_commitments_on_superagent_id")
    safe_rename_index("index_commitment_participants_on_collective_id", "index_commitment_participants_on_superagent_id")
    safe_rename_index("idx_task_run_resources_on_resource_collective", "idx_task_run_resources_on_resource_superagent")
    safe_rename_index("index_automation_rule_run_resources_on_resource_collective_id", "index_automation_rule_run_resources_on_resource_superagent_id")
    safe_rename_index("index_automation_rule_runs_on_collective_and_created", "index_automation_rule_runs_on_superagent_and_created")
    safe_rename_index("index_automation_rule_runs_on_collective_id", "index_automation_rule_runs_on_superagent_id")
    safe_rename_index("index_automation_rules_on_tenant_collective_enabled", "index_automation_rules_on_tenant_superagent_enabled")
    safe_rename_index("index_automation_rules_on_collective_id", "index_automation_rules_on_superagent_id")
    safe_rename_index("index_attachments_on_collective_id", "index_attachments_on_superagent_id")
    safe_rename_index("index_tenants_on_main_collective_id", "index_tenants_on_main_superagent_id")

    # Non-standard indexes on renamed tables
    safe_rename_index("idx_members_tenant_collective_user", "idx_members_tenant_superagent_user")
    safe_rename_index("idx_members_collective_id", "idx_members_superagent_id")
  end
end
