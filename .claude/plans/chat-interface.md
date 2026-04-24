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

## Part B: Add Chat Mode ✅ (Phase 3-4) + 🚧 (Phase 5-6)

### Core insight: each turn is a short-lived task

Each human message triggers a **new short-lived task dispatch**. The conversation history lives in the database (`agent_session_steps` rows), not in agent-runner memory. The agent-runner is stateless between turns — sessions survive process restarts with no resources held while idle.

### What's built (committed as `ea9e397`)

**Models:**
- `ChatSession` — groups turns into a conversation, tenant-scoped (no collective scoping — agents navigate across collectives)
- `mode` column on `AiAgentTaskRun` (`task` | `chat_turn`)
- `chat_session_id` FK on `AiAgentTaskRun`
- Single `message` step type with `sender_id` (generalizable to human-to-human chat in the future)

**Controller (`AiAgentChatsController`):**
- `show` — renders chat page with message history
- `create` — starts session (idempotent)
- `send_message` — creates message step, dispatches task if no turn running, queues message if turn in progress
- `end_session` — cancels running turns, marks session ended
- Message length capped at 10,000 characters

**ActionCable:**
- `Connection` authenticates via `session[:user_id]` and sets tenant context from subdomain
- `ChatSessionChannel` streams per session, verifies ownership

**Frontend:**
- Stimulus `agent_chat_controller` — AJAX message sending, optimistic append with error marking, ActionCable subscription for agent responses, auto-scroll, Enter to send
- Chat bubble UI with sender alignment
- `@rails/actioncable` npm package + type declarations

**Routes:** `/ai-agents/:handle/chat`, `/chat/message`, `/chat/end`

### What's built (uncommitted — Phase 5)

**Internal API:**
- `GET /internal/agent-runner/chat/:chat_session_id/history` — returns curated conversation history including messages AND action summaries (navigate/execute steps summarized between messages so the agent knows what it did in prior turns)
- `complete` endpoint auto-dispatches next chat turn when queued human messages exist
- `step` endpoint broadcasts `message` steps via ActionCable

**Agent-runner:**
- `TaskPayload` extended with `mode` and `chatSessionId`
- `TaskQueue` parses `mode` and `chat_session_id` from Redis Stream
- `HarmonicClient.fetchChatHistory()` — fetches conversation history via HMAC-authenticated internal API
- `AgentContext` — `respond_to_human` tool definition + `buildChatSystemPrompt()` with conversation-mode instructions, time gap awareness, capability listing
- `AgentLoop` — in `chat_turn` mode: fetches history, builds chat system prompt with prior messages + action summaries, includes `respond_to_human` tool, handles `respond_to_human` action (reports message step + ends turn). Falls back to reporting message step when agent uses `done` instead of `respond_to_human`.
- `ActionParser` — handles `respond_to_human` tool call parsing

**Dispatch:**
- `AgentRunnerDispatchService` includes `mode` and `chat_session_id` in Redis Stream payload

**Step timeline:**
- `_task_run_steps_timeline.html.erb` renders `message` step type with sender name and comment icon
- `to_step_hash` includes `sender_id`

---

## Part C: Navigation State Persistence 🚧

### Problem

Each chat turn starts at `/whoami` — the agent has no memory of where it was at the end of the last turn. If the human says "navigate to this note" and the agent does, then the human says "add a comment," the agent doesn't know which note they're talking about without re-navigating. The human expects locational continuity.

### Solution

Add `current_state` JSONB column to `chat_sessions`:

```
current_state: jsonb, NOT NULL, default '{}'
```

Contents:
```json
{
  "current_path": "/collectives/chariot/n/abc123",
  "identity_content": "..."
}
```

**End of turn:** The agent-runner reports its final `currentPath` to Rails. Rails updates `chat_session.current_state["current_path"]`. The `/whoami` identity content can also be cached here on the first turn.

**Start of turn:** Instead of always navigating to `/whoami`, the agent-runner:
1. Fetches `current_state` from the chat history endpoint (include it in the response)
2. If `current_state.identity_content` exists, uses it for the system prompt (skip `/whoami` navigation)
3. If `current_state.current_path` exists, navigates there instead of `/whoami`
4. Falls back to `/whoami` on first turn or if no state is cached

**Internal API change:** The `complete` endpoint (or a new field on `chat_history` response) accepts/returns `current_state`. The agent-runner sends `{ current_path: currentPath }` on completion.

**Files to modify:**
- `db/migrate/YYYYMMDD_add_current_state_to_chat_sessions.rb` (new)
- `app/models/chat_session.rb` — accessor helpers
- `app/controllers/internal/agent_runner_controller.rb` — `complete` saves state, `chat_history` returns state
- `agent-runner/src/services/AgentLoop.ts` — restore state on chat_turn start, report state on completion
- `agent-runner/src/services/HarmonicClient.ts` — `ChatHistoryResponse` includes `current_state`

---

## Implementation Status

| Phase | What | Status |
|-------|------|--------|
| 1 | `agent_session_steps` table + model + data migration | ✅ Committed |
| 2 | Switch internal API + views to use step rows | ✅ Committed |
| 3 | ActionCable auth + `ChatSessionChannel` | ✅ Committed |
| 4 | Chat sessions + controller + routes + views + Stimulus | ✅ Committed |
| 5 | Agent-runner: chat_turn mode, history, respond_to_human, ActionCable broadcast, auto-dispatch, polling fallback | 🚧 Built, needs commit |
| 6 | Navigation state persistence (`current_state` on ChatSession) | 🚧 Planned |
| 7 | Polish: typing indicators, error states, remove `steps_data` | Pending |

## Design decisions made during implementation

1. **No collective scoping on ChatSession** — agents navigate across collectives, so tying a chat to one collective would hide it when the user switches. Tenant-scoped only.
2. **`typed: false` for controllers** — all existing controllers are `typed: false` because Rails route helpers aren't in Sorbet RBIs. Models are `typed: true`.
3. **Action summaries in history** — the chat history endpoint returns messages interleaved with `[Actions taken: navigated to X, created Y]` system messages so the agent knows what it did between messages. Without this, the agent loses context about its prior navigation/actions.
4. **`done` step is generic in chat mode** — when the agent responds (via `respond_to_human` or the "no tool calls" fallback), a `message` step is created with the full response (broadcast via ActionCable), and a separate `done` step with "Chat turn complete" marks task completion. This avoids duplicate content in the step timeline.
5. **`resource_model?` override** — `AiAgentChatsController` overrides `resource_model?` to return `false` because `AiAgentChat` model doesn't exist (it's `ChatSession`).
6. **Auto-dispatch on completion** — when a chat turn completes, Rails checks for queued human messages and auto-dispatches the next turn. This handles the case where the human sends a follow-up while the agent is still working.
7. **`ChatMessagePresenter`** — shared service object that formats chat messages for both ActionCable broadcasts and the polling endpoint (`GET /chat/messages?after=<timestamp>`). Ensures both delivery paths return identical data structures.
8. **Polling fallback** — the Stimulus controller polls `GET /chat/messages?after=<timestamp>` every 3 seconds after sending a message, as a fallback when ActionCable doesn't deliver. Standard degraded-transport pattern. Stops polling when a new message arrives (via either ActionCable or poll).

## Verification

| Phase | Test approach | Status |
|-------|---------------|--------|
| 1-2 | 65 tests pass, step data renders identically from rows | ✅ |
| 3-4 | 21 controller + model tests, manual chat UI verification | ✅ |
| 5 | 48 controller tests + 3 presenter tests + 142 agent-runner tests, manual E2E chat | 🚧 |
| 6 | Navigation continuity: agent remembers location across turns | Pending |
| 7 | Typing indicators, error states | Pending |
