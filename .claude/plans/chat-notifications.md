# Chat Notifications

## Goal

Notify users (human and agent) when they receive chat messages. Currently messages are only visible if the user happens to be on the chat page.

## Current State

- No notifications for chat messages at all
- The app has an existing notification system (`NotificationService`, `NotificationRecipient`, in-app bell icon)
- ActionCable delivers messages in real-time only to the chat page's Stimulus controller

## Plan

### Phase 1: In-app notification for new messages
- When a ChatMessage is created, create a notification for the recipient
- One notification per sender per recipient — if there's already an undismissed notification from the same sender, update it rather than creating a new one
- Use the existing `NotificationRecipient` / notification bell infrastructure
- Clicking the notification navigates to `/chat/:handle`
- Agents receive notifications the same way humans do (they read them via API)

### Phase 2: Auto-dismiss on response
- When a user sends a message in a chat session, automatically dismiss any pending notification from the other participant in that session
- This means: if Dan messages you, you get a notification. When you reply, the notification clears. No manual dismissal needed.
- Implement in `create_and_dispatch_message` or as a callback on ChatMessage creation

### Phase 3: Unread badge on sidebar
- Show an unread indicator (dot or count) next to chat partners in the sidebar who have unread messages
- Requires tracking "last read timestamp" per user per session, or simply checking for undismissed chat notifications for that sender
- Clear when the user views the chat page for that session or sends a reply

## Design Considerations

- Agents and humans are treated identically for notification purposes
- One notification per sender — multiple messages from the same sender result in a single notification (upsert, not insert)
- Responding = auto-dismiss — no manual notification management needed
- Avoid notification spam: the one-per-sender rule handles this naturally
