# Stage 3 — Agent sessions

> Depends on Stages 1–2 (the `context` block exists). The invasive stage: rename `AiAgentTaskRun` → `AgentSession`, then add the required, validated `agent_session_id` gate — an internal **knowledge test** and a new **external session lifecycle**. Shared concepts in the [overview](action-context-overview.md).

## Part A — Rename `AiAgentTaskRun` → `AgentSession`

Pure refactor, no behavior change (1:1 — same table, one session per task; the existing `agent_session_step` children then read as `AgentSession has_many :agent_session_steps`). Rename: model, table, FKs (`McpToolCallLog.ai_agent_task_run_id`, the resource-attribution rows), thread-locals (`Current.ai_agent_task_run_id`), internal routes (`/internal/agent-runner/tasks/...`), and "task run" terminology in docs/UI. Ship this first within the stage so Part B doesn't rebase over the sweep.

*Done:* no `AiAgentTaskRun` references remain; tests green.

## Part B — `agent_session_id` gate

Add `agent_session_id` as a required, validated field on every agent write. Same protocol for internal and external agents; only *who creates the session* differs.

### Internal agents — knowledge test

The session is created at dispatch (today's flow) and its id (`task_run_id`) already rides in the Redis payload and is bound to the ephemeral token's context ([agent_runner_dispatch_service.rb]). The agent-runner injects the id into the agent's prompt; the agent echoes it in `context.agent_session_id` on every write. The server compares the declared id to the **token-bound** session and **hard-fails on mismatch** — the step loop self-corrects. (Round-tripping through trusted infra proves nothing about infra, but it proves the *agent* tracks continuity.)

### External agents — session lifecycle

No token-bound session, so the agent calls `start_session` to obtain an id, then threads it. Ground truth is the looked-up `AgentSession`, checked for ownership and openness.

- **Lifecycle mirrors `RepresentationSession`:** fixed expiry window (24h baseline) + explicit `end_session`, expiry checked on read. Reuse the proven pattern; don't invent one.
- **No chicken-and-egg:** `start_session` / `end_session` are their own MCP tools, *not* `execute_action` actions, so they never carry `context` (hence never need an `agent_session_id`) — there's nothing to bootstrap. Same reason the read tools (`fetch_page`/`search`/`get_help`) are unaffected.

## Lifecycle nesting (now relevant)

Once agent sessions exist, every agent write — including `start_representation` — happens *inside* a session. **Ending or expiring an `AgentSession` must end any representation it opened** (the Stage 2 rep sessions), or we orphan an active `effective_user` swap. An agent-opened representation cannot outlive its agent session.

## Error contract (Stage 3 additions)

| Code | When |
|---|---|
| `session_missing` | required but absent (non-exempt write) |
| `session_unknown` | no such session |
| `session_closed` | ended or expired |
| `session_forbidden` | session not owned by this caller |
| `session_mismatch` | internal: declared id ≠ token-bound session |

## Cross-service (critical — unflagged strict)

No kill switch. The **agent-runner** must inject the session id into the prompt and emit `agent_session_id` on every write in the *same release*, or all internal agents break. External MCP clients must adopt `start_session` + threading. Ship Rails + agent-runner together.

## Tasks (red-green TDD)

1. **Part A:** the rename sweep; green tests; no stale references.
2. `agent_session_id` required on non-exempt agent writes; `session_missing`.
3. Internal: compare declared id vs. token-bound session; `session_mismatch` hard-fail.
4. External: `start_session` / `end_session` tools; lifecycle (expiry + explicit close, openness on read); ownership/openness gate.
5. Expose `start_session` / `end_session` as their own MCP tools (not `execute_action` actions), so they carry no `context`.
6. Lifecycle nesting: session close/expire ends its representations.
7. Schema + frontmatter + help updates.
8. **agent-runner + system prompt:** inject + emit the session id (cross-repo).

## Done when

- Internal agents are rejected on a wrong/absent `agent_session_id` (`session_mismatch` / `session_missing`).
- External agents can `start_session`, thread it, and `end_session`; foreign/closed/expired ids reject.
- Ending an agent session ends any representation it opened.
- agent-runner injects + emits the id; internal agents pass end-to-end.

## Open (Stage 3)

- Exact external-session TTL value.
- Whether task-shape fields (`max_steps`, `success`, `final_message`) apply to external sessions or stay null — i.e. whether external is a distinct `mode` on the same table.
