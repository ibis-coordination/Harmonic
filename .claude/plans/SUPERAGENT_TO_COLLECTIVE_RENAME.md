# Superagent → Collective Rename Plan

**Status:** Ready for implementation
**Created:** 2026-02-12
**Last Verified:** 2026-02-17 (updated with thread-local findings)
**Approach:** Big Bang Migration
**Branch:** `rename-superagent-to-collective`

### Verification Summary (2026-02-17)

**Decisions resolved:** URLs stay same, no API versioning, no aliases (remove dead code), keep "studio" as user-facing term.

Corrections made during verification:
- **Scope updated**: Actual count is ~391 files / ~6,760 occurrences (was ~170 / ~4,700)
- **Added missing categories**: Sorbet RBI files (27 files, ~1,110 occurrences), Jobs, Helpers, Services
- **Fixed database section**: Removed non-existent tables (`cycles`, `webhooks`, `notifications.superagent_id`, `users.proxy_superagent_id`)
- **Added database views**: `cycle_data_*` views need to be dropped and recreated
- **Fixed User model section**: No `belongs_to :proxy_superagent` - it's a computed method
- **Clarified Cycle**: Not an ActiveRecord model (plain Ruby class)

## Overview

Rename all occurrences of "superagent" to "collective" throughout the codebase in a single coordinated deployment. This includes database tables/columns, models, controllers, views, JavaScript, tests, and configuration.

## Scope

| Category | Files | Occurrences |
|----------|-------|-------------|
| Database (migrations + structure.sql) | 21 | ~675 |
| Ruby Models | 38 | ~400 |
| Controllers | 26 | ~350 |
| Views (ERB) | 79 | ~320 |
| Services | 20 | ~290 |
| JavaScript/TypeScript | 5 | ~90 |
| Jobs | 7 | ~55 |
| Helpers | 2 | ~10 |
| Config/Routes | 3 | ~80 |
| Tests | 116 | ~2,820 |
| Sorbet RBI (auto-generated) | 27 | ~1,110 |
| Documentation | 5 | ~60 |
| Other (.claude plans, scripts, etc.) | ~42 | ~500 |
| **Total** | **~391** | **~6,760** |

> **Note:** Sorbet RBI files are auto-generated and will update when `srb rbi dsl` is run after model changes.

## Pre-Migration Checklist

- [ ] Ensure all tests pass on main branch
- [ ] Create database backup
- [ ] **Drain Sidekiq queue** - Jobs queued before migration may fail with new schema
- [ ] Schedule maintenance window (requires brief downtime)
- [ ] Notify users of planned maintenance
- [ ] Prepare rollback plan

---

## Deep Audit Findings (2026-02-17)

### Critical: Migration Must Recreate Views

The migration must recreate `cycle_data_*` views with `collective_id`. Reference the previous rename migration at `db/migrate/20260115044701_rename_studio_to_superagent.rb` for the full SQL.

### Critical: Additional Column to Rename

- `superagents.superagent_type` → `collectives.collective_type`

### Non-Obvious Dependencies

| Area | Files | Issue |
|------|-------|-------|
| **Search DSL** | `app/services/search_query.rb`, `search_query_parser.rb` | Hardcoded `"superagent"` string as group_by option |
| **Routes** | `config/routes.rb` | ~70 routes use `:superagent_handle` parameter |
| **JavaScript** | 5 files | Class names, JSON keys (`superagent_id`), data attributes (`data-superagent-id`) |
| **Jobs** | `app/jobs/tenant_scoped_job.rb`, `application_job.rb` | `set_superagent_context!` method, thread-local key symbols (`:superagent_id`, `:superagent_handle`, `:main_superagent_id`) |
| **Thread-locals** | `app/models/tenant.rb`, `app/models/superagent.rb` | `Thread.current[:main_superagent_id]`, `Tenant.current_main_superagent_id` methods |
| **Pinnable concern** | `app/models/concerns/pinnable.rb` | References `tenant.main_superagent_id` |
| **Metrics** | `config/initializers/yabeda.rb` | `superagent_id` metric tag - changing breaks historical continuity |
| **Logging** | `config/initializers/lograge.rb` | `superagent_id` in structured logs |

### Deployment Sequence

1. **Pre-deployment**: Drain Sidekiq queue, backup database
2. **Maintenance mode**: Enable
3. **Run migration**: All database changes
4. **Deploy code**: All application code changes must deploy atomically with migration
5. **Verify**: Run smoke tests
6. **Exit maintenance mode**

**Why atomic deployment required**: Code references `Collective` model but database has `superagents` table until migration runs. Can't do rolling deployment.

### 100% Complete Rename - Nothing Left Behind

The migration renames **all 128 indexes** containing "superagent":
- 31 regular table indexes
- 96 search_index partition indexes (16 partitions × 6 indexes)
- 1 parent search_index index

After migration, `grep -i superagent` on the database schema will return **zero results**.

### Historical Items (Immutable Past - Not Runtime Code)

These files document past actions and are NOT part of the running application:
- **18 old migration files** - Changing them would corrupt Rails migration history
- **24 completed plan documents** - Historical decision records
- **Historical metrics** - Past data with old tag names is just history

---

## Lessons from Previous Rename (studio → superagent)

Analyzed the original rename migration (`db/migrate/20260115044701_rename_studio_to_superagent.rb`) and the follow-up fix (`db/migrate/20260115180000_fix_active_storage_record_type_for_superagent.rb`).

### What Went Wrong

**Bug: Polymorphic `record_type` not updated** - The original migration renamed tables and columns but forgot to update `active_storage_attachments.record_type` from `'Studio'` to `'Superagent'`. This caused all studio icon images to disappear after deployment. A follow-up migration was deployed same day to fix it.

**Lesson**: Our migration MUST include the polymorphic type update. ✅ Already included in our plan.

### Good Patterns to Adopt

1. **Uses `up` and `down` methods** - Required for raw SQL (execute statements)
2. **Safety checks** - Uses `table_exists?`, `column_exists?`, `index_name_exists?` before operations
3. **Documentation header** - Lists all tables/columns being renamed
4. **Iterates over table list** - Cleaner than individual `rename_column` calls:
   ```ruby
   tables_with_studio_id.each do |table|
     next unless table_exists?(table)
     rename_column table, :studio_id, :superagent_id
   end
   ```
5. **Index name length check** - PostgreSQL has 63-char limit; some indexes were preemptively renamed

### Verified for Our Migration

- ✅ Index name lengths: All renamed names are within 63-char limit (checked)
- ✅ Polymorphic types: `active_storage_attachments.record_type` update included
- ✅ User type enum: `users.user_type` update included
- ✅ Uses `up`/`down` methods
- ⚠️ **Should add**: Safety checks (`table_exists?`, `index_name_exists?`) for robustness

### Tables That No Longer Exist

These were in the old migration but have since been dropped:
- `cycle_data_rows` - dropped
- `webhooks` - dropped (replaced by `webhook_deliveries`)
- `representation_session_associations` - dropped (replaced by `representation_session_events`)

### New Tables Since Original Rename

These tables with `superagent` columns didn't exist during the original rename:
- `automation_rules`, `automation_rule_runs`, `automation_rule_run_resources`
- `ai_agent_task_run_resources`
- `representation_session_events`
- `search_index` partitions (16 partitions created after original rename)

All are included in our migration plan.

---

## Schema Change Ordering Analysis (2026-02-17)

### Verified Constraints

**Foreign Key Constraints:**
- 27 foreign keys reference the `superagents` table
- All FK constraint names use auto-generated hashes (e.g., `fk_rails_803b260faa`), NOT column/table names
- FKs automatically update when referenced table/column is renamed (PostgreSQL metadata change only)

**Circular Reference:**
- `tenants.main_superagent_id` → `superagents.id` (NULLABLE)
- `superagents.tenant_id` → `tenants.id` (NOT NULL)
- **No issue**: Table renames are metadata-only operations, executed atomically

**Other Constraints Checked:**
- ✅ No triggers reference "superagent"
- ✅ No CHECK constraints reference "superagent"
- ✅ No column DEFAULT values reference "superagent"
- ✅ No UNIQUE constraints have "superagent" in their names (only in index names, which we rename)

**Partitioned Table (search_index):**
- 16 hash partitions (search_index_p0 through search_index_p15)
- Column rename on parent propagates to all partitions automatically (PostgreSQL 11+)
- Index renames must be done individually per partition

### Safe Ordering (Guaranteed No Constraint Violations)

The migration operations are safe in this order:

1. **DROP views first** - Views depend on column names being renamed
2. **Rename tables** (`superagents` → `collectives`, `superagent_members` → `collective_members`)
   - FKs referencing these tables auto-update
3. **Rename columns in referencing tables** - After table rename, column can be renamed
4. **Rename columns in the renamed tables themselves** (e.g., `collective_members.superagent_id`)
5. **Handle partitioned table column** - Raw SQL for parent, partitions inherit
6. **UPDATE polymorphic type values** (active_storage_attachments.record_type)
7. **UPDATE enum values** (users.user_type)
8. **Recreate views** with new column names
9. **Rename indexes** - Pure metadata, no dependencies

### Transaction Safety

**Single Transaction**: Rails migrations run in a single transaction by default. All operations succeed or all fail - no partial state possible.

**Must use `up` and `down` methods**: The `change` method only auto-reverses Rails DSL methods (`rename_table`, `rename_column`, `rename_index`). Raw SQL via `execute` is NOT reversible. This migration has many `execute` statements:
- `DROP VIEW` / `CREATE VIEW`
- `ALTER TABLE ... RENAME COLUMN` (partitioned table)
- `UPDATE` statements (polymorphic types, enum values)
- `ALTER INDEX ... RENAME TO`

Therefore we must define explicit `up` and `down` methods with mirrored SQL.

### Verified: Table Column List (Authoritative)

Tables with `superagent_id` column (18 tables):
- attachments, automation_rule_runs, automation_rules, commitment_participants
- commitments, decision_participants, decisions, events, heartbeats, invites
- links, note_history_events, notes, options, representation_session_events
- representation_sessions, superagent_members, votes

Tables with `resource_superagent_id` column (3 tables):
- ai_agent_task_run_resources, automation_rule_run_resources, representation_session_events

Other superagent columns:
- `superagents.superagent_type` → `collectives.collective_type`
- `tenants.main_superagent_id` → `tenants.main_collective_id`
- `search_index.superagent_id` → `search_index.collective_id` (partitioned, 16 child tables inherit)

**NOT in scope** (verified no superagent column):
- `webhook_deliveries` - does NOT have superagent_id column

---

## Phase 1: Database Migration

Create a single migration that renames all database objects.

### Tables with `superagent` Columns (Verified 2026-02-17)

**Tables to rename:**
- `superagents` → `collectives`
- `superagent_members` → `collective_members`

**Columns to rename (`superagent_id` → `collective_id`):**
- `notes`, `decisions`, `commitments`, `links`, `options`, `votes`
- `attachments`, `events`, `invites`, `heartbeats`
- `decision_participants`, `commitment_participants`, `note_history_events`
- `automation_rules`, `automation_rule_runs`
- `representation_sessions`, `representation_session_events`
- `search_index` (partitioned table with 16 partitions)

**Special columns:**
- `superagents.superagent_type` → `collectives.collective_type`
- `tenants.main_superagent_id` → `main_collective_id`
- `ai_agent_task_run_resources.resource_superagent_id` → `resource_collective_id`
- `automation_rule_run_resources.resource_superagent_id` → `resource_collective_id`
- `representation_session_events.resource_superagent_id` → `resource_collective_id`

**Views to recreate** (depend on renamed columns):
- `cycle_data_notes`, `cycle_data_decisions`, `cycle_data_commitments`, `cycle_data`

> **Note:** There is no `cycles` table - `Cycle` is a plain Ruby class, not an ActiveRecord model.
> **Note:** There is no `users.proxy_superagent_id` - the relationship is `superagents.proxy_user_id` (pointing TO users).
> **Note:** There is no `webhooks` table - it was dropped. `webhook_deliveries` exists but does NOT have a superagent_id column.
> **Note:** There is no `notifications.superagent_id` - notifications don't have a superagent column.

### File: `db/migrate/YYYYMMDDHHMMSS_rename_superagent_to_collective.rb`

```ruby
class RenameSuperagentToCollective < ActiveRecord::Migration[7.0]
  # Must use up/down instead of change because raw SQL (execute) is not auto-reversible

  def up
    # 1. Drop views first (they depend on columns we're renaming)
    execute "DROP VIEW IF EXISTS cycle_data CASCADE;"
    execute "DROP VIEW IF EXISTS cycle_data_notes CASCADE;"
    execute "DROP VIEW IF EXISTS cycle_data_decisions CASCADE;"
    execute "DROP VIEW IF EXISTS cycle_data_commitments CASCADE;"

    # 2. Rename main tables
    rename_table :superagents, :collectives
    rename_table :superagent_members, :collective_members

    # 3. Rename superagent_id columns in core tables
    rename_column :notes, :superagent_id, :collective_id
    rename_column :decisions, :superagent_id, :collective_id
    rename_column :commitments, :superagent_id, :collective_id
    rename_column :links, :superagent_id, :collective_id
    rename_column :options, :superagent_id, :collective_id
    rename_column :votes, :superagent_id, :collective_id
    rename_column :attachments, :superagent_id, :collective_id
    rename_column :events, :superagent_id, :collective_id
    rename_column :invites, :superagent_id, :collective_id
    rename_column :heartbeats, :superagent_id, :collective_id
    rename_column :decision_participants, :superagent_id, :collective_id
    rename_column :commitment_participants, :superagent_id, :collective_id
    rename_column :note_history_events, :superagent_id, :collective_id
    rename_column :automation_rules, :superagent_id, :collective_id
    rename_column :automation_rule_runs, :superagent_id, :collective_id
    rename_column :representation_sessions, :superagent_id, :collective_id
    rename_column :representation_session_events, :superagent_id, :collective_id

    # 4. Rename resource_superagent_id columns
    rename_column :ai_agent_task_run_resources, :resource_superagent_id, :resource_collective_id
    rename_column :automation_rule_run_resources, :resource_superagent_id, :resource_collective_id
    rename_column :representation_session_events, :resource_superagent_id, :resource_collective_id

    # 5. Rename in join table (after table rename)
    rename_column :collective_members, :superagent_id, :collective_id

    # 6. Rename special columns
    rename_column :tenants, :main_superagent_id, :main_collective_id

    # 7. Handle partitioned search_index table (parent + 16 partitions)
    execute "ALTER TABLE search_index RENAME COLUMN superagent_id TO collective_id;"

    # 8. Update polymorphic type references
    execute "UPDATE active_storage_attachments SET record_type = 'Collective' WHERE record_type = 'Superagent';"

    # 9. Rename superagent_type column
    rename_column :collectives, :superagent_type, :collective_type

    # 10. Update user_type enum value
    execute "UPDATE users SET user_type = 'collective_proxy' WHERE user_type = 'superagent_proxy';"

    # 11. Recreate views with collective_id
    create_views_with_column(:collective_id)

    # 12. Rename all indexes containing "superagent"
    rename_indexes_superagent_to_collective
  end

  def down
    # 1. Drop views first
    execute "DROP VIEW IF EXISTS cycle_data CASCADE;"
    execute "DROP VIEW IF EXISTS cycle_data_notes CASCADE;"
    execute "DROP VIEW IF EXISTS cycle_data_decisions CASCADE;"
    execute "DROP VIEW IF EXISTS cycle_data_commitments CASCADE;"

    # 2. Rename indexes back (reverse order)
    rename_indexes_collective_to_superagent

    # 3. Revert user_type enum value
    execute "UPDATE users SET user_type = 'superagent_proxy' WHERE user_type = 'collective_proxy';"

    # 4. Rename collective_type column back
    rename_column :collectives, :collective_type, :superagent_type

    # 5. Revert polymorphic type references
    execute "UPDATE active_storage_attachments SET record_type = 'Superagent' WHERE record_type = 'Collective';"

    # 6. Revert partitioned search_index column
    execute "ALTER TABLE search_index RENAME COLUMN collective_id TO superagent_id;"

    # 7. Revert special columns
    rename_column :tenants, :main_collective_id, :main_superagent_id

    # 8. Revert join table column (before table rename)
    rename_column :collective_members, :collective_id, :superagent_id

    # 9. Revert resource_collective_id columns
    rename_column :representation_session_events, :resource_collective_id, :resource_superagent_id
    rename_column :automation_rule_run_resources, :resource_collective_id, :resource_superagent_id
    rename_column :ai_agent_task_run_resources, :resource_collective_id, :resource_superagent_id

    # 10. Revert collective_id columns in core tables
    rename_column :representation_session_events, :collective_id, :superagent_id
    rename_column :representation_sessions, :collective_id, :superagent_id
    rename_column :automation_rule_runs, :collective_id, :superagent_id
    rename_column :automation_rules, :collective_id, :superagent_id
    rename_column :note_history_events, :collective_id, :superagent_id
    rename_column :commitment_participants, :collective_id, :superagent_id
    rename_column :decision_participants, :collective_id, :superagent_id
    rename_column :heartbeats, :collective_id, :superagent_id
    rename_column :invites, :collective_id, :superagent_id
    rename_column :events, :collective_id, :superagent_id
    rename_column :attachments, :collective_id, :superagent_id
    rename_column :votes, :collective_id, :superagent_id
    rename_column :options, :collective_id, :superagent_id
    rename_column :links, :collective_id, :superagent_id
    rename_column :commitments, :collective_id, :superagent_id
    rename_column :decisions, :collective_id, :superagent_id
    rename_column :notes, :collective_id, :superagent_id

    # 11. Rename tables back
    rename_table :collective_members, :superagent_members
    rename_table :collectives, :superagents

    # 12. Recreate views with superagent_id
    create_views_with_column(:superagent_id)
  end

  private

  def create_views_with_column(col)
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

  def rename_indexes_superagent_to_collective
    # Regular table indexes
    rename_index :collective_members, 'idx_members_superagent_id', 'idx_members_collective_id'
    rename_index :collective_members, 'idx_members_tenant_superagent_user', 'idx_members_tenant_collective_user'
    rename_index :collective_members, 'index_superagent_members_on_tenant_id', 'index_collective_members_on_tenant_id'
    rename_index :collective_members, 'index_superagent_members_on_user_id', 'index_collective_members_on_user_id'
    rename_index :collectives, 'index_superagents_on_created_by_id', 'index_collectives_on_created_by_id'
    rename_index :collectives, 'index_superagents_on_tenant_id', 'index_collectives_on_tenant_id'
    rename_index :collectives, 'index_superagents_on_tenant_id_and_handle', 'index_collectives_on_tenant_id_and_handle'
    rename_index :collectives, 'index_superagents_on_updated_by_id', 'index_collectives_on_updated_by_id'
    rename_index :tenants, 'index_tenants_on_main_superagent_id', 'index_tenants_on_main_collective_id'
    rename_index :attachments, 'index_attachments_on_superagent_id', 'index_attachments_on_collective_id'
    rename_index :automation_rules, 'index_automation_rules_on_superagent_id', 'index_automation_rules_on_collective_id'
    rename_index :automation_rules, 'index_automation_rules_on_tenant_superagent_enabled', 'index_automation_rules_on_tenant_collective_enabled'
    rename_index :automation_rule_runs, 'index_automation_rule_runs_on_superagent_id', 'index_automation_rule_runs_on_collective_id'
    rename_index :automation_rule_runs, 'index_automation_rule_runs_on_superagent_and_created', 'index_automation_rule_runs_on_collective_and_created'
    rename_index :automation_rule_run_resources, 'index_automation_rule_run_resources_on_resource_superagent_id', 'index_automation_rule_run_resources_on_resource_collective_id'
    rename_index :ai_agent_task_run_resources, 'idx_task_run_resources_on_resource_superagent', 'idx_task_run_resources_on_resource_collective'
    rename_index :commitment_participants, 'index_commitment_participants_on_superagent_id', 'index_commitment_participants_on_collective_id'
    rename_index :commitments, 'index_commitments_on_superagent_id', 'index_commitments_on_collective_id'
    rename_index :decision_participants, 'index_decision_participants_on_superagent_id', 'index_decision_participants_on_collective_id'
    rename_index :decisions, 'index_decisions_on_superagent_id', 'index_decisions_on_collective_id'
    rename_index :events, 'index_events_on_superagent_id', 'index_events_on_collective_id'
    rename_index :heartbeats, 'index_heartbeats_on_superagent_id', 'index_heartbeats_on_collective_id'
    rename_index :invites, 'index_invites_on_superagent_id', 'index_invites_on_collective_id'
    rename_index :links, 'index_links_on_superagent_id', 'index_links_on_collective_id'
    rename_index :note_history_events, 'index_note_history_events_on_superagent_id', 'index_note_history_events_on_collective_id'
    rename_index :notes, 'index_notes_on_superagent_id', 'index_notes_on_collective_id'
    rename_index :options, 'index_options_on_superagent_id', 'index_options_on_collective_id'
    rename_index :representation_sessions, 'index_representation_sessions_on_superagent_id', 'index_representation_sessions_on_collective_id'
    rename_index :representation_session_events, 'index_representation_session_events_on_superagent_id', 'index_representation_session_events_on_collective_id'
    rename_index :representation_session_events, 'idx_rep_events_resource_superagent', 'idx_rep_events_resource_collective'
    rename_index :votes, 'index_votes_on_superagent_id', 'index_votes_on_collective_id'

    # search_index partition indexes (96 indexes across 16 partitions)
    (0..15).each do |p|
      execute "ALTER INDEX search_index_p#{p}_tenant_id_superagent_id_idx RENAME TO search_index_p#{p}_tenant_id_collective_id_idx;"
      execute "ALTER INDEX search_index_p#{p}_tenant_id_superagent_id_created_at_idx RENAME TO search_index_p#{p}_tenant_id_collective_id_created_at_idx;"
      execute "ALTER INDEX search_index_p#{p}_tenant_id_superagent_id_deadline_idx RENAME TO search_index_p#{p}_tenant_id_collective_id_deadline_idx;"
      execute "ALTER INDEX search_index_p#{p}_tenant_id_superagent_id_item_type_idx RENAME TO search_index_p#{p}_tenant_id_collective_id_item_type_idx;"
      execute "ALTER INDEX search_index_p#{p}_tenant_id_superagent_id_sort_key_idx RENAME TO search_index_p#{p}_tenant_id_collective_id_sort_key_idx;"
      execute "ALTER INDEX search_index_p#{p}_tenant_id_superagent_id_subtype_idx RENAME TO search_index_p#{p}_tenant_id_collective_id_subtype_idx;"
    end

    # Parent search_index index
    execute "ALTER INDEX idx_search_index_tenant_superagent RENAME TO idx_search_index_tenant_collective;"
  end

  def rename_indexes_collective_to_superagent
    # Parent search_index index
    execute "ALTER INDEX idx_search_index_tenant_collective RENAME TO idx_search_index_tenant_superagent;"

    # search_index partition indexes (reverse)
    (0..15).each do |p|
      execute "ALTER INDEX search_index_p#{p}_tenant_id_collective_id_idx RENAME TO search_index_p#{p}_tenant_id_superagent_id_idx;"
      execute "ALTER INDEX search_index_p#{p}_tenant_id_collective_id_created_at_idx RENAME TO search_index_p#{p}_tenant_id_superagent_id_created_at_idx;"
      execute "ALTER INDEX search_index_p#{p}_tenant_id_collective_id_deadline_idx RENAME TO search_index_p#{p}_tenant_id_superagent_id_deadline_idx;"
      execute "ALTER INDEX search_index_p#{p}_tenant_id_collective_id_item_type_idx RENAME TO search_index_p#{p}_tenant_id_superagent_id_item_type_idx;"
      execute "ALTER INDEX search_index_p#{p}_tenant_id_collective_id_sort_key_idx RENAME TO search_index_p#{p}_tenant_id_superagent_id_sort_key_idx;"
      execute "ALTER INDEX search_index_p#{p}_tenant_id_collective_id_subtype_idx RENAME TO search_index_p#{p}_tenant_id_superagent_id_subtype_idx;"
    end

    # Regular table indexes (reverse)
    rename_index :votes, 'index_votes_on_collective_id', 'index_votes_on_superagent_id'
    rename_index :representation_session_events, 'idx_rep_events_resource_collective', 'idx_rep_events_resource_superagent'
    rename_index :representation_session_events, 'index_representation_session_events_on_collective_id', 'index_representation_session_events_on_superagent_id'
    rename_index :representation_sessions, 'index_representation_sessions_on_collective_id', 'index_representation_sessions_on_superagent_id'
    rename_index :options, 'index_options_on_collective_id', 'index_options_on_superagent_id'
    rename_index :notes, 'index_notes_on_collective_id', 'index_notes_on_superagent_id'
    rename_index :note_history_events, 'index_note_history_events_on_collective_id', 'index_note_history_events_on_superagent_id'
    rename_index :links, 'index_links_on_collective_id', 'index_links_on_superagent_id'
    rename_index :invites, 'index_invites_on_collective_id', 'index_invites_on_superagent_id'
    rename_index :heartbeats, 'index_heartbeats_on_collective_id', 'index_heartbeats_on_superagent_id'
    rename_index :events, 'index_events_on_collective_id', 'index_events_on_superagent_id'
    rename_index :decisions, 'index_decisions_on_collective_id', 'index_decisions_on_superagent_id'
    rename_index :decision_participants, 'index_decision_participants_on_collective_id', 'index_decision_participants_on_superagent_id'
    rename_index :commitments, 'index_commitments_on_collective_id', 'index_commitments_on_superagent_id'
    rename_index :commitment_participants, 'index_commitment_participants_on_collective_id', 'index_commitment_participants_on_superagent_id'
    rename_index :ai_agent_task_run_resources, 'idx_task_run_resources_on_resource_collective', 'idx_task_run_resources_on_resource_superagent'
    rename_index :automation_rule_run_resources, 'index_automation_rule_run_resources_on_resource_collective_id', 'index_automation_rule_run_resources_on_resource_superagent_id'
    rename_index :automation_rule_runs, 'index_automation_rule_runs_on_collective_and_created', 'index_automation_rule_runs_on_superagent_and_created'
    rename_index :automation_rule_runs, 'index_automation_rule_runs_on_collective_id', 'index_automation_rule_runs_on_superagent_id'
    rename_index :automation_rules, 'index_automation_rules_on_tenant_collective_enabled', 'index_automation_rules_on_tenant_superagent_enabled'
    rename_index :automation_rules, 'index_automation_rules_on_collective_id', 'index_automation_rules_on_superagent_id'
    rename_index :attachments, 'index_attachments_on_collective_id', 'index_attachments_on_superagent_id'
    rename_index :tenants, 'index_tenants_on_main_collective_id', 'index_tenants_on_main_superagent_id'
    rename_index :collectives, 'index_collectives_on_updated_by_id', 'index_superagents_on_updated_by_id'
    rename_index :collectives, 'index_collectives_on_tenant_id_and_handle', 'index_superagents_on_tenant_id_and_handle'
    rename_index :collectives, 'index_collectives_on_tenant_id', 'index_superagents_on_tenant_id'
    rename_index :collectives, 'index_collectives_on_created_by_id', 'index_superagents_on_created_by_id'
    rename_index :collective_members, 'index_collective_members_on_user_id', 'index_superagent_members_on_user_id'
    rename_index :collective_members, 'index_collective_members_on_tenant_id', 'index_superagent_members_on_tenant_id'
    rename_index :collective_members, 'idx_members_tenant_collective_user', 'idx_members_tenant_superagent_user'
    rename_index :collective_members, 'idx_members_collective_id', 'idx_members_superagent_id'
  end
end
```

### Verification Commands

**Before migration** - list all superagent columns:
```bash
docker compose exec web rails runner "
  ActiveRecord::Base.connection.tables.each do |table|
    cols = ActiveRecord::Base.connection.columns(table).map(&:name)
    superagent_cols = cols.select { |c| c.include?('superagent') }
    puts \"#{table}: #{superagent_cols.join(', ')}\" if superagent_cols.any?
  end
"
```

**After migration** - verify no superagent columns remain:
```bash
docker compose exec web rails runner "
  found = false
  ActiveRecord::Base.connection.tables.each do |table|
    cols = ActiveRecord::Base.connection.columns(table).map(&:name)
    superagent_cols = cols.select { |c| c.include?('superagent') }
    if superagent_cols.any?
      puts \"REMAINING COLUMN: #{table}: #{superagent_cols.join(', ')}\"
      found = true
    end
  end
  puts 'All superagent columns renamed!' unless found
"
```

**After migration** - verify no superagent indexes remain:
```bash
docker compose exec web rails runner "
  result = ActiveRecord::Base.connection.execute(\"
    SELECT indexname FROM pg_indexes
    WHERE schemaname = 'public' AND indexname LIKE '%superagent%'
  \")
  if result.count > 0
    puts 'REMAINING INDEXES:'
    result.each { |r| puts r['indexname'] }
  else
    puts 'All superagent indexes renamed!'
  end
"
```

**After migration** - verify no superagent tables remain:
```bash
docker compose exec web rails runner "
  result = ActiveRecord::Base.connection.execute(\"
    SELECT tablename FROM pg_tables
    WHERE schemaname = 'public' AND tablename LIKE '%superagent%'
  \")
  if result.count > 0
    puts 'REMAINING TABLES:'
    result.each { |r| puts r['tablename'] }
  else
    puts 'All superagent tables renamed!'
  end
"
```

---

## Phase 2: Model Layer Changes

### 2.1 Rename Model Files

| Old Path | New Path |
|----------|----------|
| `app/models/superagent.rb` | `app/models/collective.rb` |
| `app/models/superagent_member.rb` | `app/models/collective_member.rb` |
| `app/models/concerns/might_not_belong_to_superagent.rb` | `app/models/concerns/might_not_belong_to_collective.rb` |

### 2.2 Update Class Names

```ruby
# app/models/collective.rb
class Collective < ApplicationRecord
  # All internal references to Superagent → Collective
  # All superagent_* methods → collective_*
end

# app/models/collective_member.rb
class CollectiveMember < ApplicationRecord
  belongs_to :collective
  belongs_to :user
end
```

### 2.3 Update ApplicationRecord

```ruby
# app/models/application_record.rb
default_scope do
  if belongs_to_tenant? && Tenant.current_id
    s = where(tenant_id: Tenant.current_id)
    if belongs_to_collective? && Collective.current_id
      s = s.where(collective_id: Collective.current_id)
    end
    s
  else
    all
  end
end

def self.belongs_to_collective?
  column_names.include?("collective_id")
end
```

### 2.4 Update Thread-Local Variables

In `app/models/collective.rb`:

```ruby
class Collective < ApplicationRecord
  def self.current_id
    Thread.current[:collective_id]
  end

  def self.current_id=(id)
    Thread.current[:collective_id] = id
  end

  def self.current_handle
    Thread.current[:collective_handle]
  end

  def self.current_handle=(handle)
    Thread.current[:collective_handle] = handle
  end

  def self.scope_thread_to_collective(subdomain: nil, handle: nil)
    # ... updated implementation
  end

  def self.clear_thread_scope
    Thread.current[:collective_id] = nil
    Thread.current[:collective_handle] = nil
  end
end
```

### 2.5 Update All Model Associations

Update ~28 models with `belongs_to :superagent`:

```ruby
# Before
belongs_to :superagent

# After
belongs_to :collective
```

Models to update:
- `Note`, `Decision`, `Commitment`, `Link` (not `Cycle` - it's not an AR model)
- `Option`, `Vote`, `Attachment`, `Webhook`, `Event`
- `Invite`, `Notification`, `AiAgentTaskRun`, `AutomationRule`
- `AutomationRuleRun`, `RepresentationSession`, `RepresentationSessionEvent`
- `CyclesDataNote`, `CyclesDataDecision`, `CyclesDataCommitment`
- And others...

### 2.6 Update Tenant Model

```ruby
# app/models/tenant.rb
belongs_to :main_collective, class_name: "Collective", optional: true
# was: belongs_to :main_superagent
```

**Thread-local variables for main collective ID:**

The Tenant model caches the main collective ID in a thread-local variable for quick access during request handling. These must be renamed:

```ruby
# app/models/tenant.rb

# Thread-local key rename: :main_superagent_id → :main_collective_id

# In scope_thread_to_tenant:
self.current_main_collective_id = tenant.main_collective_id
# was: self.current_main_superagent_id = tenant.main_superagent_id

# In clear_thread_scope:
Thread.current[:main_collective_id] = nil
# was: Thread.current[:main_superagent_id] = nil

# In set_thread_context:
self.current_main_collective_id = tenant.main_collective_id
# was: self.current_main_superagent_id = tenant.main_superagent_id

# Getter:
def self.current_main_collective_id
  Thread.current[:main_collective_id]
end
# was: def self.current_main_superagent_id

# Setter:
def self.current_main_collective_id=(id)
  Thread.current[:main_collective_id] = id
end
# was: def self.current_main_superagent_id=
```

**ApplicationJob thread-local save/restore:**

```ruby
# app/jobs/application_job.rb

def save_tenant_context
  {
    # ...
    main_collective_id: Thread.current[:main_collective_id],
    collective_id: Thread.current[:collective_id],
    collective_handle: Thread.current[:collective_handle],
    # was: main_superagent_id, superagent_id, superagent_handle
  }
end

def restore_tenant_context(saved)
  # ...
  Thread.current[:main_collective_id] = saved[:main_collective_id]
  Thread.current[:collective_id] = saved[:collective_id]
  Thread.current[:collective_handle] = saved[:collective_handle]
end
```

### 2.7 Update User Model

The User model doesn't have a `belongs_to :superagent` column. Instead, it has a computed `proxy_superagent` method that finds the Collective where `proxy_user: self`:

```ruby
# app/models/user.rb
# Rename method: proxy_superagent → proxy_collective
def proxy_collective
  return @proxy_collective if defined?(@proxy_collective)
  @proxy_collective = Collective.where(proxy_user: self).first
end
# was: def proxy_superagent
```

Also update the `Collective` model (formerly `Superagent`):
```ruby
# app/models/collective.rb
belongs_to :proxy_user, class_name: "User", optional: true
# This column stays as proxy_user_id (no rename needed)
```

### 2.8 Remove Dead Alias

**Decision:** No aliases. Remove the existing dead `Studio = Superagent` alias from `app/models/superagent.rb:559`.

The alias isn't used anywhere in the code - it was leftover from a previous rename. Any missing references will fail immediately, which is the desired behavior.

---

## Phase 3: Controller Layer Changes

### 3.1 Update ApplicationController

```ruby
# app/controllers/application_controller.rb
before_action :set_collective_context

def set_collective_context
  Collective.scope_thread_to_collective(
    subdomain: request.subdomain,
    handle: params[:collective_handle]
  )
end

def current_collective
  @current_collective ||= Collective.find_by(handle: params[:collective_handle])
end
helper_method :current_collective
```

### 3.2 Rename Instance Variables

In all controllers, rename:
- `@superagent` → `@collective`
- `@superagents` → `@collectives`
- `superagent_params` → `collective_params`

### 3.3 Controllers to Update

- `studios_controller.rb` - Primary collective management
- `ai_agents_controller.rb`
- `cycles_controller.rb`
- `notes_controller.rb`
- `decisions_controller.rb`
- `commitments_controller.rb`
- `pulse_controller.rb`
- `webhooks_controller.rb`
- `invites_controller.rb`
- `admin_controller.rb`
- `app_admin_controller.rb`
- And ~12 more...

---

## Phase 4: Routes Changes

### 4.1 Update Route Parameters

```ruby
# config/routes.rb

# Before
scope "studios/:superagent_handle", as: :studio do
  # ...
end

# After
scope "studios/:collective_handle", as: :studio do
  # ...
end
```

### 4.2 URL Helper Changes

All URL helpers using `superagent_handle` will change:
- `studio_notes_path(superagent_handle: ...)` → `studio_notes_path(collective_handle: ...)`

---

## Phase 5: View Layer Changes

### 5.1 Update Instance Variables in Views

In all 89 ERB templates:
- `@superagent` → `@collective`
- `superagent.handle` → `collective.handle`
- `superagent_path` helpers updated

### 5.2 Key View Directories

- `app/views/studios/` - 12+ files
- `app/views/pulse/` - Main UI
- `app/views/shared/` - 8+ partials
- `app/views/cycles/`, `notes/`, `decisions/`, `commitments/`
- `app/views/layouts/`

---

## Phase 6: JavaScript/TypeScript Changes

### 6.1 Rename Controller File

```
app/javascript/controllers/ai_agent_superagent_adder_controller.ts
→ app/javascript/controllers/ai_agent_collective_adder_controller.ts
```

### 6.2 Update Data Attributes

```typescript
// Before
data-ai-agent-superagent-adder-target="..."
this.superagentIdValue

// After
data-ai-agent-collective-adder-target="..."
this.collectiveIdValue
```

### 6.3 Update JSON Payloads

```typescript
// Before
{ superagent_id: ..., superagent_name: ..., superagent_path: ... }

// After
{ collective_id: ..., collective_name: ..., collective_path: ... }
```

### 6.4 Files to Update

- `ai_agent_collective_adder_controller.ts` (renamed)
- `header_search_controller.ts`
- `notification_actions_controller.ts`
- `index.ts` (controller registration)

---

## Phase 7: Test Updates

### 7.1 Rename Test Files

| Old Path | New Path |
|----------|----------|
| `test/models/superagent_test.rb` | `test/models/collective_test.rb` |
| `test/models/superagent_member_test.rb` | `test/models/collective_member_test.rb` |
| `test/models/superagent_single_tenant_test.rb` | `test/models/collective_single_tenant_test.rb` |
| `test/integration/ai_agent_superagent_membership_test.rb` | `test/integration/ai_agent_collective_membership_test.rb` |

### 7.2 Update Test Helpers

```ruby
# test/test_helper.rb

def create_collective(tenant:, handle: nil, **attrs)
  # was: create_superagent
end

def create_tenant_collective_user(...)
  # was: create_tenant_studio_user (if using studio terminology)
end
```

### 7.3 Update Fixtures

```yaml
# test/fixtures/collectives.yml (renamed from superagents.yml)
main_collective:
  tenant: main_tenant
  handle: main
  name: Main Collective
```

---

## Phase 8: Configuration & Documentation

### 8.1 Update Static Analysis Scripts

```bash
# scripts/check-tenant-safety.sh
# Update references from Superagent to Collective
```

### 8.2 Update Documentation

- `CLAUDE.md` - Update all superagent references
- `PHILOSOPHY.md` - Update terminology
- `docs/ARCHITECTURE.md` - Update model descriptions
- `AGENTS.md` - Update AI agent context
- `docs/CODEBASE_PATTERNS.md` - Update patterns

### 8.3 Update Environment Variables

Check for any env vars referencing superagent (likely none).

---

## Phase 9: Service Layer Changes

### 9.1 Update ApiHelper

```ruby
# app/services/api_helper.rb
# Update all superagent references to collective
```

### 9.2 Update Other Services

- `DecisionParticipantManager`
- `CommitmentParticipantManager`
- `FeatureFlagService` - `collective_enabled?` instead of `superagent_enabled?`
- Authorization services

### 9.3 Update Search DSL Strings

In `app/services/search_query.rb` and `search_query_parser.rb`:

```ruby
# Before
VALID_GROUP_BYS = ["none", "item_type", "status", "superagent", ...]
["Studio/Scene", "superagent"]

# After
VALID_GROUP_BYS = ["none", "item_type", "status", "collective", ...]
["Studio/Scene", "collective"]
```

### 9.4 Update Metrics Tags

In `config/initializers/yabeda.rb`:

```ruby
# Note: Changing tag names breaks historical metric continuity
# Before
tags: [:tenant_id, :superagent_id]

# After
tags: [:tenant_id, :collective_id]
```

### 9.5 Update Logging

In `config/initializers/lograge.rb`:

```ruby
# Before
superagent_id: event.payload[:superagent_id]

# After
collective_id: event.payload[:collective_id]
```

---

## Execution Checklist

### Pre-Deployment

- [ ] Create feature branch `feature/rename-superagent-to-collective`
- [ ] Run full find-and-replace with manual review
- [ ] Update all test fixtures
- [ ] Run full test suite locally
- [ ] Test migration on copy of production database
- [ ] Prepare rollback migration

### Deployment

- [ ] Enable maintenance mode
- [ ] **Drain Sidekiq queue** - Wait for all jobs to complete
- [ ] Create database backup
- [ ] Deploy new code AND run migration atomically
- [ ] Verify application starts
- [ ] Run smoke tests
- [ ] Disable maintenance mode

### Post-Deployment

- [ ] Monitor error rates
- [ ] Verify all features work (especially search, cycles)
- [ ] Verify metrics are being emitted with new tag names
- [ ] Update any external documentation

---

## Rollback Plan

If issues occur, rollback with:

1. Revert code to previous commit
2. Run rollback migration:

```ruby
class RevertCollectiveToSuperagent < ActiveRecord::Migration[7.0]
  def change
    # Reverse all rename operations
    rename_table :collectives, :superagents
    rename_table :collective_members, :superagent_members
    # ... reverse all column renames
  end
end
```

---

## Search/Replace Patterns

Use these patterns for find-and-replace (with manual review):

| Find | Replace | Context |
|------|---------|---------|
| `Superagent` | `Collective` | Class names |
| `superagent` | `collective` | Variable names, methods |
| `superagents` | `collectives` | Plurals |
| `SUPERAGENT` | `COLLECTIVE` | Constants |
| `superagent_id` | `collective_id` | Column names |
| `superagent_handle` | `collective_handle` | Route params |
| `:superagent` | `:collective` | Symbols |

**Be careful with:**
- String literals in user-facing text
- Comments and documentation
- Test assertions with string matching

---

## Timeline Estimate

| Phase | Tasks |
|-------|-------|
| Phase 1 | Database migration |
| Phase 2 | Model layer |
| Phase 3 | Controller layer |
| Phase 4 | Routes |
| Phase 5 | Views |
| Phase 6 | JavaScript |
| Phase 7 | Tests |
| Phase 8 | Config/docs |
| Phase 9 | Services |
| Testing | Full regression |
| Deployment | Production release |

---

## Decisions (Resolved 2026-02-17)

1. **URL stability**: Keep URLs the same - no changes to route parameters (`superagent_handle` → `collective_handle` internally, but URL stays `/studios/:handle`)
2. **API versioning**: No external API consumers currently - no versioning needed
3. **No aliases**: Remove dead `Studio = Superagent` alias, don't add any backward compatibility aliases - let bugs surface immediately
4. **User-facing terminology**: Keep "studio" as user-facing term in UI text

---

## Implications of Decisions

- **Views**: Minimal changes needed since user-facing text stays as "studio"
- **Routes**: Internal parameter name changes but URLs remain `/studios/...`
- **Aliases**: None - remove the dead `Studio = Superagent` alias, don't add any new ones
- **Scope reduction**: Views that only use "studio" in user-facing text don't need changes - only internal variable/method names need updating
