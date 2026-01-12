---
passing: true
last_verified: 2026-01-11
verified_by: Claude Opus 4.5
---

# Test: Notifications UI

Verifies that users can view, manage, and interact with notifications through both the HTML UI and markdown API.

## Prerequisites

- A logged-in user account
- At least one studio with API enabled where the user is a member
- Another user in the same tenant to test @mentions

## Steps

### Part 1: Viewing Notifications

1. Navigate to `/notifications`
2. Observe the notifications page loads with:
   - A header showing "Notifications"
   - An unread count display
   - A list of notifications (or "No notifications" message if empty)
   - Actions section with available actions

### Part 2: Creating a Notification via @mention

1. Navigate to a studio where you are a member (e.g., `/studios/your-studio`)
2. Go to the note creation page (`/studios/your-studio/note`)
3. Execute the `create_note` action with text that mentions another user: `Hey @other-user-handle, check this out!`
4. The mentioned user should receive a notification

### Part 3: Viewing Notifications (as mentioned user)

1. Log in as the mentioned user
2. Navigate to `/notifications`
3. Observe the new "mention" notification appears with:
   - Title indicating who mentioned them
   - Body preview of the note text
   - Link to the note
   - Unread status

### Part 4: Marking Notifications as Read

1. Navigate to `/notifications`
2. Find an unread notification and note its recipient ID from the action links
3. Execute the `mark_read` action with the notification recipient ID
4. Navigate to `/notifications` and verify the notification is now marked as read

### Part 5: Dismissing Notifications

1. Navigate to `/notifications`
2. Find a notification and note its recipient ID from the action links
3. Execute the `dismiss` action with the notification recipient ID
4. Navigate to `/notifications` and verify the notification is dismissed

### Part 6: Mark All Read

1. Have multiple unread notifications
2. Navigate to `/notifications`
3. Execute the `mark_all_read` action (no parameters needed)
4. Navigate to `/notifications` and verify all notifications are now marked as read
5. Verify the unread count shows 0

### Part 7: Markdown API Access

1. Navigate to `/notifications` with `Accept: text/markdown` header
2. Verify the response is in markdown format with:
   - Table of notifications with status, title, time, and action links
   - Actions section with links to mark_read, dismiss, and mark_all_read

### Part 8: Unread Count API

1. Navigate to `/notifications/unread_count` with `Accept: application/json` header
2. Verify the response is JSON with a `count` field showing the unread count

## Checklist

- [x] Notifications page loads successfully at `/notifications`
- [x] Unread count is displayed correctly
- [x] Notifications list shows notification title, body preview, and time
- [x] @mentions in notes trigger mention notifications
- [x] Actors are not notified when they mention themselves
- [x] `mark_read` action marks a notification as read
- [x] `dismiss` action dismisses a notification
- [x] `mark_all_read` action marks all notifications as read
- [x] Markdown API returns properly formatted notification list
- [x] JSON API returns unread count
- [x] Unauthenticated users are redirected to login

## Notes

- Notifications are created asynchronously via `NotificationDeliveryJob`
- The notification system supports multiple channels (in_app, email) but only in_app is currently displayed
- Notification types include: mention, comment, participation, system
- When using the MCP server, always navigate to the resource page (e.g., `/notifications`) before executing actions. The MCP constructs action URLs from the current path.
