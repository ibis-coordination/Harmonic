# ChatMessage Model Refactor

## Context

Chat messages are currently stored as `AgentSessionStep` records (step_type: "message") nested inside `AiAgentTaskRun` records. This couples messages to the agent execution model — you need a task_run to store a message. This blocks external agent chat (no dispatch = no task_run) and human-to-human chat (no agent = no task_run).

This refactor introduces a `ChatMessage` model that belongs directly to `ChatSession` + `sender`, decoupling messages from task runs. Scope: internal agents only. External agent and human-to-human chat come later.

## New Model

```
chat_messages
  id         (uuid, PK)
  tenant_id  (uuid, FK, not null)
  chat_session_id (uuid, FK, not null)
  sender_id  (uuid, FK to users, not null)
  content    (text, not null)
  created_at, updated_at
```

Indexes: `(chat_session_id, created_at)` for message loading, `(tenant_id)` for default scope.

## Migration Strategy

Two migrations:
1. **Create table** — `chat_messages` with columns and indexes
2. **Data migration** — `INSERT INTO chat_messages SELECT ... FROM agent_session_steps` where step_type = "message" and the step belongs to a task_run with a chat_session_id. Map: `detail->>'content'` → `content`, `sender_id` → `sender_id`, derive `chat_session_id` and `tenant_id` via join to `ai_agent_task_runs`.

## Changes by File

### New files
- `db/migrate/..._create_chat_messages.rb` — table + indexes
- `db/migrate/..._migrate_message_steps_to_chat_messages.rb` — data migration
- `app/models/chat_message.rb` — model with validations, tenant scoping
- `test/models/chat_message_test.rb` — model tests

### Models
- [app/models/chat_session.rb](app/models/chat_session.rb)
  - Add `has_many :chat_messages, dependent: :destroy`
  - Replace `messages` method: query `chat_messages.order(:created_at)` instead of AgentSessionStep subquery
  - Remove `has_many :task_runs` dependency for message access (keep association for task run management)
- [app/models/agent_session_step.rb](app/models/agent_session_step.rb)
  - Remove "message" from `STEP_TYPES`
  - Remove `.messages` scope
  - Remove `message_step?` method
  - Remove sender validation for message steps (sender stays as a column for other uses, or becomes optional)

### Chat controllers — writing messages
- [app/controllers/chats_controller.rb](app/controllers/chats_controller.rb)
  - `send_message`: create `ChatMessage` on the session instead of `AgentSessionStep` on a task_run. Still create task_run + dispatch for the agent, but the human's message is a `ChatMessage`, not a step.
  - When a turn is already running: create `ChatMessage` (no need to attach to active_run's steps)
- [app/controllers/ai_agent_chats_controller.rb](app/controllers/ai_agent_chats_controller.rb)
  - Same changes as above

### Chat controllers — reading messages
- [app/controllers/chats_controller.rb](app/controllers/chats_controller.rb)
  - `show`: `@chat_session.chat_messages` (already returns ChatMessage via updated `messages` method)
  - `render_new_messages`: query `chat_messages` with timestamp filter
  - `render_older_messages`: query `chat_messages` with pagination
- [app/controllers/ai_agent_chats_controller.rb](app/controllers/ai_agent_chats_controller.rb)
  - `show`, `poll_messages`: same pattern
  - `preload_first_messages`: query `ChatMessage` directly — `ChatMessage.where(chat_session_id: session_ids).order(:created_at)` grouped by session

### Internal agent-runner controller
- [app/controllers/internal/agent_runner_controller.rb](app/controllers/internal/agent_runner_controller.rb)
  - `step` action: when `step_type == "message"`, create a `ChatMessage` on the task_run's chat_session instead of an `AgentSessionStep`. Broadcast via `broadcast_chat_message` as before.
  - `chat_history` action: query `ChatMessage` for messages, keep querying `AgentSessionStep` for navigate/execute steps (action summaries between messages). Interleave by timestamp.
  - `auto_dispatch_next_chat_turn`: query `ChatMessage` to find last agent message and pending human messages.
  - `broadcast_chat_message`: update to accept `ChatMessage` instead of `AgentSessionStep`

### Presenter
- [app/services/chat_message_presenter.rb](app/services/chat_message_presenter.rb)
  - `format` takes `ChatMessage` instead of `AgentSessionStep`
  - Read `message.content` instead of `step.detail&.dig("content")`
  - Read `message.sender_id` instead of `step.sender_id`
  - Rest of the format hash stays identical

### Views
- [app/views/ai_agent_chats/_message.html.erb](app/views/ai_agent_chats/_message.html.erb)
  - Change `step` local to `message` (or keep `step` name for minimal diff)
  - Read `message.content` instead of `step.detail&.dig("content")`
  - Read `message.sender_id` instead of `step.sender_id`
- [app/views/ai_agents/show_run.html.erb](app/views/ai_agents/show_run.html.erb)
  - First message query: use `ChatMessage.where(chat_session_id: ...)` instead of step query

### No changes needed
- `agent_chat_controller.ts` — frontend format is unchanged (ChatMessagePresenter output is identical)
- `ChatSessionChannel` — transport layer, broadcasts whatever it's given
- `AgentRunnerDispatchService` — broadcasts status events, not messages
- Agent-runner TypeScript service — it POSTs steps to `/step` endpoint (the Rails side handles routing to ChatMessage), and GETs `/chat/:id/history` (response format unchanged)

## Key Design Decisions

**Human messages are no longer attached to task_runs.** When a user sends a message, a `ChatMessage` is created on the session. A task_run is still created and dispatched, but it doesn't "contain" the message. The task_run's `task` field still gets the message text (for the agent-runner to know what to respond to).

**Agent messages come through the `step` endpoint.** The agent-runner still POSTs `{ type: "message", detail: { content: ... }, sender_id: agentId }` to `/step`. The controller detects `type == "message"` and creates a `ChatMessage` instead of an `AgentSessionStep`. This means the agent-runner needs zero code changes.

**chat_history interleaves two tables.** Messages come from `chat_messages`, action summaries come from `agent_session_steps` (navigate/execute). The endpoint queries both and merges by timestamp. This is slightly more complex but keeps the data model clean.

**auto_dispatch_next_chat_turn simplifies.** Instead of finding message steps within a task_run by position, query `ChatMessage.where(chat_session_id: ...).order(:created_at)` to find the last agent message and any human messages after it.

## Verification

### Automated tests
- `test/models/chat_message_test.rb` — validations, tenant scoping, associations
- Update `test/models/chat_session_test.rb` — `messages` method returns ChatMessage records
- Update `test/models/agent_session_step_test.rb` — remove message-related tests
- Update `test/controllers/chats_controller_test.rb` — assert ChatMessage creation in send_message
- Update `test/controllers/ai_agent_chats_controller_test.rb` — same
- Update `test/controllers/internal/agent_runner_controller_test.rb` — step creates ChatMessage for message type, chat_history returns from ChatMessage
- Update `test/services/chat_message_presenter_test.rb` — format takes ChatMessage

### Manual verification
- Send a message via `/chat/:handle` — message appears, agent responds
- Refresh page — full history visible with pagination
- Load earlier messages — older messages prepended correctly
- Old `/ai-agents/:handle/chat` routes still work
- Agent-runner successfully picks up tasks and responds
- Admin task run view still shows steps correctly (minus message steps)

### Run
```bash
docker compose exec web bundle exec rails test
docker compose exec web bundle exec rubocop
docker compose exec web bundle exec srb tc
docker compose exec js npm test && npm run typecheck
```

## File Summary

| File | Action |
|------|--------|
| `db/migrate/..._create_chat_messages.rb` | New |
| `db/migrate/..._migrate_message_steps_to_chat_messages.rb` | New |
| `app/models/chat_message.rb` | New |
| `test/models/chat_message_test.rb` | New |
| `app/models/chat_session.rb` | Edit |
| `app/models/agent_session_step.rb` | Edit — remove message-related code |
| `app/controllers/chats_controller.rb` | Edit |
| `app/controllers/ai_agent_chats_controller.rb` | Edit |
| `app/controllers/internal/agent_runner_controller.rb` | Edit |
| `app/services/chat_message_presenter.rb` | Edit |
| `app/views/ai_agent_chats/_message.html.erb` | Edit |
| `app/views/ai_agents/show_run.html.erb` | Edit |
| `test/models/chat_session_test.rb` | Edit |
| `test/models/agent_session_step_test.rb` | Edit |
| `test/controllers/chats_controller_test.rb` | Edit |
| `test/controllers/ai_agent_chats_controller_test.rb` | Edit |
| `test/controllers/internal/agent_runner_controller_test.rb` | Edit |
| `test/services/chat_message_presenter_test.rb` | Edit |
