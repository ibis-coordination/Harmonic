---
passing: true
last_verified: 2026-06-11
verified_by: Claude Fable 5
---

# Test: Notifications UI

Verifies that users can view, manage, and interact with notifications through both the HTML UI and markdown API, including the unread / read / dismissed lifecycle.

## Prerequisites

- A logged-in user account
- At least one collective with API enabled where the user is a member
- Another user in the same tenant to test @mentions and chat

## Steps

### Part 1: Viewing Notifications

1. Navigate to `/notifications`
2. Observe the notifications page loads with:
   - A header showing "Notifications"
   - An unread count display (or "All caught up!" if empty)
   - A list of notifications (or empty state message)
   - "Schedule Reminder" button

### Part 2: Creating a Notification via @mention

1. Navigate to a collective where you are a member (e.g., `/collectives/your-collective`)
2. Go to the note creation page (`/collectives/your-collective/note`)
3. Execute the `create_note` action with text that mentions another user: `Hey @other-user-handle, check this out!`
4. The mentioned user should receive a notification

### Part 3: Viewing Notifications (as mentioned user)

1. Log in as the mentioned user
2. Navigate to `/notifications`
3. Observe the new "mention" notification appears with:
   - Title indicating who mentioned them
   - Body preview of the note text
   - Link to the note
   - An unread indicator dot and highlighted styling

### Part 4: Marking Read

1. With unread notifications present, observe the badge count in the top nav and the "(N)" page title
2. Click the mark-read (check) button on one notification
3. Verify the row stays in the list but loses its indicator dot and highlight, and the badge count decrements
4. Click a notification's title link
5. Verify you navigate to the linked content and, on returning to `/notifications`, that notification shows as read
6. Click "Mark all read" in the summary row
7. Verify the badge clears to zero, all rows lose their unread styling, the "Mark all read" button disappears, and "Dismiss all" remains

### Part 5: Dismissing Notifications

1. Navigate to `/notifications`
2. Find a notification (read or unread) and click the dismiss (X) button
3. Verify the notification is removed from the list

### Part 6: Dismiss All

1. Have multiple notifications, including read ones
2. Navigate to `/notifications`
3. Click the "Dismiss all" button
4. Verify all notifications are dismissed, including read ones
5. Verify the page shows "All caught up!"

### Part 7: Chat Notifications Clear on View

1. Have another user send you a chat message
2. Verify the badge shows a new unread notification ("New message from ...")
3. Navigate to `/chat/<their-handle>` without replying
4. Verify the notification is dismissed (badge clears) — viewing the conversation acknowledges it
5. With the chat window open and the tab visible, have them send another message
6. Verify no stale notification accumulates (it is dismissed on receipt)

### Part 8: Schedule Reminder

1. Navigate to `/notifications`
2. Click "Schedule Reminder"
3. Fill in the reminder form with title and scheduled time
4. Submit and verify the reminder appears in "Scheduled Reminders" section
5. Delete the reminder and verify it's removed

### Part 9: Markdown API Access

1. Navigate to `/notifications` with `Accept: text/markdown` header
2. Verify the response is in markdown format with:
   - Table of notifications with title, status (unread/read), time, and action links
   - `mark_read` links on unread rows only
   - `mark_all_read` and `dismiss_all` links beside the unread count
   - Per-collective `mark_read_for_collective` and `dismiss_for_collective` links

### Part 10: Unread Count API

1. Navigate to `/notifications/unread_count` with `Accept: application/json` header
2. Verify the response is JSON with a `count` field showing the unread count (read notifications are not counted)

## Checklist

- [x] Notifications page loads successfully at `/notifications`
- [x] Unread count is displayed correctly and excludes read notifications
- [x] Notifications list shows notification title, body preview, and time
- [x] Unread rows show an indicator dot; read rows don't
- [x] @mentions in notes trigger mention notifications
- [x] Actors are not notified when they mention themselves
- [x] `mark_read` marks a notification read without removing it; badge decrements
- [x] Clicking a notification link marks it read
- [x] `mark_all_read` clears the badge and keeps rows visible
- [x] `dismiss` action dismisses a notification
- [x] `dismiss_all` action dismisses all notifications, including read ones
- [x] Viewing a chat dismisses notifications from that partner
- [x] Schedule Reminder feature works
- [x] Delete scheduled reminder works
- [x] Markdown API returns properly formatted notification list with read state
- [x] JSON API returns unread count
- [x] Unauthenticated users are redirected to login

## Notes

- Notifications are created asynchronously via `NotificationDeliveryJob`
- The notification system supports multiple channels (in_app, email) but only in_app is currently displayed
- Notification types include: mention, comment, participation, system, reminder, chat_message, persona_unavailable, tune_in
- Read state lifecycle: unread → read (badge quiets, row stays) → dismissed (row removed). Dismissing implies reading.
- When using the MCP server, always navigate to the resource page (e.g., `/notifications`) before executing actions. The MCP constructs action URLs from the current path.
- Scheduled reminders appear in a separate "Scheduled Reminders" section and are not counted in the unread count until they become due
- 2026-06-11 verification covered Parts 1, 4 (steps 1-3, 6-7), 5, 6, 9, 10 plus chat dismiss-on-view (Part 7 steps 1-4) via browser and markdown UI; Part 7 steps 5-6 (dismiss-on-receipt) verified via frontend unit tests only
