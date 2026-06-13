# Auto-confirm read on note creation and commenting

## Goal

Read confirmations on notes should be created implicitly in two cases:

1. **Note creator** is auto-confirmed as a reader of the note they create.
2. **Commenter** is auto-confirmed as a reader of the note they comment on.

All other read confirmations remain manual. The existing HTML "must confirm to see comments" gate stays in place for passive readers.

## Motivation

- Requiring the creator to confirm reading their own note is nonsensical UX.
- The HTML UI gates commenting behind a read confirmation: in [_confirm.html.erb](app/views/notes/_confirm.html.erb), the `pulse_comments` partial is only rendered when `@note_reader.confirmed_read?` is true (via `_history` → `_history_log`). The markdown UI ([show.md.erb:57](app/views/notes/show.md.erb#L57)) renders the comments section unconditionally, so a user can `POST /actions/add_comment` without ever confirming a read. Auto-confirming on comment closes that asymmetry by making the read implicit on the markdown side.

## Implementation

### Single change point

Both HTML and markdown comment paths funnel through `ApiHelper#create_note(commentable:)` ([application_controller.rb:1162](app/controllers/application_controller.rb#L1162) for the HTML form via `create_comment`, [:1192](app/controllers/application_controller.rb#L1192) for the markdown `add_comment` action). Both call `Note.create!`. A single model `after_create` callback covers both interfaces.

Extend the existing `after_create` in [app/models/note.rb:56-63](app/models/note.rb#L56-L63):

```ruby
after_create do
  NoteHistoryEvent.create!(
    note: self,
    user: created_by,
    event_type: "create",
    happened_at: created_at,
  )
  confirm_read!(created_by)
  commentable.confirm_read!(created_by) if commentable.is_a?(Note)
end
```

`Note#confirm_read!` is already idempotent (returns the existing confirmation if `happened_at > updated_at`) and clears the memoized `@confirmed_reads` count.

### Gating

- `commentable.is_a?(Note)` — only auto-confirm on the parent when the parent is a Note. Decision, Commitment, and RepresentationSession don't have `confirm_read!` and don't have the read-confirmation concept.
- No need to guard against `created_by` being nil — `belongs_to :created_by` is required.
- No need to guard against the user-block case for commenting — `check_not_blocked_for_comment!` runs in `ApiHelper#create_note` before `Note.create!`, so blocked comments never reach the callback.

### No view changes

The HTML gate stays as-is. With the creator auto-confirmed, the creator's own note immediately shows the comments section instead of a "Confirm Read" prompt — the desired behavior, for free.

## Decision: commenting on a note that was updated since the commenter's last manual confirmation

Scenario: B manually confirmed at t=1. A updates the note at t=2. B comments via markdown at t=3.

`confirm_read!`'s existing logic: the existing confirmation is from t=1, and t=1 is not greater than `updated_at`=t=2, so it creates a fresh confirmation row at t=3. Effect: B is marked as having confirmed the *updated* state of the note.

**Keep this behavior.** Two reasons:

1. **It matches the HTML gate's outcome.** In HTML, after an update, [_confirm.html.erb:66-83](app/views/notes/_confirm.html.erb#L66-L83) shows "Reconfirm to acknowledge the changes" instead of the comment form — a non-blocked HTML commenter cannot comment without first reconfirming the post-update state. Auto-confirming on markdown comment produces the same end state.
2. **`confirm_read!`'s idempotency semantics are already the right semantic for "commented = engaged with current state."** Inventing a "only-if-no-existing-confirmation" variant would diverge from how manual confirmation behaves and leave the markdown commenter in a "stale confirmation" state that misrepresents their engagement.

The known cost: a markdown caller who comments based on a cached/old view (never actually saw the update) gets silently marked as having confirmed the new state. This is no worse than the existing markdown `POST /actions/confirm_read`, which already accepts confirmation with no proof of reading.

## Tests

### New tests (in [test/models/note_test.rb](test/models/note_test.rb))

- Creating a note creates a `read_confirmation` event for the creator
- `confirmed_reads` is 1 immediately after a note is created
- `user_has_read?(creator)` returns true right after creation; creator appears in `where_user_has_read(user: creator)`
- Creating a comment on a Note creates a `read_confirmation` on the parent for the commenter
- Creating a comment on a Decision does not error and does not create a read confirmation on the Decision
- Idempotency: a commenter who already manually confirmed (with the note not since updated) does not get a duplicate confirmation row
- Post-update behavior: B confirms, A updates the note, B comments — B has a fresh confirmation dated after the update

### Existing tests likely to break

Audit during implementation; likely candidates:

- Anything asserting an exact `note_history_events.count` immediately after `Note.create!` — expect 2 (create + read_confirmation) instead of 1; expect 3 for a comment (create + commenter's read on the comment itself + commenter's read on the parent)
- Anything asserting `confirmed_reads == 0` right after creating a note
- Any test that creates a note and then asserts the readers list is empty
- [test/integration/markdown_ui_test.rb:439-449](test/integration/markdown_ui_test.rb#L439) `add_comment` test — extend to assert the parent note's `confirmed_reads` incremented (don't replace the existing assertions)

The fix is to update expected counts, not suppress the new behavior.

### Out of scope

- The dead `creator_can_skip_confirm?(_user)` method ([note.rb:271-275](app/models/note.rb#L271-L275)) has no callers. Delete it in this PR — auto-confirmation makes the question it asks moot.
- `interaction_count` ([note.rb:233-235](app/models/note.rb#L233-L235)) is also dead code (no callers in app/ or test/). Leave it alone or delete it; if leaving it, the "subtract the create event" arithmetic is now off by one but it doesn't matter because nothing reads it. Prefer deleting both this and `creator_can_skip_confirm?` in one go.

## Development workflow

Red-green TDD per project convention:

1. Write the new model tests; run them — they fail.
2. Add the two lines to the `after_create` callback; new tests pass.
3. Run the targeted note / note_history_event / note_reader / api_helper test files; fix breakage by adjusting expected counts.
4. Run the markdown UI integration test file; extend the `add_comment` test.
5. Optionally delete `creator_can_skip_confirm?` and `interaction_count`.
6. Run RuboCop and Sorbet on touched files.
7. Push; CI runs the full suite.

CHANGELOG entry goes in post-merge, not in the feature branch.
