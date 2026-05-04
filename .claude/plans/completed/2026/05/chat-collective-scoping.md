# Chat Collective Scoping (Completed 2026-05-03)

## Problem

Chat messages are private 1:1 conversations, but they were scoped to the tenant's main collective. Adding event tracking (`include Tracked`) would have made `chat_message.created` events visible to every automation rule in the main collective — any member could set up a webhook triggered by other people's private messages.

## Solution

Each chat session gets a dedicated collective (`collective_type: "chat"`) with only the two participants as members. The existing `AutomationDispatcher` collective scoping enforces chat privacy automatically.

### How it works

1. **`ChatSession.find_or_create_between`** creates a chat collective per session via `create_with_chat_collective` (private). Both participants are added as `CollectiveMember`s. Uses `tenant_scoped_only` to find existing sessions across collectives.

2. **`ChatsController.find_partner_and_session`** switches thread context to the chat collective via `Collective.set_thread_context`. All subsequent queries, message creation, and event tracking for that request are scoped to the chat collective.

3. **`ChatMessage` includes `Tracked`**, firing `chat_message.created` events. Events inherit `Collective.current_id` from thread context (set by the controller). The `created_by` method delegates to `sender` for the event actor.

4. **Cross-collective queries** in `load_chat_partners` and `sort_chat_partners` use `ChatSession.unscope_collective` and `chat_messages.unscope(where: :collective_id)` since they need to list sessions across all chat collectives.

5. **Agent runner controller** sets `Collective.set_thread_context` before creating agent chat messages, ensuring events are scoped correctly.

### Scope rename: `not_private_workspace` → `listable`

Replaced the negative filter with a positive one (`where(collective_type: "standard")`). Any new non-standard collective type is hidden by default. Updated 15+ call sites across controllers, views, and models.

### Validations added

- `Collective`: `collective_type` must be in `%w[standard private_workspace chat]`
- `ChatSession`: collective must be a chat collective; participants must be in canonical UUID order
- `ChatMessage`: `collective_id` must match `chat_session.collective_id`

### Collective guardrails

- No identity user created for chat collectives
- `billing_exempt: true`, settings locked down (unlisted, invite_only)
- Membership limited to 2 users; invites blocked

### Other changes

- Simplified `Tenant#create_private_workspace_for!` — removed unnecessary `Collective.set_thread_context` save/restore since `add_user!` passes tenant/collective explicitly via associations
- Migration creates chat collectives for all existing chat sessions

## Key files

| File | Role |
|------|---------|
| [chat_session.rb](app/models/chat_session.rb) | Create chat collective on session creation, validations |
| [chat_message.rb](app/models/chat_message.rb) | Tracked events, collective validation |
| [collective.rb](app/models/collective.rb) | chat type, listable scope, guardrails |
| [chats_controller.rb](app/controllers/chats_controller.rb) | Context switching, unscoped cross-collective queries |
| [agent_runner_controller.rb](app/controllers/internal/agent_runner_controller.rb) | Context switch for agent messages |
