# Migrate Thread.current to ActiveSupport::CurrentAttributes

## Status

**Not started.** Follow-up work after the agent-runner migration (see
[agent-runner-service.md](agent-runner-service.md)) is complete and stable.

## Why

Harmonic has ~41 direct `Thread.current[:...]` reads/writes across 6 files. The
pattern is "implicit ambient state passed through the call stack," which is
exactly what `ActiveSupport::CurrentAttributes` is designed to replace — but
with safety rails that raw thread-locals don't provide.

The immediate trigger: on 2026-04-16 we found that `AutomationContext`'s
chain tracking leaks across HTTP requests because Puma reuses threads and
nothing cleared the state at request boundaries. The fix
([commit 96dbbe6](../../app/controllers/application_controller.rb)) adds a
`before_action { AutomationContext.clear_chain! }`. That's the one-off patch.
The pattern is the bug.

`Tenant.current_id` / `Collective.current_id` have the same shape and would
be similarly vulnerable, but are masked by the fact that every request
re-assigns them via `scope_thread_to_tenant`. If we ever get a code path that
reads tenant scope without going through that setter (e.g., a new background
path, a Rack middleware that runs before `ApplicationController`), the bug
resurfaces silently and corrupts data across tenants.

`ActiveSupport::CurrentAttributes` auto-resets around every HTTP request
(`ActionDispatch::Executor` middleware) and every ActiveJob execution
(built-in executor wrap), eliminating the whole class of leak bugs.

## Non-goals

- Changing any tenant-scoping **semantics**. This is a mechanical swap of the
  backing store with the same external API (`Tenant.current_id`,
  `Collective.current_id`, `AiAgentTaskRun.current_id`,
  `AutomationContext.current_run_id`, etc.).
- Changing when scope is set/cleared at controller or job boundaries.
- Touching how the automation chain is serialized across job boundaries
  (still `chain_to_hash` / `restore_chain!`).

## Scope: every `Thread.current[:...]` usage today

All 41 call sites fall into 5 groups:

| Group | Keys | Setter surface | Files |
|-------|------|----------------|-------|
| Tenant scope | `tenant_id`, `tenant_subdomain`, `main_collective_id` | `Tenant.scope_thread_to_tenant`, `Tenant.clear_thread_scope` | `app/models/tenant.rb` |
| Collective scope | `collective_id`, `collective_handle` | `Collective.scope_thread_to_collective`, `Collective.clear_thread_scope` | `app/models/collective.rb` |
| Task run tracking | `ai_agent_task_run_id` | `AiAgentTaskRun.current_id=` | `app/models/ai_agent_task_run.rb` |
| Automation context | `automation_rule_run_id`, `automation_chain` | `AutomationContext.*` | `app/models/concerns/automation_context.rb` |
| Tests | `simulate_production` | direct assign in specs | `app/controllers/tenant_admin_controller.rb` (read), tests (write) |

Additionally, `app/jobs/application_job.rb` reads and writes all of these
when snapshotting/restoring thread state around job execution.

## Target design

One `ApplicationCurrent` class (or a small number of grouped ones) defined
with `ActiveSupport::CurrentAttributes`. Example:

```ruby
# app/models/current.rb
class Current < ActiveSupport::CurrentAttributes
  attribute :tenant_id, :tenant_subdomain, :main_collective_id
  attribute :collective_id, :collective_handle
  attribute :ai_agent_task_run_id
  attribute :automation_rule_run_id, :automation_chain
end
```

Existing public APIs (`Tenant.current_id`, `AutomationContext.current_run_id`,
etc.) stay — they just delegate to `Current.tenant_id`, `Current.run_id`, etc.
Internal call sites that read `Thread.current[:...]` directly are rewritten
to read `Current.<attr>`.

## Phased implementation

### Phase A: Automation (lowest-risk, highest-leverage)

Migrate `AutomationContext` first. It's the one that bit us, it's fully
self-contained, and it's the easiest to test.

- [ ] Add `Current` class with `automation_rule_run_id` and `automation_chain`
  attributes.
- [ ] Replace `Thread.current[:automation_*]` reads/writes in
  `automation_context.rb` with `Current.<attr>`.
- [ ] Keep the `AutomationContext.clear_chain!` method (now a no-op thanks to
  executor-driven reset, but callers like `AutomationRuleExecutionJob` still
  call it — leave the method body empty with a comment, or delete callers too).
- [ ] Remove the `before_action { AutomationContext.clear_chain! }` from
  `ApplicationController` — executor reset now handles it.
- [ ] Test: the integration test in
  `test/integration/application_controller_thread_state_test.rb` should still
  pass (now exercising the executor boundary instead of the before_action).
- [ ] Add a test that verifies the state also resets around an
  `ActiveJob.perform_now` invocation.

### Phase B: Task run tracking

- [ ] Add `ai_agent_task_run_id` to `Current`.
- [ ] Rewrite `AiAgentTaskRun.current_id` / `=` / `clear_thread_scope` to
  delegate to `Current`.
- [ ] Sweep tests that poke `Thread.current[:ai_agent_task_run_id]` directly —
  replace with `AiAgentTaskRun.current_id = id`.
- [ ] Keep `api_helper.rb`'s token-first / thread-local-fallback logic; it
  already uses the `AiAgentTaskRun.current_id` accessor, so no change.

### Phase C: Tenant and Collective scope (load-bearing, treat with care)

This is the big one. Every ActiveRecord query goes through `default_scope`
which reads these values.

- [ ] Add `tenant_id`, `tenant_subdomain`, `main_collective_id`,
  `collective_id`, `collective_handle` to `Current`.
- [ ] Rewrite `Tenant.scope_thread_to_tenant`, `Tenant.clear_thread_scope`,
  the three `current_*` accessors on `Tenant`, and the corresponding
  methods on `Collective` to delegate to `Current`.
- [ ] Rewrite `ApplicationJob.around_perform` snapshot/restore logic:
  instead of 7 lines of `Thread.current[...] = saved[...]`, use
  `Current.set(attrs) { ... }` which is the CurrentAttributes equivalent.
- [ ] **Verification gate:** run the full test suite before merging. This is
  the one place where a subtle regression could leak data across tenants.

### Phase D: Clean up

- [ ] Grep for any remaining `Thread.current[:...]` and convert.
- [ ] Delete `clear_thread_scope` methods if they're no-ops after migration
  (or keep as aliases for backward compat, then delete in a later pass).
- [ ] Delete the manual `before_action { AutomationContext.clear_chain! }`.
- [ ] Decide what to do with `Thread.current[:simulate_production]` —
  it's test-only and probably should remain raw thread-local or move to
  a `Current.test_overrides` attribute.

## Risks and mitigations

| Risk | Mitigation |
|------|-----------|
| Auto-reset fires at an unexpected moment (e.g., mid-request during rescue) | Rails' executor wraps the full request lifecycle; only a raw Rack middleware ordered **before** `ActionDispatch::Executor` would see state without reset. None exist in Harmonic. Verify `bin/rails middleware` output pre-merge. |
| Tenant scope missing during a background path that doesn't go through `ApplicationJob` | Same risk exists today with raw thread-locals. Migration doesn't make it worse; fixing it means ensuring every entry point sets tenant context. |
| Fiber-spawning code reads stale value | `CurrentAttributes` is fiber-aware in Rails 7.1+. Harmonic uses plain `async`/threads sparingly; audit during Phase C. |
| Tests poking `Thread.current[:...]` directly break | Phase B & C sweep. Grep `test/` for `Thread.current` before merging each phase. |
| ActiveJob adapter differences (Sidekiq, :test) | All adapters go through ActiveJob's executor, so reset fires consistently. Verified against Sidekiq docs; `:test` adapter also wraps in executor. |

## Testing strategy

- Every phase keeps the same external API, so existing tests exercise the
  behavior. No test should need to change semantically.
- Add a **leak regression test per phase**: seed a `Current.<attr>`, make a
  new HTTP request or job invocation, assert the attr is nil at the start.
  Pattern already exists in
  `test/integration/application_controller_thread_state_test.rb`.
- Phase C specifically: add a multi-tenant integration test that verifies
  a request scoped to tenant A cannot see tenant B's records after a request
  boundary, even if tenant B's ID was the last value set by any previous code
  path in the same worker.

## Estimated effort

- Phase A: 1-2 hours (small file, isolated).
- Phase B: 1-2 hours.
- Phase C: 1 day — small code change, but needs careful review plus full
  test suite run plus local exploratory testing against the multi-tenant
  dev setup.
- Phase D: 30 minutes.

Total: one focused day for a senior engineer, or two split days with
review gates between phases.

## Out of scope

- Replacing `Tenant.scope_thread_to_tenant` with an entirely different
  tenant-resolution API (e.g., explicit tenant-aware query scopes). That's a
  different conversation about multi-tenancy design.
- Moving away from `default_scope` for tenant filtering. Also a different
  conversation.
- Anything touching the agent-runner TypeScript service.
