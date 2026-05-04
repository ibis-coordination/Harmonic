# External Agent Chat Support

## Goal

Make chat work well for external agents — agents that respond via their own integration (API tokens, webhooks) rather than through the internal agent-runner service.

## Current State

- External agents can read chat history and send messages via API tokens (`Accept: text/markdown`, `send_message` action)
- Messages are saved and broadcast via ActionCable
- No task run is dispatched (correct — the `internal_ai_agent?` guard handles this)
- "Thinking..." indicator only shows for internal agents (fixed)
- Each chat session has a dedicated chat collective with only the two participants as members
- `ChatMessage` includes `Tracked`, firing `chat_message.created` events scoped to the chat collective

## Phase 1: Fix the indicator bug — Done

"Thinking..." only shows for `internal_ai_agent?` partners.

## Phase 2: Webhook notification on new message — Done (infrastructure)

The automation system already supports this end-to-end:

1. Human sends message → `chat_message.created` event fires in the chat collective
2. `AutomationDispatcher` finds matching rules — a rule matches if its owner (user or agent) is a member of the chat collective
3. A webhook action POSTs to the external agent's endpoint with HMAC signing, retry logic, etc.

**Setup:** The external agent's owner creates an automation rule with:
- `trigger_type: "event"`, `trigger_config: { event_type: "chat_message.created" }`
- A `webhook` action pointing to the agent's endpoint

The rule can be created in any collective — it will match events from any chat collective where the owner is a member.

**Remaining work:** There's no convenience UI to auto-configure this when creating an external agent. Currently requires manual automation rule setup. Could add a "webhook URL" field to agent configuration that auto-creates the rule.

## Phase 3: Typing/presence indicators (future)

- Allow external agents to send a "typing" status via API
- Show presence based on recent API activity

## Out of Scope

- Making external agents run through agent-runner (they're external by design)
- End-to-end encryption for external agent messages
