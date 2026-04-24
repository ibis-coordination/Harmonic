# Chat Interface: Human-AI Agent Conversations

## Context

Today, AI agent tasks are fire-and-forget: the human submits a prompt, the agent-runner executes autonomously, and the human sees results after. This plan adds a **real-time chat interface** where a human and an AI agent can have a true back-and-forth conversation.

Before building chat, we first refactor the existing task run infrastructure to store steps as individual database rows instead of a JSONB array. This unifies the data model so chat becomes a natural extension of tasks rather than a parallel system.

---

## Part A: Refactor Task Run Steps into Individual Records

### Why

`AiAgentTaskRun.steps_data` stores all steps as a JSONB array. Every append rewrites the entire column. The Stimulus controller polls for the full array and diffs client-side. This works for tasks (max 50 steps), but:

- Can't efficiently query individual steps or stream them over ActionCable
- The `complete` endpoint overwrites the entire array as an "authoritative write"
- Chat conversations would grow unboundedly in a single JSONB column
- Can't broadcast individual new steps via Turbo Streams

### New table: `agent_session_steps`

| Column | Type | Notes |
|--------|------|-------|
| id | uuid PK | |
| ai_agent_task_run_id | uuid FK | NOT NULL |
| position | integer | NOT NULL, sequential within the task run |
| step_type | varchar | NOT NULL — existing types: `navigate`, `think`, `execute`, `done`, `error`, `security_warning`, `scratchpad_update`, `scratchpad_update_failed`. Chat adds: `message` |
| sender_id | uuid FK → users | nullable — set on `message` steps to identify who sent it. NULL for non-message steps (navigate, think, etc.) |
| detail | jsonb | NOT NULL, default `{}` — same structure as today's step detail objects |
| created_at | timestamp | replaces the `timestamp` field currently inside each step |

Index: `(ai_agent_task_run_id, position)` unique.

### Migration strategy

1. Create the `agent_session_steps` table
2. Keep `steps_data` column temporarily (don't remove yet)
3. Data migration: copy existing `steps_data` arrays into individual rows
4. Update internal API `step` endpoint to INSERT rows instead of appending JSON
5. Update `complete` endpoint to stop overwriting `steps_data`
6. Update `show_run` JSON endpoint to build steps from the relation
7. Update `_task_run_steps_timeline.html.erb` to read from the relation
8. Remove `steps_data` column in a follow-up migration

### Files to create/modify

**New:**
- `db/migrate/YYYYMMDD_create_agent_session_steps.rb`
- `app/models/agent_session_step.rb` — `belongs_to :ai_agent_task_run`, validations, scopes

**Modified:**
- `app/models/ai_agent_task_run.rb` — add `has_many :agent_session_steps, -> { order(:position) }`
- `app/controllers/internal/agent_runner_controller.rb` — `step` action inserts rows; `complete` stops overwriting steps_data
- `app/controllers/ai_agents_controller.rb` — `show_run` JSON format reads from relation
- `app/views/shared/_task_run_steps_timeline.html.erb` — iterate `task_run.agent_session_steps` instead of `task_run.steps_data`
- `app/javascript/controllers/task_run_status_controller.ts` — poll by position offset instead of full array diff

### Agent-runner impact

Minimal. The agent-runner already reports steps incrementally via `POST /internal/agent-runner/tasks/:id/step` with `steps: [...]`. The contract stays the same — Rails just handles receipt differently.

The `complete` call currently sends `stepsData` as an authoritative overwrite. After refactor, `complete` only sends token totals and final status. Minor update to `TaskReporter.complete()` to drop the `stepsData` field (or Rails ignores it).

---

## Part B: Add Chat Mode

### Core insight: each turn is a short-lived task

A chat session is **not** a persistent agent-runner fiber waiting for human input. That design can't survive process restarts, wastes memory while idle, and holds the per-agent lock indefinitely.

Instead: each human message triggers a **new short-lived task dispatch**. The conversation history lives in the database (`agent_session_steps` rows), not in agent-runner memory. The agent-runner is stateless between turns.

### How a chat turn works

1. Human sends message → Rails inserts `message` step, dispatches a fresh task with `mode: "chat_turn"` and a fresh ephemeral token
2. Agent-runner picks up task, fetches conversation history from Rails via internal API, rebuilds LLM context
3. Agent navigates, executes actions, calls LLM — same as a regular task
4. Agent responds → reports `message` step → task completes, fiber exits, token is destroyed
5. Human comes back whenever — a minute, a day, a year — sends another message → new dispatch, new token, new fiber

**What this gives us:**
- Survives agent-runner restarts and deployments — no state to lose
- No token refresh needed — each turn gets a fresh short-lived token
- No memory leak — conversation history is in the DB, not in a growing array
- No long-held agent lock — lock is held only during each turn's execution
- Same billing, orphan recovery, and dispatch infrastructure as regular tasks

### Model changes

Add `mode` column to `ai_agent_task_runs`:

```
mode: varchar, NOT NULL, default "task". Values: "task", "chat_turn"
```

Add `chat_session_id` column to `ai_agent_task_runs`:

```
chat_session_id: uuid, nullable. Groups multiple chat_turn task runs into one conversation.
```

New step type: `message` (with `sender_id` to identify who sent it)

### New table: `chat_sessions`

Lightweight container that groups chat turns into a conversation:

| Column | Type | Notes |
|--------|------|-------|
| id | uuid PK | |
| tenant_id | uuid FK | NOT NULL |
| collective_id | uuid FK | NOT NULL |
| ai_agent_id | uuid FK → users | NOT NULL |
| initiated_by_id | uuid FK → users | NOT NULL |
| status | varchar | `active`, `ended` (default: `active`) |
| created_at / updated_at | timestamps | |

Token/cost tracking lives on the individual `AiAgentTaskRun` records (one per turn) — no need to duplicate it on the session. The session is just a grouping key.

### Architecture

```
Browser                    Rails                     Redis                   Agent-Runner
  |                          |                         |                         |
  |-- POST /chat ----------->| create ChatSession      |                         |
  |<- redirect to chat page -|                         |                         |
  |                          |                         |                         |
  |== ActionCable subscribe =>|                        |                         |
  |                          |                         |                         |
  |-- POST /chat/message --->| insert message    |                         |
  |                          | create TaskRun(chat_turn)|                        |
  |                          |-- XADD ----------------->|                        |
  |<= turbo_stream append ===|                         |---- stream pickup ----->|
  |                          |                         |                         |
  |                          |                         |<- GET internal/chat/:id/history
  |                          |<- return step rows -----|                         |
  |                          |                         |                         |
  |                          |                         |      LLM + tools        |
  |                          |                         |                         |
  |                          |<- POST internal/step (message) -------------|
  |<= ActionCable broadcast =| INSERT step row         |                         |
  |                          |                         |                         |
  |                          |<- POST internal/complete -------------------------|
  |                          | task done, token destroyed|    fiber exits         |
  |                          |                         |                         |
  |   (human sends next msg) |                         |                         |
  |-- POST /chat/message --->| insert message    |                         |
  |                          | create new TaskRun      |                         |
  |                          |-- XADD ----------------->|---- new pickup ------->|
  |                          |                         |      (repeat)           |
```

**Transport:**
- **Redis Streams** for dispatching each chat turn (reuses existing pattern exactly)
- **ActionCable** for agent→browser streaming (Turbo Streams for new messages)
- **Internal HTTP API** for agent-runner→Rails (existing HMAC pattern)
- **No Redis pub/sub needed** — there's no persistent fiber to notify

### Conversation history management

The agent-runner fetches history via a new internal API endpoint: `GET /internal/agent-runner/chat/:chat_session_id/history`. Rails returns `agent_session_steps` rows for that chat session.

**What to include in history:** The history endpoint should return a curated view, not a raw step dump. The agent needs:
- `message` steps — the conversational thread (use `sender_id` to distinguish human vs agent)
- A summary of `navigate` and `execute` steps — what the agent did (not raw content previews or think steps, which would bloat context)
- The endpoint should produce a structured response that separates messages from action summaries, so the agent-runner can build the LLM context intelligently

**Time awareness:** The system prompt for each chat turn should include the current timestamp and, if the previous message is more than a few minutes old, explicitly note the gap: "The last message in this conversation was 3 days ago." This lets the agent re-orient naturally — check if things have changed, re-read pages it acted on previously — rather than picking up mid-thought as if no time has passed.

**For long conversations**, the agent-runner applies a **sliding window + summary** strategy:
- If history exceeds ~50 messages, ask the LLM to summarize older context
- Send: summary + last N messages + new human message
- This keeps LLM context bounded regardless of conversation length

**Scratchpad updates per turn:** The existing scratchpad update runs at end of task. For chat, this should run at end of each turn, so the agent builds up memory across the conversation. This is especially valuable for long-running conversations with gaps — the scratchpad persists even if the conversation history gets summarized.

### ActionCable setup

- `app/channels/application_cable/connection.rb` — add auth via `session[:user_id]` (mirrors `ApplicationController#load_session_user`)
- `app/channels/chat_session_channel.rb` (new) — streams for a chat session, verifies `initiated_by_id == current_user.id`

### Routes

```ruby
get  'ai-agents/:handle/chat'         => 'ai_agent_chats#show'
post 'ai-agents/:handle/chat'         => 'ai_agent_chats#create'
post 'ai-agents/:handle/chat/message' => 'ai_agent_chats#send_message'
post 'ai-agents/:handle/chat/end'     => 'ai_agent_chats#end_session'

# Internal API:
get  'internal/agent-runner/chat/:chat_session_id/history' => 'internal/agent_runner#chat_history'
```

### Controller: `AiAgentChatsController`

- **`show`** — renders chat page. Loads active chat session for this agent (if any), with its message history. Otherwise shows "Start Chat" state.
- **`create`** — billing checks, creates `ChatSession`, redirects to show.
- **`send_message`** — inserts `AgentSessionStep(step_type: "message")` on the chat session, creates a new `AiAgentTaskRun(mode: "chat_turn", chat_session_id: ...)`, dispatches via Redis Stream. Returns turbo_stream to append human message to UI.
- **`end_session`** — marks chat session as ended.

### Internal API extensions

Extend `Internal::AgentRunnerController`:
- **`chat_history`** — returns message steps for a chat session (for LLM context rebuilding)
- Existing `step` endpoint handles `message` steps — broadcasts via ActionCable when the step belongs to a chat session
- Existing `complete` endpoint works unchanged

### Agent-runner changes

No separate `ChatLoop` needed. The existing `AgentLoop` handles `chat_turn` mode with minor modifications:

**Modified files:**
- `agent-runner/src/core/PromptBuilder.ts` — add `mode` and `chatSessionId` to `TaskPayload`. When `mode === "chat_turn"`: fetch history, build conversation-mode system prompt, include prior messages in context
- `agent-runner/src/services/TaskQueue.ts` — parse `mode` and `chat_session_id` from stream entry
- `agent-runner/src/services/HarmonicClient.ts` — add `fetchChatHistory(chatSessionId, token, subdomain)` method
- `agent-runner/src/services/AgentLoop.ts` — at startup, if `mode === "chat_turn"`: fetch history, prepend to messages. Add `respond_to_human` tool. When agent calls `respond_to_human`, report `message` step and end the task (instead of waiting).

**`respond_to_human` tool in chat mode**: Instead of pausing (old design), it signals "I'm done with this turn." The agent reports its response as a `message` step and the task completes normally. The next human message will trigger a new task.

### Agent experience: system prompt guidance

The chat system prompt should give the agent clear operational context:

- **Capabilities:** Explicitly list what the agent can and cannot do. "You can navigate pages, create notes/decisions/commitments, vote, comment, and read content. You cannot modify user settings, manage collectives, or access admin pages." Avoids trial-and-error failures that feel bad in a conversational context.
- **Conversation mode:** "You are in a conversation with a human. After completing actions or when you need clarification, use `respond_to_human` to reply. You can chain multiple navigations and actions before responding — do your work first, then summarize what you did."
- **Asking questions:** "If a request is ambiguous, ask a clarifying question rather than guessing. Use `respond_to_human` to ask."
- **Time gaps:** Include current timestamp and time since last message. The agent should re-orient after gaps rather than assuming continuity.

### Frontend

**`app/views/ai_agent_chats/show.html.erb`** — full-height chat layout:
- Agent info header (avatar, name, status indicator)
- Scrollable message list (renders `agent_session_steps` where type is `message`, using `sender_id` to style each side)
- Fixed-bottom input bar (textarea + send button)
- "Agent is thinking..." indicator while a chat_turn task is running

**`app/views/ai_agent_chats/_message.html.erb`** — message partial

**`app/javascript/controllers/agent_chat_controller.ts`** — Stimulus controller:
- ActionCable subscription for the chat session — receives new agent messages as Turbo Stream appends
- Message sending via fetch POST
- Auto-scroll, typing/thinking indicators
- Enter to send, Shift+Enter for newline

### In-progress turn visibility

While a turn is running, the UI should show more than just "Agent is thinking..." — show a live activity feed of what the agent is doing (navigating to X, executing Y), similar to the existing step timeline but rendered inline in the chat as a collapsible activity block. This uses the same ActionCable broadcast for step rows — the UI just renders `navigate` and `execute` steps differently than `message` steps.

### Mid-turn human messages

The input should **not** be disabled while a turn is in progress. The human should be able to queue a follow-up or correction ("actually, skip the third one"). When the current turn completes, Rails checks for any queued `message` steps that arrived after the turn was dispatched and immediately dispatches a new turn with that message. This preserves the simplicity of the stateless turn model while giving the human the ability to course-correct.

Implementation: `send_message` always inserts the `message` step. If a `chat_turn` task is currently `running` or `queued` for this session, it skips dispatching a new task — the step just sits in the DB. When the current turn completes (the `complete` internal API call), Rails checks for un-processed human `message` steps (by `sender_id`) after the last agent `message` step and auto-dispatches a new turn.

**Modified:** `app/views/ai_agents/show.html.erb` — add "Chat" link

### Billing + dispatch

- `app/services/agent_runner_dispatch_service.rb` — accept `mode: "chat_turn"` and `chat_session_id` in the Redis Stream payload
- Same billing pre-checks as task dispatch (run on each turn)
- Each turn is a separate `AiAgentTaskRun` with its own token tracking
- Session-level cost = sum of all turns' costs (query via `chat_session_id`)

---

## Implementation Order

| Phase | What | Depends on |
|-------|------|------------|
| 1 | `agent_session_steps` table + model + data migration | — |
| 2 | Switch internal API + views to use step rows | Phase 1 |
| 3 | ActionCable auth + `ChatSessionChannel` | — (can parallel with 1-2) |
| 4 | `chat_sessions` table + model + chat controller + routes + views | Phases 2, 3 |
| 5 | Agent-runner: chat_turn mode, history fetching, `respond_to_human` | Phase 4 |
| 6 | Polish: typing indicators, reconnection, error states, remove `steps_data` | Phase 5 |

## Key reusable code

| What | File |
|------|------|
| Billing pre-checks | `app/services/agent_runner_dispatch_service.rb` |
| HMAC internal API base | `app/controllers/internal/base_controller.rb` |
| Redis Stream dispatch | `AgentRunnerDispatchService#dispatch` |
| Token encryption | `AgentRunnerCrypto` / `TokenCrypto` |
| Ephemeral API tokens | `ApiToken.create_internal_token` |
| AgentLoop (extend, not replace) | `agent-runner/src/services/AgentLoop.ts` |
| Step building | `agent-runner/src/core/StepBuilder.ts` |
| System prompt | `app/services/concerns/harmonic_assistant.rb` |
| Session auth pattern | `ApplicationController#load_session_user` via `session[:user_id]` |

## Verification

| Phase | Test approach |
|-------|---------------|
| 1-2 | Existing task run tests pass, step data renders identically from rows |
| 3 | Manual: ActionCable connects, test broadcast appears |
| 4 | Manual: chat UI renders, human messages append, turn tasks are dispatched |
| 5 | Full E2E: send message → agent navigates → responds → human replies → agent gets history |
| 5 | Playwright MCP: automated chat flow |
