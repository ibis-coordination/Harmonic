# Agent Task Queue Processing

## Goal

Ensure individual agents process tasks sequentially (FIFO) while allowing different agents to work in parallel. Tasks should be visible in the database for admin inspection.

## Design: Queue Processor Pattern

```
@mention triggers task
        │
        ▼
┌─────────────────────────────┐
│  NotificationDispatcher     │
│  • Creates SubagentTaskRun  │
│    with status "queued"     │
│  • Enqueues processor job   │
└─────────────────────────────┘
        │
        ▼
┌─────────────────────────────┐
│  AgentQueueProcessorJob     │
│  • Locks subagent row       │
│  • Checks for running task  │
│  • Claims oldest queued     │
│  • Runs task                │
│  • Enqueues next processor  │
└─────────────────────────────┘
```

## Implementation

### Phase 1: Refactor NotificationDispatcher

**File**: `app/services/notification_dispatcher.rb`

Change `trigger_subagent_tasks` to:
1. Create `SubagentTaskRun` with status `queued` (instead of letting the job create it)
2. Enqueue `AgentQueueProcessorJob` (instead of `AgentTaskJob`)

```ruby
def self.trigger_subagent_tasks(event, mentioned_users, item_path)
  # ... existing rate limit check ...

  subagents.each do |subagent|
    # Create the task run record with "queued" status
    task_run = SubagentTaskRun.create!(
      tenant_id: event.tenant_id,
      subagent: subagent,
      initiated_by_id: event.actor_id,
      task: build_task_prompt(event, item_path),
      max_steps: 15,
      status: "queued"
    )

    # Kick off the queue processor
    AgentQueueProcessorJob.perform_later(subagent_id: subagent.id, tenant_id: event.tenant_id)
  end
end

def self.build_task_prompt(event, item_path)
  actor_name = event.actor&.display_name || "Someone"
  "You were mentioned by #{actor_name}. Navigate to #{item_path} to see the context and respond appropriately by adding a comment."
end
```

### Phase 2: Create AgentQueueProcessorJob

**File**: `app/jobs/agent_queue_processor_job.rb` (new)

```ruby
class AgentQueueProcessorJob < ApplicationJob
  extend T::Sig

  queue_as :default

  class_attribute :navigator_class, default: AgentNavigator

  sig { params(subagent_id: String, tenant_id: String).void }
  def perform(subagent_id:, tenant_id:)
    tenant = Tenant.find_by(id: tenant_id)
    subagent = User.find_by(id: subagent_id)

    return unless tenant && subagent
    return unless subagent.subagent?
    return unless tenant.subagents_enabled?

    task_run = claim_next_task(subagent, tenant)
    return unless task_run

    set_context(tenant, task_run)

    begin
      run_task(task_run)
    ensure
      clear_context
      # Check for more queued tasks
      AgentQueueProcessorJob.perform_later(subagent_id: subagent_id, tenant_id: tenant_id)
    end
  end

  private

  def claim_next_task(subagent, tenant)
    subagent.with_lock do
      # Already running? Exit - the running job will trigger us when done
      return nil if SubagentTaskRun.where(subagent: subagent, tenant: tenant, status: "running").exists?

      # Get oldest queued task
      next_task = SubagentTaskRun
        .where(subagent: subagent, tenant: tenant, status: "queued")
        .order(:created_at)
        .first

      return nil unless next_task

      # Claim it
      next_task.update!(status: "running", started_at: Time.current)
      next_task
    end
  end

  def run_task(task_run)
    navigator = self.class.navigator_class.new(
      user: task_run.subagent,
      tenant: task_run.tenant,
      superagent: resolve_superagent(task_run)
    )

    result = navigator.run(task: task_run.task, max_steps: task_run.max_steps)

    task_run.update!(
      status: result.success ? "completed" : "failed",
      success: result.success,
      final_message: result.final_message,
      error: result.error,
      steps_count: result.steps.count,
      steps_data: result.steps.map { |s| { type: s.type, detail: s.detail, timestamp: s.timestamp.iso8601 } },
      completed_at: Time.current
    )
  end

  def resolve_superagent(task_run)
    # Extract superagent from task path if possible, or use first available
    task_run.subagent.superagent_members.first&.superagent
  end

  def set_context(tenant, task_run)
    Tenant.current_subdomain = tenant.subdomain
    Tenant.current_id = tenant.id
    Tenant.current_main_superagent_id = tenant.main_superagent_id

    superagent = resolve_superagent(task_run)
    if superagent
      Thread.current[:superagent_id] = superagent.id
      Thread.current[:superagent_handle] = superagent.handle
    end
  end

  def clear_context
    Tenant.clear_thread_scope
    Superagent.clear_thread_scope
  end
end
```

### Phase 3: Delete AgentTaskJob

Remove `app/jobs/agent_task_job.rb` since we're replacing it with the queue processor pattern.

### Phase 4: Update SubagentTaskRun model

**File**: `app/models/subagent_task_run.rb`

Add helper method:

```ruby
def queued?
  status == "queued"
end
```

### Phase 5: Update Tests

**Files**:
- `test/jobs/agent_queue_processor_job_test.rb` (new)
- `test/services/notification_dispatcher_test.rb` (update assertions)
- `test/jobs/agent_task_job_test.rb` (delete)

## Files Summary

| File | Action |
|------|--------|
| `app/jobs/agent_queue_processor_job.rb` | Create |
| `app/jobs/agent_task_job.rb` | Delete |
| `app/services/notification_dispatcher.rb` | Modify |
| `app/models/subagent_task_run.rb` | Minor addition |
| `test/jobs/agent_queue_processor_job_test.rb` | Create |
| `test/jobs/agent_task_job_test.rb` | Delete |
| `test/services/notification_dispatcher_test.rb` | Update |

## Key Behaviors

1. **Sequential per agent**: Row lock on subagent ensures only one task claims "running" at a time
2. **FIFO ordering**: `order(:created_at).first` picks oldest queued task
3. **Parallel across agents**: Different agents have different locks
4. **Self-terminating**: Chain stops when queue is empty
5. **Idempotent**: Multiple processor jobs for same agent safely exit if one is already running
6. **Visible queue**: All queued tasks are in the database with status "queued"

## Verification

1. **Unit tests**: `docker compose exec web bundle exec rails test test/jobs/agent_queue_processor_job_test.rb`
2. **Integration tests**: `docker compose exec web bundle exec rails test test/services/notification_dispatcher_test.rb`
3. **Manual test**:
   - Enable subagents feature flag
   - Create a subagent, add to studio
   - Rapidly @mention the agent 3 times
   - Verify: 3 SubagentTaskRuns with "queued" status created
   - Verify: Tasks process one at a time (check `started_at` timestamps)
   - Verify: All 3 eventually complete
