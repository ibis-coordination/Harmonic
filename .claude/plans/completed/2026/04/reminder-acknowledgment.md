# Reminder Acknowledgment

## Context

Currently, notes have a "Confirm Read" system where users acknowledge they've read a note. For reminder notes, we need a similar but distinct interaction: an "Acknowledge Reminder" button that only appears *after* the reminder has fired, letting recipients confirm they've seen the reminder. This creates a `reminder_acknowledged` NoteHistoryEvent, distinct from `read_confirmation`.

The existing confirm read flow: button click → JS POST → controller → `note.confirm_read!` → NoteHistoryEvent → TracksUserItemStatus → partial re-renders.

## Requirements

- **Before reminder fires**: normal "Confirm Read" button/action is available (same as any text note)
- **After reminder fires**: "Confirm Read" goes away, replaced by "Acknowledge Reminder" button/action
- Clicking creates a `reminder_acknowledged` NoteHistoryEvent
- If the note is updated after acknowledgment, the button reappears (same pattern as confirm read reconfirm)
- The acknowledge count is visible (like confirmed_reads count)
- **Markdown UI**: `confirm_read` action only available when reminder has NOT fired; `acknowledge_reminder` action only available when reminder HAS fired
- Agent action: `acknowledge_reminder` on reminder note show page (conditional on `reminder_delivered?`)

## Implementation

### 1. NoteHistoryEvent: add `reminder_acknowledged` event type

**Modify**: `app/models/note_history_event.rb`
- Add `"reminder_acknowledged"` to the validation inclusion list (line 17)
- Add description case: `"acknowledged this reminder"`
- Add to `user_item_status_updates` — same pattern as `read_confirmation` (marks user as having read)

### 2. Note model: `acknowledge_reminder!` and helpers

**Modify**: `app/models/note.rb`
- `acknowledge_reminder!(user)` — mirrors `confirm_read!`, creates `reminder_acknowledged` event. Checks for existing acknowledgment, handles re-acknowledgment after update.
- `reminder_acknowledgments` — count of distinct users who acknowledged (mirrors `confirmed_reads`)

### 3. NoteReader: reminder acknowledgment state

**Modify**: `app/models/note_reader.rb`
- `acknowledged_reminder?` — has the user acknowledged?
- `acknowledged_but_note_updated?` — acknowledged but note updated since
- `last_acknowledged_at` — timestamp of last acknowledgment

### 4. Confirm partial: conditional rendering

**Modify**: `app/views/notes/_confirm.html.erb`
- When `@note.is_reminder? && @note.reminder_delivered?`: render acknowledgment UI instead of confirm read
  - Button text: "Acknowledge Reminder"
  - Icon: `bell` instead of `book`
  - Message: "This reminder has fired. Acknowledge to confirm you've seen it."
  - Re-acknowledge message: "Note updated since you last acknowledged. Re-acknowledge to confirm."
- When `@note.is_reminder? && !@note.reminder_delivered?`: render normal confirm read UI (same as text notes)

### 5. Controller: acknowledge_reminder action

**Modify**: `app/controllers/notes_controller.rb`
- `acknowledge_reminder` — same flow as `confirm_read`, calls `note.acknowledge_reminder!(current_user)`
- `describe_acknowledge_reminder` — action description

### 6. ApiHelper: acknowledge_reminder

**Modify**: `app/services/api_helper.rb`
- `acknowledge_reminder` — mirrors `confirm_read`, calls `note.acknowledge_reminder!`

### 7. Routes

**Modify**: `config/routes.rb`
- `post '/actions/acknowledge_reminder' => 'notes#acknowledge_reminder'`
- `get '/actions/acknowledge_reminder' => 'notes#describe_acknowledge_reminder'`

### 8. ActionsHelper: action definitions and conditional visibility

**Modify**: `app/services/actions_helper.rb`
- Add `acknowledge_reminder` action definition
- Add as conditional action on note show page (condition: `is_reminder? && reminder_delivered?`)
- Make `confirm_read` conditional for reminder notes: hide when `is_reminder? && reminder_delivered?`
  - Add `CONFIRM_READ_CONDITION` that returns false for delivered reminders
  - Move `confirm_read` from always-shown actions to conditional actions with this condition

### 9. JS: reuse note controller

The existing `note_controller.ts` `confirm()` method posts to whatever URL is in `confirmButtonTarget.dataset.url`. By setting the URL to `/actions/acknowledge_reminder` in the template, the same JS handles both flows — no JS changes needed.

The controller action returns the re-rendered `_confirm.html.erb` partial, which the JS replaces in the DOM.

## Files Changed

| File | Action |
|------|--------|
| `app/models/note_history_event.rb` | Add `reminder_acknowledged` event type |
| `app/models/note.rb` | Add `acknowledge_reminder!`, `reminder_acknowledgments` |
| `app/models/note_reader.rb` | Add `acknowledged_reminder?`, `acknowledged_but_note_updated?` |
| `app/views/notes/_confirm.html.erb` | Conditional rendering for reminder acknowledgment |
| `app/controllers/notes_controller.rb` | Add `acknowledge_reminder` action |
| `app/services/api_helper.rb` | Add `acknowledge_reminder` |
| `app/services/actions_helper.rb` | Add action definition + conditional wiring |
| `config/routes.rb` | Add acknowledge_reminder routes |
| `test/models/note_test.rb` | Tests for acknowledge_reminder! |
| `test/models/note_reader_test.rb` | Tests for acknowledgment state |
| `test/controllers/notes_controller_test.rb` | Controller tests |

## Verification

```bash
docker compose exec web bundle exec rails test test/models/note_test.rb test/models/note_reader_test.rb test/controllers/notes_controller_test.rb
docker compose exec web bundle exec srb tc
```

Manual: Create a reminder, wait for it to fire, verify "Acknowledge Reminder" button appears, click it, verify it's recorded. Edit the note, verify button reappears.
