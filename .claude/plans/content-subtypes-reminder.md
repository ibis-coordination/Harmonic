# Content Subtypes — Reminder Note

## Context

A "reminder" note is a text note that resurfaces via the existing reminder infrastructure. When created, it schedules a reminder through `ReminderService`. When the reminder fires, it creates a NoteHistoryEvent of type `"reminder"` which appears in the collective timeline/feed as a reference back to the original note.

The note itself stays in its original cycle. The reminder event is what appears in the current feed.

Recurring reminders are out of scope for this iteration — the existing `ReminderService` is one-shot. Can revisit later.

**Depends on:** [Foundation](content-subtypes-foundation.md)

## Existing Infrastructure (already built)

- **`ReminderService.create!`** — creates Notification + NotificationRecipient with `scheduled_for`
- **`ReminderDeliveryJob`** — cron job (every minute) finds due reminders, delivers them
- **`NotificationRecipient`** — has `scheduled_for`, scopes: `.scheduled`, `.due`
- **Time parsing** — ISO 8601, unix timestamps, relative ("1h", "2d", "1w"), datetime-local
- **Rate limits** — max 50 per user, 10 per hour, 90 days out
- **NoteHistoryEvent** — existing model with types: "create", "update", "read_confirmation"

## Database Migration

```ruby
add_column :notes, :reminder_notification_id, :uuid, null: true
add_foreign_key :notes, :notifications, column: :reminder_notification_id
add_index :notes, :reminder_notification_id, where: "reminder_notification_id IS NOT NULL"
```

Links the note directly to its scheduled Notification. Null for all non-reminder notes. Enables direct cancellation and status checks without URL matching.

## How It Works

1. User creates a reminder note with a `scheduled_for` time
2. `ReminderService.create!` schedules the reminder (existing flow)
3. When the reminder fires (via `ReminderDeliveryJob`), it:
   - Delivers the notification as usual (in-app, email per user prefs)
   - Creates a NoteHistoryEvent with event_type `"reminder"` on the note
4. The collective timeline/feed includes recent reminder events, rendered as "Reminder: [note title]" linking back to the original note
5. The note itself stays in its original cycle — only the reminder event appears in the current feed

## Model Changes

### Note (`app/models/note.rb`)
- `belongs_to :reminder_notification, class_name: "Notification", optional: true`
- Helper: `reminder_scheduled_for` — returns `reminder_notification.notification_recipients.first.scheduled_for`
- Helper: `reminder_pending?` — checks if the notification recipient is still pending
- `cancel_reminder!` — calls `ReminderService.delete!` on the recipient, nullifies `reminder_notification_id`
- On soft delete: cancel any pending reminder via `cancel_reminder!`

### NoteHistoryEvent (`app/models/note_history_event.rb`)
- Add `"reminder"` to valid event types

### Feed query changes
- The feed (PulseController) currently only shows Notes/Decisions/Commitments created within the cycle
- Add: also include NoteHistoryEvents of type `"reminder"` created within the cycle, rendered as feed entries pointing to the original note

## Integration with ReminderDeliveryJob

The existing `ReminderDeliveryJob` (`app/jobs/reminder_delivery_job.rb`) needs a hook: when delivering a reminder that is linked to a note (via `Notification` → `Note.where(reminder_notification_id: notification.id)`), also create the NoteHistoryEvent. This is the only change to the existing job.

## Controller Changes

### NotesController (`app/controllers/notes_controller.rb`)
- `new`: accept `?subtype=reminder`
- `create`: accept `scheduled_for` param, call `ReminderService.create!` after note creation
- `show`: display scheduled/delivered status in note history

## View Changes

### Creation form (`app/views/notes/new.html.erb`)
- When "Reminder" selected: show datetime picker for `scheduled_for`
- Reuse time parsing from NotificationsController

### Show page (`app/views/notes/show.html.erb`)
- Show "Reminder scheduled for: [date/time]" if pending
- Show "Reminded on: [date/time]" in history log if delivered
- Otherwise renders like a normal text note

### Feed (`app/components/feed_item_component.rb` + template)
- Reminder events render as a distinct feed entry: "Reminder: [note title]" with a link to the note
- Type label: "Reminder"

### ResourceHeaderComponent
- Type label: "Reminder"

## Out of Scope (future iteration)

- Recurring reminders (repeat at intervals)
- Rescheduling from the note show page
- Multiple reminders per note

## Testing

- Model: creating reminder note schedules via ReminderService, soft deleting cancels reminder
- NoteHistoryEvent: "reminder" event type created on delivery
- Feed: reminder event appears in current cycle's feed
- Controller: create reminder note with scheduled_for, show page displays status

## Help Documentation

After actions and interfaces are implemented:
- Add help content explaining reminder notes (scheduling, how resurfacing works)
- Update any existing help pages that reference notes

## Verification

```bash
docker compose exec web bundle exec rails test test/models/note_test.rb test/models/note_history_event_test.rb test/controllers/notes_controller_test.rb
docker compose exec web bundle exec rubocop
```
Manual: create a reminder note with a near-future time, wait for delivery, verify notification appears AND reminder event shows in the feed/timeline.
