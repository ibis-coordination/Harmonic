# Agent-Runner MCP Migration

Migrate the internal agent-runner ([agent-runner/](../../agent-runner/)) from its bespoke HTTP wrapper to the hosted `/mcp` endpoint as its tool transport. After this lands, internal and external agents share the same tool surface, and every internal-agent action lands in `McpToolCallLog` tied to its parent `AiAgentTaskRun` — closing the last gap in the Phase 1 audit guarantee.

The per-call resource attribution layer (`McpToolCallResource`) is in a separate, prior branch: [mcp-resource-attribution.md](mcp-resource-attribution.md). The dual-write semantics it sets up activate automatically once this migration ships.

## Scope

The runner makes two kinds of HTTP call to Rails. Only the first kind migrates.

**Agent acting** (migrates): `navigate(path)` → MCP `fetch_page`. `executeAction(path, action, params)` → MCP `execute_action`. Bearer-auth, goes through `ApplicationController#api_authorize!`.

**Service coordination** (stays): preflight, claim, step batches, scratchpad PUT, complete, chat-history fetch. HMAC-authed against `Internal::*`. Not "the agent acting" — runner ↔ Rails plumbing.

The split mirrors [docs/AGENT_RUNNER.md](../../docs/AGENT_RUNNER.md#two-types-of-http-request).

## What changes by stage

| Stage | Change |
|-------|--------|
| 1. Create internal agent | None |
| 2. Trigger task run | None — `ApiToken#context` already carries `AiAgentTaskRun`, which the MCP endpoint will read |
| 3. Pickup | None — HMAC paths |
| 4. Execution loop | Substantial — see below |
| 5. Finalize | None — HMAC paths |
| 6. Human views task run | Steps timeline learns two new step types |

### Stage 4 specifics

- **Tool definitions:** `getToolDefinitions()` switches from hardcoded `navigate`/`executeAction` to building from MCP `tools/list` (fetched once per task run). The LLM sees the same four tools (`fetch_page`, `execute_action`, `search`, `get_help`) an external Claude Desktop user sees.
- **Step-type rename:** narrow — only `"navigate" → "fetch_page"` and `"execute" → "execute_action"` in [agent_session_steps](../../app/models/agent_session_step.rb). The six loop-internal types (`think`, `done`, `error`, `security_warning`, `scratchpad_update`, `scratchpad_update_failed`) stay; they aren't tool calls.
- **`availableActions` from markdown frontmatter:** unchanged. MCP wraps the same markdown body; per-page action lists feed the next prompt iteration as today.
- **Audit log:** every `tools/call` writes an `McpToolCallLog` row stamped with `ai_agent_task_run_id` from `current_token.context_id`. Goal achieved.
- **Connection lifecycle:** stateless. One-shot `POST /mcp` per call, no `initialize` handshake, no session.
- **Linking step ↔ tool-call log:** new nullable `mcp_tool_call_log_id` FK on `agent_session_steps`. MCP `tools/call` response gains `_meta.harmonic.tool_call_log_id` (spec-allowed escape hatch); runner reads it and includes in the step payload. Powers a "view raw call" deep-link per step.
- **Prompt rewrite:** [PromptBuilder.ts](../../agent-runner/src/core/PromptBuilder.ts) and system prompts audited to use the new tool names.
- **Rate limits:** unchanged. Runner respects `Retry-After` (see below).
- **Chat history:** unchanged — HMAC internal endpoint.

## Backoff on 429

The MCP endpoint returns `429` with `Retry-After` when any rate-limit scope breaches. The runner:

1. Parses `Retry-After` (integer seconds), sleeps, retries the same call once.
2. If the retry also 429s, surfaces a tool error to the LLM.
3. Caps total backoff per task run (proposed default: 60 seconds; tune during implementation).
4. Logs each 429+backoff event so operators can see which scope is the binding constraint.

This keeps rate-limit policy uniform across internal and external agents.

## Steps

Each is independently shippable.

### Step B — Rails: stamp task-run FK on `McpToolCallLog`; expose log id in response

- Migration: `add_reference :mcp_tool_call_logs, :ai_agent_task_run, null: true, foreign_key: true`.
- `Mcp::EndpointController#record_tool_call_log!` sets the FK from `current_token.context_id` when `context_type == "AiAgentTaskRun"`.
- `tools/call` response (and error response) includes `_meta.harmonic.tool_call_log_id`.

Tests: FK set for internal-token calls, null for external; non-`AiAgentTaskRun` context_type → null (defensive); `_meta` field present on success and error.

### Step B' — Rails: link `AgentSessionStep` to `McpToolCallLog` (paired with Step B)

- Migration: `add_reference :agent_session_steps, :mcp_tool_call_log, null: true, foreign_key: true`.
- `Internal::AgentRunnerController#step` accepts optional `mcp_tool_call_log_id` per step item; validates the referenced log row belongs to the same task run before writing.

Tests: FK populated when payload includes it; null when omitted; cross-task-run reference → 422.

### Step C — Agent-runner: Retry-After backoff infrastructure

Lands ahead of Step D so the migration doesn't bundle transport + retry logic in one PR.

- `withRetryAfter` wrapper around the existing request paths.
- Per-task budget tracked in `AgentContext`.

Tests: 429-then-success; 429-then-429; budget exhausted.

### Step D — Agent-runner: replace `HarmonicClient` with MCP SDK

- Add `@modelcontextprotocol/sdk`. New `McpClient` service replaces `HarmonicClient` for agent-acting calls only (`fetchChatHistory` stays on HMAC).
- One-shot `POST /mcp` per call: `Authorization: Bearer …`, `MCP-Protocol-Version: 2025-11-25`. No session.
- Unwrap MCP response to the same `{ content, availableActions, resolvedPath }` shape the loop already consumes.
- Wire Step C's wrapper around MCP calls.

Tests: `fetchPage` and `executeAction` happy paths; 429 surfaces through the wrapper; revoked token → clean auth error; chat history still uses HMAC.

### Step E — Agent-runner: prompts, step types, log id propagation

- `PromptBuilder.ts`: replace `navigate`/`executeAction` references with the new names.
- `getToolDefinitions()` builds from MCP `tools/list` at loop start.
- `StepBuilder.ts` emits `fetch_page` and `execute_action` step types (the only renames).
- `ActionParser.ts` parses the new tool names from LLM output.
- After each MCP call, read `_meta.harmonic.tool_call_log_id` from the response and include it in the step payload.

Tests: each renamed step type emitted correctly and FK populated; legacy types unchanged; missing `_meta` → step still written, FK null; prompt builder references new tool names.

### Step F — View: steps timeline learns new step types

- [show_run.html.erb](../../app/views/ai_agents/show_run.html.erb) partial renders `fetch_page` and `execute_action` alongside legacy `navigate`/`execute` (old runs keep their original strings until retention ages them out).

### Step G — Flip `create_internal_token` default to `mcp_only: true`

Timing open — same PR as Step D, or a follow-up release. Same-PR is cleaner if the "internal token blocked on direct endpoint" test is solid; follow-up adds a soak window in case a non-MCP code path that depends on internal tokens has been overlooked.

- `ApiToken.create_internal_token` defaults `mcp_only: true`.
- Verify `AutomationInternalActionService` still works (dispatches through `MarkdownUiService` → `harmonic.internal_dispatch` env flag is set → enforcement passes).

Tests: internal token against a direct non-MCP endpoint → 403; internal token against `/mcp` → 200; automation path unaffected.

### Step H — (later) Deprecate `AiAgentTaskRunResource`

Out of scope for this branch. Switch read paths to `McpToolCallResource`, backfill if needed, drop dual-write, drop table.

## Cross-cutting

- **Token destruction at completion** ([agent_runner_controller.rb:115](../../app/controllers/internal/agent_runner_controller.rb#L115)) still happens. In-flight MCP calls on a destroyed token will 401 cleanly — worth one test.
- **Latency**: per-call cost gains a small JSON-RPC envelope. SDK keepalive amortizes TLS. Measure p50/p99 before and after Step D.
- **Audit log filtering**: external vs internal MCP calls share the same row shape. `ai_agent_task_run_id IS NULL` discriminates.

## Open questions

- Step G timing — same PR as Step D, or follow-up release?

## Out of scope

- `McpToolCallResource` table itself ([mcp-resource-attribution.md](mcp-resource-attribution.md)).
- `AiAgentTaskRunResource` deprecation (Step H).
- Runner Redis pickup, LLM-loop logic, token encryption changes.
- Per-collective token scopes (deferred to Phase 2).
- Connection-level audit (`initialize`/`ping`/`tools/list`).

## Verify at kickoff

- `ApiToken#context` polymorphic association supports `AiAgentTaskRun` — confirm column types before relying on them.
- `@modelcontextprotocol/sdk` supports stateless one-shot `tools/call` without a long-lived client — quick spike before Step D.
