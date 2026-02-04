---
passing: true
last_verified: 2026-02-04
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
   - An unread count display (or "All caught up!" if empty)
   - A list of notifications (or empty state message)
   - "Schedule Reminder" button

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

### Part 4: Dismissing Notifications

1. Navigate to `/notifications`
2. Find a notification and click the dismiss (X) button
3. Verify the notification is removed from the list

### Part 5: Dismiss All

1. Have multiple notifications
2. Navigate to `/notifications`
3. Click the "Dismiss all" button (only visible when notifications exist)
4. Verify all notifications are dismissed
5. Verify the page shows "All caught up!"

### Part 6: Schedule Reminder

1. Navigate to `/notifications`
2. Click "Schedule Reminder"
3. Fill in the reminder form with title and scheduled time
4. Submit and verify the reminder appears in "Scheduled Reminders" section
5. Delete the reminder and verify it's removed

### Part 7: Markdown API Access

1. Navigate to `/notifications` with `Accept: text/markdown` header
2. Verify the response is in markdown format with:
   - Table of notifications with title, time, and action links
   - Actions section with links to dismiss and dismiss_all

### Part 8: Unread Count API

1. Navigate to `/notifications/unread_count` with `Accept: application/json` header
2. Verify the response is JSON with a `count` field showing the unread count

## Checklist

- [x] Notifications page loads successfully at `/notifications`
- [x] Unread count is displayed correctly
- [x] Notifications list shows notification title, body preview, and time
- [x] @mentions in notes trigger mention notifications
- [x] Actors are not notified when they mention themselves
- [x] `dismiss` action dismisses a notification
- [x] `dismiss_all` action dismisses all notifications
- [x] Schedule Reminder feature works
- [x] Delete scheduled reminder works
- [x] Markdown API returns properly formatted notification list
- [x] JSON API returns unread count
- [x] Unauthenticated users are redirected to login

## Notes

- Notifications are created asynchronously via `NotificationDeliveryJob`
- The notification system supports multiple channels (in_app, email) but only in_app is currently displayed
- Notification types include: mention, comment, participation, system, reminder
- When using the MCP server, always navigate to the resource page (e.g., `/notifications`) before executing actions. The MCP constructs action URLs from the current path.
- Scheduled reminders appear in a separate "Scheduled Reminders" section and are not counted in the unread count until they become due
