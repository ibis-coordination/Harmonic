# Plan: Sys Admin Ops Improvements

## Context

Production troubleshooting of the agent-runner revealed gaps in admin tooling: no way to redispatch stuck tasks from the UI, no way to cancel tasks, and no visibility into system health (DB pool, Redis). These are operational tools for sys admins managing the infrastructure.

See also: [Safety Pipeline plan](safety-pipeline.md) for the security/moderation track.

## Features (in implementation order)

### 1. Redispatch queued tasks button (sys admin)

**What**: Button on `/system-admin/agent-runner` to re-dispatch tasks stuck in `queued` status. Mirrors `rake agent_runner:redispatch_queued` (see `lib/tasks/agent_runner.rake:7`).

**Files to modify**:
- `config/routes.rb` — add routes after line 213
- `app/controllers/system_admin_controller.rb` — add `execute_redispatch_queued_tasks`
- `app/views/system_admin/agent_runner.html.erb` — add button in the Recent Task Runs section

**Implementation**:
- Query: `AiAgentTaskRun.unscoped_for_admin(@current_user).where(status: "queued")`
- For each: set tenant scope via `Tenant.scope_thread_to_tenant`, call `AgentRunnerDispatchService.dispatch(task_run)` (class method, not instance — see `agent_runner_dispatch_service.rb:12`)
- Must call `Tenant.clear_thread_scope` in `ensure` block (match rake task pattern at `lib/tasks/agent_runner.rake:23`)
- Show count + confirmation before executing
- Flash result: "Redispatched X of Y tasks"

**Routes**:
```
post 'system-admin/agent-runner/actions/redispatch-queued' => 'system_admin#execute_redispatch_queued_tasks'
```

---

### 2. Cancel stuck task (sys admin)

**What**: Cancel button on `/system-admin/agent-runner/runs/:id` for tasks in `running` or `queued` status.

**Files to modify**:
- `config/routes.rb` — add route after line 213
- `app/controllers/system_admin_controller.rb` — add `execute_cancel_task_run`
- `app/views/system_admin/show_task_run.html.erb` — add cancel button (conditionally shown)

**Implementation**:
- Guard: only allow cancel when `status` is `running` or `queued`
- Update: `task_run.update!(status: "cancelled", completed_at: Time.current, error: "Cancelled by admin")`
- Call `task_run.notify_parent_automation_runs!` — if the task was triggered by an automation rule, the parent `AutomationRuleRun` needs to update its aggregate status (see `ai_agent_task_run.rb:114`)
- Delete any active API tokens for the task run context: `task_run.api_tokens.where(deleted_at: nil).find_each(&:delete!)`
- Log via `SecurityAuditLog.log_admin_action`
- Use `<details>` confirmation pattern (matches suspend button in show_user.html.erb)

**Routes**:
```
post 'system-admin/agent-runner/runs/:id/cancel' => 'system_admin#execute_cancel_task_run'
```

---

### 3. System health panel (sys admin dashboard)

**What**: Add DB connection pool and Redis memory stats to the sys admin dashboard.

**Files to modify**:
- `app/controllers/system_admin_controller.rb` — expand dashboard action
- `app/views/system_admin/dashboard.html.erb` — add health stats section

**Implementation**:
- DB pool: `ActiveRecord::Base.connection_pool.stat` -> size, connections, busy, waiting
- Redis memory: `redis.info("memory")["used_memory_human"]`
- Add as a new accordion section or expand the existing Resources card

---

## Verification

1. **Redispatch**: Create a stuck queued task (or use Rails console), click redispatch, verify it appears in Redis stream
2. **Cancel task**: Navigate to a running/queued task detail, click cancel, verify status updates
3. **Health panel**: Visit `/system-admin`, verify DB pool and Redis stats appear

Run targeted tests after each feature:
```bash
docker compose exec web bundle exec rails test test/controllers/system_admin_controller_test.rb
```
