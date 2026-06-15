# MCP Resource Attribution

Extend the audit chain one grain deeper than Phase 1: record which resources each MCP tool call creates or touches. Today an external Claude Desktop user calling `execute_action create_note` produces an `McpToolCallLog` row but no attribution of the resulting `Note`. After this lands, every resource an MCP call affects has an `McpToolCallResource` row linking it back.

Independent of the agent-runner migration ([agent-runner-mcp-migration.md](agent-runner-mcp-migration.md)). Ships first because (a) it's the data layer for the Phase 2 principal-review UI, (b) the gap exists for external agents in production today, (c) the dual-write semantics activate automatically when the runner migration later routes internal agents through `/mcp`.

The existing [AiAgentTaskRunResource](../../app/models/ai_agent_task_run_resource.rb) — written by `track_task_run_resource` ([api_helper.rb:1273](../../app/services/api_helper.rb#L1273)) for requests with an `AiAgentTaskRun` context — coexists until Step H of the runner-migration plan deprecates it.

## Table

`mcp_tool_call_resources`:

| Column | Notes |
|--------|-------|
| `mcp_tool_call_log_id` | FK, not null, indexed |
| `tenant_id` | FK, not null |
| `resource_type` + `resource_id` | polymorphic, joint index |
| `resource_collective_id` | FK, nullable; resource's home collective (may differ from request's current collective) |
| `action_name` | Literal action name as invoked via `execute_action` (`create_note`, `confirm_read`, `add_options`, etc.). Renamed from `AiAgentTaskRunResource.action_type` — the old column stores abbreviated kinds (`"create"` for any creation), the new one stores the full name. Old table is being deprecated, so no cleanup of the old convention. |
| `display_path` | precomputed; same helper as `AiAgentTaskRunResource` |
| `created_at` | |

No `success` column — failed actions don't write rows (matches `AiAgentTaskRunResource`). Composite index `[mcp_tool_call_log_id, created_at]` plus the polymorphic pair.

## Mechanism

Same shape as the existing task-run-resource flow: the FK target exists before the action runs, deep code reads it from request-scoped state, resource rows are written immediately.

Two adjustments to Phase 1's existing log-row code:

- **Split `McpToolCallLog` write into create-then-update.** Insert at the start of `tools/call` handling with `status: "pending"`. Update with final `status` + `duration_ms` after dispatch returns (or in a rescue). Two queries per call instead of one, but the update is PK-keyed.
- **Add `"pending"` to `STATUSES`.** Represents the in-flight state. Side benefit: orphaned `"pending"` rows older than N seconds become a useful operator signal — they mean a process was killed mid-dispatch, which Phase 1 silently dropped.

Sketch:

```ruby
# Mcp::EndpointController, tools/call handler
log = McpToolCallLog.create!(
  tool_name:, args: redacted_args, status: "pending",
  request_id:, tenant:, user:, api_token:, ai_agent_task_run_id: ...,
)
Current.mcp_tool_call_log_id = log.id
started = monotonic_now
begin
  result = dispatch(...)
  log.update!(status: "ok", duration_ms: elapsed(started))
  result
rescue => e
  log.update!(status: "tool_error", duration_ms: elapsed(started))
  raise
end
# Current auto-resets between requests via ActionDispatch::Executor — no explicit clear.
```

```ruby
# api_helper.rb#track_task_run_resource
def track_task_run_resource(resource, action_name)
  if AiAgentTaskRun.current_id
    write_ai_agent_task_run_resource(...)  # existing, unchanged
  end
  if Current.mcp_tool_call_log_id
    McpToolCallResource.create!(
      mcp_tool_call_log_id: Current.mcp_tool_call_log_id,
      tenant: Tenant.current_id, resource:, action_name:,
      resource_collective_id: resource.collective_id,
      display_path: compute_display_path(resource),
    )
  end
rescue => e
  Rails.logger.error("Resource attribution failed: #{e.message}")
end
```

Properties:

- **Errors in attribution are rescued, logged, and swallowed.** A failed attribution write must never break the user's action. Same posture as the existing helper.
- **`Current` resets automatically.** [Current](../../app/models/current.rb) is `ActiveSupport::CurrentAttributes`; Rails clears it between requests via `ActionDispatch::Executor`. No manual lifecycle to manage.
- **No nesting.** No MCP-within-MCP path exists today.

Add `mcp_tool_call_log_id` to [Current](../../app/models/current.rb) alongside the existing attributes.

Resulting behavior:

| Call shape | `AiAgentTaskRunResource` | `McpToolCallResource` |
|------------|--------------------------|------------------------|
| External MCP call | — | ✓ |
| Internal agent direct HTTP (today) | ✓ | — |
| Internal agent via `/mcp` (post-runner-migration) | ✓ | ✓ |
| Direct REST with task-run context | ✓ | — |
| Direct REST without task-run context | — | — |

## Steps

### Step 1 — Table + model + association

- Migration as above.
- `McpToolCallResource`: `belongs_to :mcp_tool_call_log`, `belongs_to :tenant`, polymorphic `:resource` (optional, so view code stays graceful when a soft-deleted target returns nil), optional `:resource_collective`.
- `McpToolCallLog has_many :mcp_tool_call_resources`.
- Query conveniences mirroring `AiAgentTaskRunResource`: `for_resource(record)`, `touched_by_log(log)`.

Tests: model validations, polymorphic resolution, tenant scoping, FK constraint, query scopes.

### Step 2 — Log-row lifecycle + `Current` attribute

- Add `"pending"` to `McpToolCallLog::STATUSES`.
- Add `:mcp_tool_call_log_id` to [Current](../../app/models/current.rb).
- Refactor `Mcp::EndpointController` `tools/call` handler: create log row at start (status `"pending"`), set `Current.mcp_tool_call_log_id`, dispatch, update row with final `status` + `duration_ms`. Rescue path also updates with appropriate status.

Tests: log row exists during dispatch; `Current.mcp_tool_call_log_id` set; row's status transitions `"pending"` → `"ok"` on success and `"pending"` → `"tool_error"` on raise; orphaned `"pending"` rows recognizable.

### Step 3 — Helper extension

- `track_task_run_resource` writes an `McpToolCallResource` row when `Current.mcp_tool_call_log_id` is set, on top of its existing `AiAgentTaskRunResource` write.
- Rescue around the new write so attribution failures don't break user actions.

Tests: each row of the behavior table above. Resource-less action → no rows. Caller outside a request → behaves as today. **Single MCP call touching N resources → N `McpToolCallResource` rows sharing the same `mcp_tool_call_log_id`.** Attribution write failure → logged, user action still succeeds.

## Out of scope

- Deprecating `AiAgentTaskRunResource` (after dual-write soaks; tracked in the runner-migration plan).
- UI for browsing the new table (Phase 2 principal-review UI).
- Backfilling historical attribution for external MCP traffic since Phase 1 shipped.
- Per-resource backlink UI for external-agent creations. Today `AuthorComponent` and `CommentComponent` render a "Created by AI Agent Task Run #X" link via `AiAgentTaskRunResource.task_run_for(resource)`. Internal-agent links keep working unchanged after this branch (dual-write keeps the existing path populated); external-agent creations resolve to nil and silently render no link until Phase 2 ships a per-tool-call detail page.
- Retention — rides along with `McpToolCallLog` ([mcp-audit-log-retention.md](mcp-audit-log-retention.md)).
