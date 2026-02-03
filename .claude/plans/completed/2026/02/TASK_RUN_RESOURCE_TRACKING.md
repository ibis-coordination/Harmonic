# Plan: Track Subagent Task Run Resource Associations

## Goal
Track which resources (Notes, Decisions, etc.) are created by which SubagentTaskRun, enabling:
- Query: "What resources did this task run create?"
- Query: "Which task run created this resource?"
- Traceability from agent-created content back to the originating task

## Approach: Join Table (following RepresentationSessionAssociation pattern)

Use a polymorphic join table like the existing `RepresentationSessionAssociation` model, which already tracks resources created during representation sessions.

**Why this approach:**
- Proven pattern already in codebase
- Single migration, no changes to existing resource tables
- Clean separation - resources don't need to know about task runs
- Flexible queries in both directions
- Easy to extend to new resource types

## Implementation

### Phase 1: Database Schema

**Migration: `CreateSubagentTaskRunResources`**

```ruby
create_table :subagent_task_run_resources, id: :uuid do |t|
  t.references :tenant, null: false, foreign_key: true, type: :uuid
  t.references :subagent_task_run, null: false, foreign_key: true, type: :uuid,
               index: { name: 'idx_task_run_resources_on_task_run_id' }
  t.references :resource, null: false, polymorphic: true, type: :uuid,
               index: { name: 'idx_task_run_resources_on_resource' }
  # Track which superagent owns the resource (may differ from task run's starting superagent)
  t.references :resource_superagent, null: false, foreign_key: { to_table: :studios }, type: :uuid,
               index: { name: 'idx_task_run_resources_on_resource_superagent' }
  t.string :action_type  # 'create', 'update', 'vote', 'commit', etc.
  t.timestamps
end

add_index :subagent_task_run_resources,
          [:subagent_task_run_id, :resource_id, :resource_type],
          unique: true,
          name: 'idx_task_run_resources_unique'
```

**Note:** Unlike most models, this table does NOT have a `superagent_id` column for thread-local scoping. Instead it has `resource_superagent_id` which tracks where each resource lives. This allows a single task run to create resources across multiple studios.

### Phase 2: Models

**New: `app/models/subagent_task_run_resource.rb`**
- `belongs_to :subagent_task_run`
- `belongs_to :resource, polymorphic: true`
- `belongs_to :resource_superagent, class_name: 'Superagent'` - the studio that owns the resource
- Validates resource_type inclusion
- Validates resource_superagent matches the resource's actual superagent
- Auto-sets tenant_id from task run
- Auto-sets resource_superagent_id from the resource itself (not from task run)

**Update: `app/models/subagent_task_run.rb`**
- Add `has_many :subagent_task_run_resources`
- Add thread-local context: `SubagentTaskRun.current_id` / `current_id=` / `clear_thread_scope`
- Add convenience methods: `created_notes`, `created_decisions`, `all_resources`

### Phase 3: Context Management

**Update: `app/jobs/agent_queue_processor_job.rb`**

In `set_context`:
```ruby
SubagentTaskRun.current_id = task_run.id
```

In `clear_context`:
```ruby
SubagentTaskRun.clear_thread_scope
```

### Phase 4: Resource Tracking

**Update: `app/services/api_helper.rb`**

Add helper method:
```ruby
def track_task_run_resource(resource, action_type:)
  return unless SubagentTaskRun.current_id
  return unless resource.respond_to?(:superagent_id) && resource.superagent_id.present?

  SubagentTaskRunResource.create!(
    subagent_task_run_id: SubagentTaskRun.current_id,
    resource: resource,
    resource_superagent_id: resource.superagent_id,  # Track which studio owns this resource
    action_type: action_type
  )
end
```

Call after resource creation in existing methods:
- `create_note` → `track_task_run_resource(note, action_type: 'create')`
- `create_decision` → `track_task_run_resource(decision, action_type: 'create')`
- `create_option` → `track_task_run_resource(option, action_type: 'add_option')`
- `create_vote` → `track_task_run_resource(vote, action_type: 'vote')`
- `confirm_read` → `track_task_run_resource(history_event, action_type: 'confirm')`

This mirrors how `current_representation_session.record_activity!` is already called throughout the codebase.

## Files to Modify

| File | Changes |
|------|---------|
| `db/migrate/YYYYMMDD_create_subagent_task_run_resources.rb` | New migration |
| `app/models/subagent_task_run_resource.rb` | New model |
| `app/models/subagent_task_run.rb` | Add associations, thread-local context, query helpers |
| `app/jobs/agent_queue_processor_job.rb` | Set/clear task run context |
| `app/services/api_helper.rb` | Add tracking after resource creation |
| `sorbet/rbi/dsl/subagent_task_run_resource.rbi` | Generate with tapioca |

## Verification

1. **Run migration**: `docker compose exec web bundle exec rails db:migrate`
2. **Generate RBI**: `docker compose exec web bundle exec tapioca dsl SubagentTaskRunResource`
3. **Run existing tests**: `./scripts/run-tests.sh`
4. **Manual test**:
   - Create a subagent and trigger a task run
   - Have the agent create a note via the markdown UI
   - Query `SubagentTaskRun.last.subagent_task_run_resources` to see the association
   - Query `SubagentTaskRun.last.created_notes` to see the note

## Trade-offs

- **Additional writes**: One extra INSERT per resource created during task runs (minimal overhead)
- **No backfill**: Existing task runs won't have associations (acceptable - new feature)
- **Dangling references**: If a resource is deleted, association record remains (historical record)
