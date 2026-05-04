# Human-to-Human Chat

## Context

Chat currently assumes one side is always an AI agent (`ChatSession.ai_agent_id`). This prevents human-to-human direct messaging. The goal is to generalize `ChatSession` to support any two participants while keeping all existing agent chat working.

Design constraints: 1-on-1 only (no group chat), social proximity for contact discovery, same routes/views for all chat types.

## Data Model Change

Replace `ai_agent_id` + `initiated_by_id` with `user_one_id` + `user_two_id`. Store participants in a canonical order (lower UUID first) to enforce uniqueness without caring who initiated.

**Migration:**
1. Add `user_one_id` and `user_two_id` columns (nullable initially)
2. Backfill from existing data: `user_one_id = MIN(ai_agent_id, initiated_by_id)`, `user_two_id = MAX(ai_agent_id, initiated_by_id)`
3. Add unique index on `(tenant_id, user_one_id, user_two_id)`
4. Make columns NOT NULL
5. Remove old unique index on `(tenant_id, ai_agent_id, initiated_by_id)`
6. Drop `ai_agent_id` and `initiated_by_id` columns

**ChatSession model changes:**
- `belongs_to :user_one, class_name: "User"` + `belongs_to :user_two, class_name: "User"`
- `find_or_create_between(user_a:, user_b:, tenant:)` — canonicalizes order, find-or-create
- `other_participant(user)` — returns the other user
- `participant?(user)` — returns boolean
- Remove `find_or_create_for(agent:, user:, tenant:)`
- Keep `has_many :task_runs` for agent chat sessions (backward compatible)

## Controller Changes

**`find_partner_and_session`** in [ChatsController](app/controllers/chats_controller.rb):
- Remove the agent/human branching logic
- Look up partner by handle (already done)
- Authorization: partner must be on the same tenant (already done) AND either:
  - Partner is one of current_user's agents (existing check)
  - Partner is a human on the same tenant (new — allow all tenant members to DM)
- `ChatSession.find_or_create_between(user_a: current_user, user_b: partner, tenant: current_tenant)`
- Set `@partner` (the other participant) instead of `@ai_agent`

**`load_chat_partners`**:
- For humans: list agents (existing) + humans with existing sessions + social proximity contacts
- For agents: list humans with existing sessions (existing)

**`create_and_dispatch_message`**:
- Dispatch logic: if `@partner.internal_ai_agent?`, dispatch a turn. Otherwise, just save + broadcast.
- Replace `@ai_agent` references with `@partner`

## View Changes

**`_message.html.erb`** — Replace `@ai_agent` with `@partner`:
- `is_mine = message.sender_id == current_user.id` (instead of `is_human = sender != ai_agent`)
- Sender name: "You" for own messages, `message.sender.display_name` for others
- Markdown rendering: render as markdown if sender is an AI agent (`message.sender.ai_agent?`), plain text otherwise

**`show.html.erb`** — Replace `@ai_agent` references with `@partner`

**`show.md.erb`** — Same

**Sidebar** — Replace `@ai_agent` references with `@partner`

## ChatMessagePresenter

Replace `is_agent = message.sender_id == chat_session.ai_agent_id` with `is_agent = message.sender.ai_agent?`. The `is_agent` field stays in the output (the frontend uses it to decide markdown rendering), but it's determined by the sender's user type, not the session's structure.

## ChatSessionChannel

Currently authorizes by `initiated_by_id: current_user.id`. Change to `participant?(current_user)`.

## Internal Agent Runner Controller

References `chat_session.ai_agent_id` in `chat_history` for role assignment. Change to check sender's user type.

References `chat_session.initiated_by` in `auto_dispatch_next_chat_turn`. Change to use `chat_session.other_participant(task_run.ai_agent)` to find the human.

## AiAgentTaskRunResource

`resource_collective_matches_resource` and tracking — no changes needed (uses `chat_message.collective_id`).

## Migration of Existing Code References

Search and replace all references to:
- `chat_session.ai_agent_id` / `chat_session.ai_agent`
- `chat_session.initiated_by_id` / `chat_session.initiated_by`

With the new participant methods.

## Sidebar: Social Proximity Contacts

For the `/chat` sidebar when a human visits:
- Show agents first (existing)
- Then show humans they have existing chat sessions with
- Then show top social proximity contacts (via `current_user.most_proximate_users`)
- Deduplicate and limit

## Files to Change

| File | Change |
|------|--------|
| `db/migrate/..._generalize_chat_session_participants.rb` | New — add columns, backfill, drop old |
| `app/models/chat_session.rb` | Rewrite — new associations, find_or_create_between, participant helpers |
| `app/controllers/chats_controller.rb` | Refactor — @partner instead of @ai_agent, simplified find logic |
| `app/views/chats/_message.html.erb` | Update — use current_user for own/other detection |
| `app/views/chats/show.html.erb` | Update — @partner |
| `app/views/chats/show.md.erb` | Update — @partner |
| `app/views/pulse/_sidebar_chat_unified.html.erb` | Update — show humans + agents |
| `app/services/chat_message_presenter.rb` | Update — is_agent from sender type |
| `app/channels/chat_session_channel.rb` | Update — participant? check |
| `app/controllers/internal/agent_runner_controller.rb` | Update — role assignment, auto_dispatch |
| `app/javascript/controllers/agent_chat_controller.ts` | Minor — agentName data attribute may need updating |
| Tests | Update all chat-related tests |

## Verification

- Human sends message to agent — agent responds via agent-runner (existing flow works)
- Human sends message to external agent — saved, broadcast, no dispatch
- Agent sends message to human via API — saved, broadcast
- Human sends message to human — saved, broadcast, no dispatch
- Social proximity contacts appear in sidebar
- Old chat sessions still work after migration
- ActionCable delivers messages to both participants
- Markdown UI works for all participant types
