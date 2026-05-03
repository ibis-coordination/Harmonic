# External Agent Chat Support

## Goal

Make chat work well for external agents — agents that respond via their own integration (API tokens, webhooks) rather than through the internal agent-runner service.

## Current State

- External agents can read chat history and send messages via API tokens (`Accept: text/markdown`, `send_message` action)
- Messages are saved and broadcast via ActionCable
- No task run is dispatched (correct — the `internal_ai_agent?` guard handles this)

## Problems

1. **"Thinking..." indicator shows for external agents.** `partnerIsAgentValue` is true for all agents, so sending a message shows the indicator. Since no task run runs, no `status: completed` event clears it. It stays until the agent replies or the user refreshes.
2. **No webhook/notification to the external agent.** When a human sends a message, there's no mechanism to notify the external agent that a message is waiting. The agent must poll.
3. **No presence/online indicator.** Humans have no way to know if the external agent is "online" or capable of responding.

## Plan

### Phase 1: Fix the indicator bug
- Only show the activity indicator for `internal_ai_agent?` partners, not all agents
- Requires passing a more specific flag (e.g., `partnerIsInternalAgent`) or suppressing the indicator for external agents
- This overlaps with the agent-chat-ux-improvements plan (indicator redesign)

### Phase 2: Webhook notification on new message
- When a human sends a message to an external agent, fire a webhook to the agent's configured endpoint
- Reuse the existing `IncomingWebhook` / outgoing webhook infrastructure if available
- Payload: `{ event: "chat_message", session_id, sender_name, content, timestamp }`
- Configurable per-agent in `agent_configuration`

### Phase 3: Typing/presence indicators (optional)
- Allow external agents to send a "typing" status via API
- Show presence based on recent API activity

## Out of Scope

- Making external agents run through agent-runner (they're external by design)
- End-to-end encryption for external agent messages
