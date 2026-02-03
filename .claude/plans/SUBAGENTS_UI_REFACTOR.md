# Subagents UI Refactor Plan

## Goal

Refactor the agent testing UI from a development-only feature to a user-facing subagents management and task execution interface. Replace `/agent-test` with `/subagents`.

## Requirements

1. **`/subagents` path** - Show all subagents for the current user (similar to subagents section in user settings)
2. **"Run Task" link** - Each subagent card should link to `/subagents/:handle`
3. **`/subagents/:handle` path** - Task runner UI similar to `/agent-test` but:
   - Agent is pre-selected based on URL handle (no agent dropdown)
   - No "Starting studio" field (use current studio context)
   - Keep task textarea and max steps
4. **Remove `/agent-test`** - Delete the old route and controller
5. **User dropdown navigation** - Add "Subagents" link to user menu

## Current Implementation Analysis

### Agent Test UI (`/agent-test`)
- **Controller**: `AgentTestController` with `index` and `run` actions
- **Views**: `app/views/agent_test/index.html.erb` (form) and `result.html.erb` (results)
- **Features**: Task input, starting studio dropdown, agent selection dropdown, max steps
- **Backend**: Uses `AgentNavigator.run(task:, max_steps:)`

### Subagents in User Settings
- **Location**: `app/views/users/settings.html.erb` (lines 182-260)
- **Style**: Accordion with card layout (`.pulse-subagent-card`)
- **Data**: Loaded via `UsersController#settings` - `@subagents = @settings_user.subagents`
- **Actions**: Impersonate, Settings, Add/Remove from studios

---

## Implementation Plan

### Phase 1: Routes

**File**: `config/routes.rb`

Add top-level subagents routes (outside user scope):

```ruby
# Subagent task runner (user-facing)
resources :subagents, only: [:index] do
  member do
    get :run_task
    post :execute_task
  end
end
```

### Phase 2: Controller

**File**: `app/controllers/subagents_controller.rb`

Extend the existing controller with new actions:

```ruby
# GET /subagents - List all subagents owned by current user
def index
  @page_title = "My Subagents"
  @subagents = current_user.subagents
    .includes(:tenant_users, :superagent_members)
    .where(tenant_users: { tenant_id: current_tenant.id })
end

# GET /subagents/:handle/run_task - Show task form for specific subagent
def run_task
  @page_title = "Run Task"
  @subagent = find_subagent_by_handle
  @max_steps_default = 15
end

# POST /subagents/:handle/execute_task - Execute the task
def execute_task
  @subagent = find_subagent_by_handle

  navigator = AgentNavigator.new(
    user: @subagent,
    tenant: current_tenant,
    superagent: current_superagent
  )

  @result = navigator.run(
    task: params[:task],
    max_steps: (params[:max_steps] || 15).to_i
  )

  render :result
end

private

def find_subagent_by_handle
  current_user.subagents
    .joins(:tenant_users)
    .where(tenant_users: { tenant_id: current_tenant.id })
    .find_by!(handle: params[:id])
end
```

### Phase 3: Views

#### 3.1 Index View
**File**: `app/views/subagents/index.html.erb`

Display subagent cards with "Run Task" button:
- Reuse `.pulse-subagent-card` styling from user settings
- Show subagent name, avatar, creation date
- Show studio memberships
- Add "Run Task" button linking to `/subagents/:handle/run_task`
- Add "Create Subagent" link at bottom

#### 3.2 Run Task View
**File**: `app/views/subagents/run_task.html.erb`

Simplified version of agent-test index:
- Header showing which subagent will run the task
- Task textarea (required)
- Max steps input (default 15)
- Submit button
- No agent dropdown (pre-selected)
- No starting studio dropdown (uses current context)

#### 3.3 Result View
**File**: `app/views/subagents/result.html.erb`

Copy from `agent_test/result.html.erb`:
- Breadcrumb: Home > Subagents > [Agent Name] > Result
- Success/failure status
- Execution steps timeline
- Link to run another task

### Phase 4: Navigation

Add "Subagents" link to the user dropdown menu.

**File**: `app/views/layouts/_top_right_menu.html.erb`

Add between Settings and Admin links (around line 46):
```erb
<li>
  <%= octicon 'diamond' %>
  <a href="/subagents">Subagents</a>
</li>
```

### Phase 5: Remove Agent Test

Delete the old `/agent-test` UI:
- Remove routes from `config/routes.rb`
- Delete `app/controllers/agent_test_controller.rb`
- Delete `app/views/agent_test/` directory

---

## Critical Files

| File | Action |
|------|--------|
| `config/routes.rb` | Add new routes, remove agent-test routes |
| `app/controllers/subagents_controller.rb` | Add index, run_task, execute_task actions |
| `app/views/subagents/index.html.erb` | Create - subagent listing |
| `app/views/subagents/run_task.html.erb` | Create - task form |
| `app/views/subagents/result.html.erb` | Create - execution results |
| `app/views/layouts/_top_right_menu.html.erb` | Add Subagents link |
| `app/controllers/agent_test_controller.rb` | Delete |
| `app/views/agent_test/` | Delete directory |
| `db/migrate/xxx_create_subagent_task_runs.rb` | Create - migration for task runs table |
| `app/models/subagent_task_run.rb` | Create - model for persisted task runs |
| `app/views/subagents/runs.html.erb` | Create - task run history list view |
| `app/views/subagents/show_run.html.erb` | Create - individual task run detail view |

---

## Phase 6: Persist Task Runs

Record subagent task runs in the database so they are not ephemeral.

### Data Model

**Table**: `subagent_task_runs`

| Column | Type | Description |
|--------|------|-------------|
| `id` | uuid | Primary key |
| `tenant_id` | uuid | Foreign key to tenants (for multi-tenancy) |
| `subagent_id` | uuid | Foreign key to users (the subagent) |
| `initiated_by_id` | uuid | Foreign key to users (person who initiated the run) |
| `task` | text | The task description provided by the user |
| `max_steps` | integer | Maximum steps allowed for the run |
| `status` | string | `pending`, `running`, `completed`, `failed`, `cancelled` |
| `success` | boolean | Whether the task completed successfully (null while running) |
| `final_message` | text | The agent's final response message |
| `error` | text | Error message if the task failed |
| `steps_count` | integer | Number of steps executed |
| `steps_data` | jsonb | Array of step details (type, detail, timestamp) |
| `started_at` | datetime | When execution began |
| `completed_at` | datetime | When execution finished |
| `created_at` | datetime | Record creation time |
| `updated_at` | datetime | Record update time |

### Migration

```ruby
class CreateSubagentTaskRuns < ActiveRecord::Migration[7.0]
  def change
    create_table :subagent_task_runs, id: :uuid do |t|
      t.references :tenant, null: false, foreign_key: true, type: :uuid
      t.references :subagent, null: false, foreign_key: { to_table: :users }, type: :uuid
      t.references :initiated_by, null: false, foreign_key: { to_table: :users }, type: :uuid

      t.text :task, null: false
      t.integer :max_steps, null: false, default: 15
      t.string :status, null: false, default: 'pending'
      t.boolean :success
      t.text :final_message
      t.text :error
      t.integer :steps_count, default: 0
      t.jsonb :steps_data, default: []

      t.datetime :started_at
      t.datetime :completed_at
      t.timestamps
    end

    add_index :subagent_task_runs, [:tenant_id, :subagent_id]
    add_index :subagent_task_runs, [:tenant_id, :initiated_by_id]
    add_index :subagent_task_runs, :status
  end
end
```

### Model

**File**: `app/models/subagent_task_run.rb`

```ruby
class SubagentTaskRun < ApplicationRecord
  belongs_to :tenant
  belongs_to :subagent, class_name: 'User'
  belongs_to :initiated_by, class_name: 'User'

  validates :task, presence: true
  validates :max_steps, presence: true, numericality: { greater_than: 0, less_than_or_equal_to: 50 }
  validates :status, presence: true, inclusion: { in: %w[pending running completed failed cancelled] }

  scope :recent, -> { order(created_at: :desc) }
  scope :for_subagent, ->(subagent) { where(subagent: subagent) }

  def running?
    status == 'running'
  end

  def completed?
    status == 'completed'
  end

  def failed?
    status == 'failed'
  end

  def duration
    return nil unless started_at && completed_at
    completed_at - started_at
  end
end
```

### Controller Updates

Update `execute_task` to persist the run:

```ruby
def execute_task
  # ... authorization checks ...

  @task_run = SubagentTaskRun.create!(
    tenant: current_tenant,
    subagent: @subagent,
    initiated_by: current_user,
    task: params[:task],
    max_steps: (params[:max_steps] || 15).to_i,
    status: 'running',
    started_at: Time.current
  )

  navigator = AgentNavigator.new(
    user: @subagent,
    tenant: current_tenant,
    superagent: current_superagent
  )

  @result = navigator.run(
    task: params[:task],
    max_steps: @task_run.max_steps
  )

  @task_run.update!(
    status: @result.success ? 'completed' : 'failed',
    success: @result.success,
    final_message: @result.final_message,
    error: @result.error,
    steps_count: @result.steps.count,
    steps_data: @result.steps.map { |s| { type: s.type, detail: s.detail, timestamp: s.timestamp.iso8601 } },
    completed_at: Time.current
  )

  render :result
end
```

### Routes

Add routes for task run history and individual run details:

```ruby
# In config/routes.rb
get 'subagents/:handle/runs' => 'subagents#runs', as: 'subagent_runs'
get 'subagents/:handle/runs/:run_id' => 'subagents#show_run', as: 'subagent_run'
```

### Controller Actions

```ruby
# GET /subagents/:handle/runs - List past task runs
def runs
  @subagent = find_subagent_by_handle
  return render status: 404, plain: '404 Not Found' unless @subagent

  @page_title = "Task Runs - #{@subagent.display_name}"
  @task_runs = SubagentTaskRun.where(subagent: @subagent).recent
end

# GET /subagents/:handle/runs/:run_id - Show a specific task run
def show_run
  @subagent = find_subagent_by_handle
  return render status: 404, plain: '404 Not Found' unless @subagent

  @task_run = SubagentTaskRun.find_by(id: params[:run_id], subagent: @subagent)
  return render status: 404, plain: '404 Not Found' unless @task_run

  @page_title = "Task Run - #{@subagent.display_name}"
end
```

Update `execute_task` to redirect to the show_run page:

```ruby
def execute_task
  # ... authorization checks and task run creation ...

  # After running the task and updating @task_run:
  redirect_to subagent_run_path(@subagent.handle, @task_run.id)
end
```

### Views for Task Run History

- **`/subagents/:handle/runs`** - List of past task runs for a subagent
  - Each run shows: task summary, status, timestamp, duration, step count
  - Click to view full details of a past run
- **`/subagents/:handle/runs/:run_id`** - Show a specific task run
  - Same content as current result.html.erb but loads from database
  - Form submission redirects here after execution

---

## Verification

1. Navigate to `/subagents` - should see list of current user's subagents
2. Click "Run Task" on a subagent - should go to `/subagents/:handle/run`
3. Enter a task and submit - should execute and redirect to `/subagents/:handle/runs/:run_id`
4. Run detail page should show execution steps timeline
5. Ensure non-owner cannot access another user's subagent task runner
6. User dropdown menu should show "Subagents" link
7. `/agent-test` should return 404
8. Task runs are persisted in `subagent_task_runs` table
9. Task run history is viewable at `/subagents/:handle/runs`
10. Individual task runs are viewable at `/subagents/:handle/runs/:run_id`
