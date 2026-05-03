# Unified /chat Page

## Context

Chat sessions with AI agents are currently buried under `/ai-agents/:handle/chat`, requiring users to navigate to a specific agent first. The goal is a top-level `/chat` route that works like a DM-style messaging app: agents listed as contacts in the sidebar, click one to open the conversation.

**Key simplification**: One chat session per agent-user pair (not multiple parallel sessions). Clicking an agent always opens the same continuous conversation thread, like texting someone. This eliminates session management entirely from the user's perspective.

**Context window management**: The agent-runner's chat history endpoint applies a sliding window (last N messages) so the LLM context doesn't grow unboundedly. Full history stays in the DB for the user to scroll through.

## Design

**Sidebar**: Agents listed as contacts. Clicking an agent opens (or creates) the single conversation with that agent. Selected agent is highlighted. No session picker needed.

```
┌─────────────────────┐
│ Chat                │
├─────────────────────┤
│ AGENTS              │
│ ● Agent Alpha    ← active
│   Agent Beta        │
│   Agent Gamma       │
│                     │
│                     │
│                     │
└─────────────────────┘
```

**URL structure**:
- `GET /chat` — landing page (no agent selected)
- `GET /chat/:agent_handle` — conversation with a specific agent (find-or-create session)
- `POST /chat/:agent_handle/message` — send a message
- `GET /chat/:agent_handle/messages` — polling fallback

The existing `/ai-agents/:handle/chat/*` routes stay for now (no breaking changes).

## Implementation Steps

### 1. Add unique index on ChatSession
**File**: new migration

Add unique index on `(tenant_id, ai_agent_id, initiated_by_id)` to enforce one session per agent-user pair. Consolidate any existing duplicate sessions first (keep the one with the most recent activity, reassign task_runs from others).

### 2. Update ChatSession model
**File**: [app/models/chat_session.rb](app/models/chat_session.rb)

Add `find_or_create_for(agent:, user:, tenant:)` class method that atomically finds or creates the single session for an agent-user pair. Add uniqueness validation matching the index.

### 3. Add routes
**File**: [config/routes.rb](config/routes.rb)

```ruby
get "/chat", to: "chats#index", as: :chats
get "/chat/:handle", to: "chats#show", as: :chat
post "/chat/:handle/message", to: "chats#send_message", as: :chat_message
get "/chat/:handle/messages", to: "chats#poll_messages", as: :chat_poll
```

No `create` action needed — `show` does find-or-create.

### 4. Create ChatsController
**File**: `app/controllers/chats_controller.rb` (new)

Adapts logic from [AiAgentChatsController](app/controllers/ai_agent_chats_controller.rb):

- `before_action :load_agents` — loads all agents the user can chat with (for sidebar)
- `before_action :find_agent_and_session` (show/send_message/poll) — finds agent by `:handle`, then `ChatSession.find_or_create_for(...)` to get/create the session
- `set_sidebar_mode` — uses new `"chat_unified"` mode
- `show` — loads messages, checks turn status (same as existing `show`)
- `send_message` — same logic as existing (create turn or queue message)
- `poll_messages` — same logic as existing

Reuse directly from existing controller:
- `create_chat_turn(message_text)` logic
- `dispatch_chat_turn(task_run)` logic
- `format_activity_text(step)` helper
- `ChatMessagePresenter` for formatting
- `MAX_MESSAGE_LENGTH` constant

### 5. Add sidebar mode
**File**: [app/components/sidebar_component.rb](app/components/sidebar_component.rb)

Add `"chat_unified"` to `VALID_MODES` and map to `"pulse/sidebar_chat_unified"` in `resolved_mode`. Add same bypass in `compute_resolved_mode` as existing `"chat"` mode.

### 6. Create unified chat sidebar partial
**File**: `app/views/pulse/_sidebar_chat_unified.html.erb` (new)

Structure:
- **Header**: "Chat" title
- **Agents list**: Each agent with avatar/name, linking to `/chat/:handle`. Active agent highlighted. Show indicator if agent has a running turn.

Required instance variables:
- `@agents` — all agents the user can chat with
- `@ai_agent` — currently selected agent (may be nil, for highlighting)

### 7. Create views
**File**: `app/views/chats/index.html.erb` (new)

Empty state: "Select an agent to start chatting."

**File**: `app/views/chats/show.html.erb` (new)

Nearly identical to [ai_agent_chats/show.html.erb](app/views/ai_agent_chats/show.html.erb). Differences:
- `data-agent-chat-url-value` points to `chat_message_path(@ai_agent.handle)`
- `data-agent-chat-poll-url-value` points to `chat_poll_path(@ai_agent.handle)`
- Reuse `ai_agent_chats/_message.html.erb` partial (render with full path)

### 8. Add sliding window to chat history endpoint
**File**: [app/controllers/internal/agent_runner_controller.rb](app/controllers/internal/agent_runner_controller.rb)

In the `chat_history` action, cap the messages returned to the LLM. Apply a limit (e.g., last 50 messages or configurable per-agent). Full history stays in DB — this only affects what the agent-runner receives for context.

### 9. Add link in navigation
**File**: [app/views/layouts/_top_right_menu.html.erb](app/views/layouts/_top_right_menu.html.erb)

Add "Chat" link (with `comment-discussion` octicon) near the existing "AI Agents" link.

## No changes needed to:
- `AiAgentTaskRun` model
- `AgentSessionStep` model
- `ChatSessionChannel` (ActionCable)
- `agent_chat_controller.ts` (Stimulus) — data attributes passed from view
- `AgentRunnerDispatchService`
- `ChatMessagePresenter`

## Testing

### Automated tests
- Controller tests for `ChatsController` — index, show, send_message, poll_messages
- `ChatSession.find_or_create_for` — creates on first call, returns existing on second
- Unique index prevents duplicate sessions
- Authorization: user can only see their own sessions
- Sliding window: chat history endpoint returns capped messages
- Migration: duplicate sessions consolidated correctly

### Manual verification
- Navigate to `/chat` — see agent list in sidebar, empty state in main area
- Click an agent — conversation loads (or empty conversation created)
- Send a message — appears immediately, agent responds via ActionCable
- Navigate away and back to same agent — same conversation, full history visible
- Click a different agent — switches to that agent's conversation
- Existing `/ai-agents/:handle/chat` routes still work

## File Summary

| File | Action |
|------|--------|
| `db/migrate/xxx_add_unique_chat_session_index.rb` | New — unique index + consolidation |
| `app/models/chat_session.rb` | Edit — add `find_or_create_for`, uniqueness validation |
| `config/routes.rb` | Edit — add `/chat` routes |
| `app/controllers/chats_controller.rb` | New |
| `app/components/sidebar_component.rb` | Edit — add `chat_unified` mode |
| `app/views/pulse/_sidebar_chat_unified.html.erb` | New |
| `app/views/chats/index.html.erb` | New |
| `app/views/chats/show.html.erb` | New |
| `app/controllers/internal/agent_runner_controller.rb` | Edit — sliding window on chat_history |
| `app/views/layouts/_top_right_menu.html.erb` | Edit — add Chat link |
| `test/controllers/chats_controller_test.rb` | New |
| `test/models/chat_session_test.rb` | Edit — test find_or_create_for + uniqueness |
