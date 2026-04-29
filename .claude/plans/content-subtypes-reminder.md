# Content Subtypes — Reminder Note

## Context

A "reminder" note is a text note that resurfaces via the existing reminder infrastructure. When created, it schedules a reminder through `ReminderService`. When the reminder fires, it creates a NoteHistoryEvent of type `"reminder"` which appears in the collective feed as a distinct entry linking back to the original note.

The note itself stays in its original cycle. The reminder event is what appears in the current feed.

Recurring reminders are out of scope for this iteration — the existing `ReminderService` is one-shot. Can revisit later.

**Depends on:** [Foundation](content-subtypes-foundation.md)

## Design Decisions

1. **Reminder notes replace standalone reminders.** The existing `create_reminder` / `delete_reminder` actions in ActionsHelper are retired. Reminder notes repurpose the same `ReminderService` infrastructure but wrap it in a proper note with text content, history, and feed presence.
2. **`deadline` is unrelated.** The note's `deadline` column is a separate concept. The reminder's `scheduled_for` lives on the `NotificationRecipient` and is accessed via the `reminder_notification_id` FK join. No reuse of `deadline`.
3. **Separate feed component for reminder events.** NoteHistoryEvents don't share the same interface as Notes/Decisions/Commitments. A dedicated `ReminderFeedItemComponent` renders them in the feed.
4. **Collective identity user for reminder events.** When the reminder fires, the NoteHistoryEvent's `user` is `collective.identity_user` (same pattern as automation-created items), not the note author.

## Existing Infrastructure (already built)

- **`ReminderService.create!`** — creates Notification + NotificationRecipient with `scheduled_for`
- **`ReminderDeliveryJob`** — cron job (every minute) finds due reminders, delivers them; uses `with_tenant_and_collective_context`
- **`NotificationRecipient`** — has `scheduled_for`, scopes: `.scheduled`, `.due`; statuses: pending/delivered/dismissed/rate_limited
- **Time parsing** — ISO 8601, unix timestamps, relative ("1h", "2d", "1w"), datetime-local
- **Rate limits** — max 50 per user, 10 per hour
- **NoteHistoryEvent** — existing model with types: "create", "update", "read_confirmation"
- **Subtype selector** — creation form already has Text/Table toggle; Reminder would be a third option
- **`edit_access` column** — exists on notes; reminder notes use "owner" (same as text notes)
- **Collective identity user** — `collective.identity_user` is a `collective_identity` type User; used as actor for automation-created content

## Database Migration

```ruby
add_column :notes, :reminder_notification_id, :uuid, null: true
add_foreign_key :notes, :notifications, column: :reminder_notification_id
add_index :notes, :reminder_notification_id, where: "reminder_notification_id IS NOT NULL"
```

Links the note directly to its scheduled Notification. Null for all non-reminder notes. Enables direct cancellation and status checks without URL matching.

## How It Works

1. User creates a reminder note with text content and a `scheduled_for` time
2. `ReminderService.create!` schedules the reminder (existing flow)
3. The note stores `reminder_notification_id` linking to the Notification
4. When the reminder fires (via `ReminderDeliveryJob`), it:
   - Delivers the notification as usual (in-app, email per user prefs)
   - Finds the linked note via `Note.where(reminder_notification_id: notification.id)`
   - Creates a NoteHistoryEvent with event_type `"reminder"`, user set to `collective.identity_user`
5. The collective feed includes the reminder event as a distinct entry (see Feed Integration)
6. The note itself stays in its original cycle — only the reminder event appears in the current feed

## Model Changes

### Note (`app/models/note.rb`)
- `belongs_to :reminder_notification, class_name: "Notification", optional: true`
- Predicate: `is_reminder?` (already exists from foundation — `subtype == "reminder"`)
- Helper: `reminder_scheduled_for` — returns `reminder_notification.notification_recipients.first.scheduled_for`
- Helper: `reminder_pending?` — checks if the notification recipient is still pending
- Helper: `reminder_delivered?` — checks if delivered
- `cancel_reminder!` — calls `ReminderService.delete!` on the recipient, nullifies `reminder_notification_id`
- On soft delete: cancel any pending reminder in `scrub_content!` (parallels table notes scrubbing `table_data`)

### NoteHistoryEvent (`app/models/note_history_event.rb`)
- Add `"reminder"` to valid event types (line 17)
- Add description case: `"reminder fired"`

## Feed Integration

The feed (`PulseController#build_unified_feed`) currently queries Notes, Decisions, and Commitments created within the cycle. NoteHistoryEvents are not currently in the feed.

**Approach:** Add a new query for NoteHistoryEvents of type `"reminder"` with `happened_at` within the cycle. These render as distinct feed entries via a dedicated `ReminderFeedItemComponent` — showing "Reminder: [note title]" linking back to the original note. This is additive: one more query in `build_unified_feed`, one new component.

### Changes:
- `PulseController#build_unified_feed` — add query for `NoteHistoryEvent.where(event_type: "reminder")` scoped to cycle dates, include `:note` and `note: :created_by`
- `ReminderFeedItemComponent` — new component, renders reminder events with note title, link, and reminder timestamp

## Integration with ReminderDeliveryJob

The existing `ReminderDeliveryJob` (`app/jobs/reminder_delivery_job.rb`) needs a hook after delivery (around line 104-106): when delivering a reminder whose notification is linked to a note (via `Note.where(reminder_notification_id: notification.id)`), create a NoteHistoryEvent:

```ruby
note = Note.find_by(reminder_notification_id: notification.id)
if note
  NoteHistoryEvent.create!(
    note: note,
    user: collective.identity_user,
    event_type: "reminder",
    happened_at: Time.current,
  )
end
```

This is the only change to the existing job.

## Retiring Standalone Reminders

Remove from `ActionsHelper`:
- `create_reminder` action definition (lines 555-565)
- `delete_reminder` action definition (lines 566-573)
- Any route wiring for these actions

The `ReminderService` and `ReminderDeliveryJob` stay — they're the underlying infrastructure. The `NotificationsController` reminder endpoints may also need cleanup (check if anything besides these actions uses them).

## Controller Changes

### NotesController (`app/controllers/notes_controller.rb`)
- `new`: accept `?subtype=reminder`, show datetime picker
- `create`: when subtype is "reminder", accept `scheduled_for` param, create the note, call `ReminderService.create!`, store `reminder_notification_id` on the note
- `show`: display scheduled/delivered status in note metadata
- `cancel_reminder` action: cancels a pending reminder (calls `note.cancel_reminder!`)

## View Changes

### Creation form (`app/views/notes/new.html.erb`)
- Add "Reminder" to the existing subtype selector (Text / Table / Reminder)
- When "Reminder" selected: show text area (same as text notes) + datetime picker for `scheduled_for`
- Reuse time parsing from existing reminder infrastructure

### Show page (`app/views/notes/show.html.erb`)
- Show "Reminder scheduled for: [date/time]" if pending
- Show "Reminder delivered on: [date/time]" if delivered
- Show "Cancel reminder" button if pending and user is author
- Otherwise renders like a normal text note (markdown body)

### Show page — Markdown UI (`app/views/notes/show.md.erb`)
- Include `reminder_status` and `reminder_scheduled_for` in rendered output
- Agents can see when a reminder is scheduled and whether it has fired

### Feed — `ReminderFeedItemComponent`
- New component (separate from `FeedItemComponent`)
- Renders: reminder icon, "Reminder" type label, note title as link, reminder timestamp
- Simpler than FeedItemComponent — no voting, no progress bars, no read confirmations

### ResourceHeaderComponent
- Type label: "Reminder" when `is_reminder?`

## Agent Actions (Markdown UI)

Replace the standalone `create_reminder` / `delete_reminder` actions with:

- **`create_reminder_note`** — on the note creation page; params: `text`, `title` (optional), `scheduled_for`
- **`cancel_reminder`** — on the reminder note show page; cancels a pending reminder. Conditional on `is_reminder?` and reminder being pending.

These appear in markdown frontmatter only when relevant (same conditional pattern as table note actions with `TABLE_NOTE_CONDITION`).

## Help Documentation

- Create `app/views/help/reminder_notes.md.erb` — explains what reminder notes are, how scheduling works, how resurfacing appears in the feed
- Update `app/views/help/notes.md.erb` — reference reminder subtype (already references table notes)

## Out of Scope (future iteration)

- Recurring reminders (repeat at intervals)
- Rescheduling from the note show page
- Multiple reminders per note

## Testing

- **Model**: creating reminder note with `reminder_notification_id`, `is_reminder?` predicate, `reminder_scheduled_for`, `reminder_pending?`, `reminder_delivered?`, `cancel_reminder!`, soft delete cancels pending reminder
- **NoteHistoryEvent**: "reminder" event type valid, description returns correct text
- **ReminderDeliveryJob**: creates NoteHistoryEvent with collective identity user when delivering a note-linked reminder
- **Feed**: reminder event appears in `build_unified_feed`, `ReminderFeedItemComponent` renders correctly
- **Controller**: create reminder note with `scheduled_for`, show page displays status, cancel action works
- **Agent actions**: frontmatter includes `cancel_reminder` only for pending reminder notes; `create_reminder_note` on creation page
- **Standalone removal**: old `create_reminder` / `delete_reminder` actions no longer available
- **Help pages**: reminder notes topic accessible

## Verification

```bash
docker compose exec web bundle exec rails test test/models/note_test.rb test/models/note_history_event_test.rb test/controllers/notes_controller_test.rb test/jobs/reminder_delivery_job_test.rb test/components/reminder_feed_item_component_test.rb
docker compose exec web bundle exec rubocop
docker compose exec web bundle exec srb tc
```
Manual: create a reminder note with a near-future time, wait for delivery, verify notification appears AND reminder event shows in the feed.
