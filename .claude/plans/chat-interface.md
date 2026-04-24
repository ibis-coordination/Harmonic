# Chat Interface: Human-AI Agent Conversations

## Context

Today, AI agent tasks are fire-and-forget: the human submits a prompt, the agent-runner executes autonomously, and the human sees results after. This plan adds a **real-time chat interface** where a human and an AI agent can have a true back-and-forth conversation.

Before building chat, we first refactor the existing task run infrastructure to store steps as individual database rows instead of a JSONB array. This unifies the data model so chat becomes a natural extension of tasks rather than a parallel system.

---

## Part A: Refactor Task Run Steps into Individual Records ✅

**Status: Complete** (committed as `a79a9b3`)

- Created `agent_session_steps` table with `position`, `step_type`, `sender_id`, `tenant_id`, `detail` (JSONB)
- Dual-write: internal API writes to both rows and JSON during transition
- Views/JSON endpoints read from rows with fallback to JSON for older runs
- Backfill migration for all existing task runs
- Full type signatures on `AiAgentTaskRun`, Sorbet RBIs generated
- 65 tests, 0 Sorbet errors

---

## Part B: Add Chat Mode ✅

### Core insight: each turn is a short-lived task

Each human message triggers a **new short-lived task dispatch**. The conversation history lives in the database (`agent_session_steps` rows), not in agent-runner memory. The agent-runner is stateless between turns — sessions survive process restarts with no resources held while idle.

### What's built

**Models** (committed as `ea9e397`):
- `ChatSession` — groups turns into a conversation, tenant-scoped (no collective scoping — agents navigate across collectives)
- `mode` column on `AiAgentTaskRun` (`task` | `chat_turn`)
- `chat_session_id` FK on `AiAgentTaskRun`
- Single `message` step type with `sender_id` (generalizable to human-to-human chat in the future)

**Controller (`AiAgentChatsController`):**
- `index` — lists all chat sessions for an agent
- `show` — renders chat page with message history
- `create` — starts new session, redirects to permalink
- `send_message` — creates message step, dispatches task if no turn running, queues message if turn in progress
- `poll_messages` — returns messages after timestamp via `ChatMessagePresenter`
- Message length capped at 10,000 characters

**ActionCable:**
- `Connection` authenticates via `session[:user_id]` and sets tenant context from subdomain
- `ChatSessionChannel` streams per session, verifies ownership
- `allowed_request_origins` configured for development subdomains

**Frontend:**
- Stimulus `agent_chat_controller` — AJAX message sending, optimistic append with error marking, ActionCable subscription for agent responses with polling fallback (`waitingForResponse` flag), auto-scroll, Enter to send
- Chat bubble UI with sender alignment
- `@rails/actioncable` npm package + type declarations

**Routes:** `GET /ai-agents/:handle/chat` (index), `POST /ai-agents/:handle/chat` (create), `GET /ai-agents/:handle/chat/:session_id` (show), `POST /ai-agents/:handle/chat/:session_id/message` (send), `GET /ai-agents/:handle/chat/:session_id/messages` (poll)

**Internal API** (committed as `0030d21`):
- `GET /internal/agent-runner/chat/:chat_session_id/history` — returns curated conversation history including messages AND action summaries (navigate/execute steps summarized between messages so the agent knows what it did in prior turns)
- `complete` endpoint auto-dispatches next chat turn when queued human messages exist, saves `current_state`
- `step` endpoint broadcasts `message` steps via ActionCable

**Agent-runner** (committed as `0030d21`):
- `TaskPayload` extended with `mode` and `chatSessionId`
- `TaskQueue` parses `mode` and `chat_session_id` from Redis Stream
- `HarmonicClient.fetchChatHistory()` — fetches conversation history via HMAC-authenticated internal API
- `AgentContext` — `respond_to_human` tool definition + `buildChatSystemPrompt()` with conversation-mode instructions, time gap awareness, capability listing
- `AgentLoop` — in `chat_turn` mode: fetches history, navigates `/whoami` then saved `current_path`, builds chat messages with history, LLM loop with `respond_to_human` tool, reports `current_state` on completion. Falls back to reporting message step when agent uses `done` instead of `respond_to_human`.
- `ActionParser` — handles `respond_to_human` tool call parsing

**Dispatch:**
- `AgentRunnerDispatchService` includes `mode` and `chat_session_id` in Redis Stream payload

**Step timeline:**
- `_task_run_steps_timeline.html.erb` renders `message` step type with sender name and comment icon
- `to_step_hash` includes `sender_id`
- Task run pages link back to specific chat session and message anchor

---

## Part C: Navigation State Persistence ✅

**Status: Complete** (committed as `fc78fd4`)

`current_state` JSONB column on `chat_sessions` stores `current_path` so the agent resumes where it left off between turns. Identity content is NOT cached (stale data risk) — the agent always fetches `/whoami` fresh.

- Agent-runner navigates `/whoami` first (always), then saved `current_path` (if any)
- On turn completion, agent-runner reports `currentState` with final path
- Rails `complete` endpoint saves state to `chat_session.current_state`
- `chat_history` endpoint returns `current_state` in its response

---

## Implementation Status

| Phase | What | Status |
|-------|------|--------|
| 1 | `agent_session_steps` table + model + data migration | ✅ `a79a9b3` |
| 2 | Switch internal API + views to use step rows | ✅ `a79a9b3` |
| 3 | ActionCable auth + `ChatSessionChannel` | ✅ `ea9e397` |
| 4 | Chat sessions + controller + routes + views + Stimulus | ✅ `ea9e397` |
| 5 | Agent-runner: chat_turn mode, history, respond_to_human, ActionCable broadcast, auto-dispatch, polling fallback | ✅ `0030d21` |
| 6 | Navigation state persistence (`current_state` on ChatSession) | ✅ `fc78fd4` |
| 7 | Remove "ended" session status — sessions are always resumable | ✅ `fc78fd4` |
| 8 | Chat routes restructured: index + permalinks per session | ✅ `fc78fd4` |
| 9 | Polish: in-progress turn visibility, busy-agent indicator, error states, remove `steps_data` | ✅ Built |

## Design decisions made during implementation

1. **No collective scoping on ChatSession** — agents navigate across collectives, so tying a chat to one collective would hide it when the user switches. Tenant-scoped only.
2. **`typed: false` for controllers** — all existing controllers are `typed: false` because Rails route helpers aren't in Sorbet RBIs. Models are `typed: true`.
3. **Action summaries in history** — the chat history endpoint returns messages interleaved with `[Actions taken: navigated to X, created Y]` system messages so the agent knows what it did between messages. Without this, the agent loses context about its prior navigation/actions.
4. **`done` step is generic in chat mode** — when the agent responds (via `respond_to_human` or the "no tool calls" fallback), a `message` step is created with the full response (broadcast via ActionCable), and a separate `done` step with "Chat turn complete" marks task completion. This avoids duplicate content in the step timeline.
5. **`resource_model?` override** — `AiAgentChatsController` overrides `resource_model?` to return `false` because `AiAgentChat` model doesn't exist (it's `ChatSession`).
6. **Auto-dispatch on completion** — when a chat turn completes, Rails checks for queued human messages and auto-dispatches the next turn. This handles the case where the human sends a follow-up while the agent is still working.
7. **`ChatMessagePresenter`** — shared service object that formats chat messages for both ActionCable broadcasts and the polling endpoint (`GET /chat/messages?after=<timestamp>`). Ensures both delivery paths return identical data structures.
8. **Polling fallback** — the Stimulus controller polls `GET /chat/:session_id/messages?after=<timestamp>` every 3 seconds after sending a message, as a fallback when ActionCable doesn't deliver. Standard degraded-transport pattern. Controlled by `waitingForResponse` flag — only polls when actively waiting for an agent response, stops when a new message arrives (via either ActionCable or poll).
9. **No "ended" session status** — sessions are always resumable. Users start new sessions for fresh context. The sliding window + summary strategy (future) handles unbounded history within a session.
10. **Chat sessions have permalinks** — `/ai-agents/:handle/chat/:session_id`. The index at `/ai-agents/:handle/chat` lists all sessions. Task run pages link back to the specific session and message that triggered them.
11. **Each agent can only run one task at a time** — the agent-runner's per-agent lock ensures this. When an agent is busy (in any session), new turns queue in the Redis Stream. The chat UI shows a warning when the agent is busy in another session with a link to the active task run.
12. **Real-time turn visibility** — ActionCable broadcasts three event types: `status` (working/completed/error), `activity` (navigating to X, executing Y), and `message` (existing). The polling fallback also returns `turn_status`, `turn_error`, and `activity` fields.
13. **`steps_data` removed** — the JSONB column on `ai_agent_task_runs` was a transition artifact from when steps were stored inline. All step data now lives exclusively in `agent_session_steps` rows. The dual-write, sync-on-complete, and view fallback logic were all removed.

## Verification

| Phase | Test approach | Status |
|-------|---------------|--------|
| 1-2 | 65 tests pass, step data renders identically from rows | ✅ |
| 3-4 | 21 controller + model tests, manual chat UI verification | ✅ |
| 5 | 48 controller tests + 3 presenter tests + 142 agent-runner tests, manual E2E chat | ✅ |
| 6-8 | Navigation state persistence, route restructuring, no "ended" status — 114 Rails tests / 278 assertions, 142 agent-runner tests | ✅ |
| 9 | In-progress turn visibility, busy-agent indicator, error states, remove `steps_data` — 81 Rails tests / 275 assertions, 142 agent-runner tests | ✅ |
