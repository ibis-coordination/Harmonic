# Phase 2: Phased Deletion

Add a 30-day grace period between user-initiated soft-delete and permanent hard-delete. Phase 2's auto hard-delete pipeline applies to **Notes only**; `Decision` and `Commitment` soft-delete works (grace period, accessor masking, undo) but never auto-hard-deletes — their deletion semantics are a separate design conversation deferred to a follow-up phase.

## Context

Today's `SoftDeletable#soft_delete!` is misleadingly named: it sets `deleted_at` **and immediately scrubs content** (writes `[deleted]` over titles/text via `scrub_content!`). There is no grace period, no undo, and no hard-delete pipeline. A "30-day undo" on top of the current scheme would be hollow because the content is gone the moment soft-delete runs.

`DataDeletionManager` has two known bugs (originally captured as `skip`'d tests in `test/services/data_deletion_manager_test.rb`):
- `delete_collective!` doesn't include `Event` in its deletion list → FK violation on `events.collective_id`.
- Child records (`Option`, `Vote`, `DecisionParticipant`, `CommitmentParticipant`, `DecisionAuditEntry`) can drift from their parent's `collective_id`, evading collective-scoped cleanup.

Both bugs are prerequisites for the hard-delete pipeline.

## Resolved decisions

### Grace-period content semantics

`soft_delete!` becomes purely metadata — sets `deleted_at`, `deleted_by_id`, and (for models that participate in auto hard-delete) `hard_delete_after`. Removes from search index, unpins. **No DB content scrubbing.** Content is preserved at rest during the grace period, so undo is just clearing timestamps.

### Defense-in-depth via accessor masking

Override the content attribute readers on each soft-deletable model so that when `deleted?` is true they return `[deleted]` (or `nil` for `table_data`), even though the DB still has the real values. `raw_*` escape hatches (`raw_title`, `raw_text`, `raw_question`, `raw_description`, `raw_table_data`) read the real values for legitimate consumers (`content_snapshot`, admin recovery, undo verification).

### Soft-delete behavior (Notes)

From the user's perspective, soft-delete **is** deletion. It:
- Sets `deleted_at`, `deleted_by_id`, `hard_delete_after = now + 30 days`
- Hides the note from all default queries (via `default_scope`)
- Masks `title`, `text`, `table_data` via accessor overrides so content is no longer accessible to any reader path
- Removes the note from the search index
- Cancels any scheduled reminder for the note
- Unpins the note from its collective

Undo is possible within the 30-day window.

### Hard-delete-or-tombstone (decided at expiry, Notes only)

When `hard_delete_after` passes, the `HardDeleteExpiredRecordsJob` calls `DataDeletionManager.system_finalize_note!(note:)`, which inspects the note for **non-creator-owned associated records**:

- Child comments (`subtype = "comment"` notes with `commentable_id` pointing at the parent) created by anyone other than the note's creator
- `NoteHistoryEvent` rows where `user_id != note.created_by_id` (read confirmations and reminder acknowledgments by other users)
- `Link` rows where the *other* end of the link belongs to a note owned by someone other than the creator (i.e. another user referenced this note)

**If any such records exist**: tombstone — null `title`/`text`/`table_data` via `update_columns`, purge attachments, set `tombstoned_at`. The note row remains in the DB so external FK references stay valid. B's comment, B's read confirmation, and B's incoming link all continue to resolve to a real (but content-stripped) parent row.

**If no such records exist**: hard-delete — destroy the row entirely. The cascade also clears A's own `NoteHistoryEvent` rows and `Link` rows (existing `cascade_delete_note` logic).

The decision is made *at expiry*, not at soft-delete. A note with no other-user activity at delete time may still tombstone if other-user activity has accrued before the grace period ends. The check happens inside the same transaction as the finalize action.

### Why Notes only

For `Decision` and `Commitment`, the parent record is a *container* for collectively-authored data (options, votes, audit-chain entries, participants). The question/description are A's contribution; everything else belongs to other users. Nulling the question would render every existing vote semantically meaningless (`B voted accept on [deleted]`) and the audit chain pins option titles via hashed `option_title` fields, so option content can't be altered without destroying the chain.

That ambiguity ("does a Decision belong to its creator once others engage?") is a real philosophy question we shouldn't half-answer inside this PR. Scope decision: `Decision` and `Commitment` still get the grace-period soft-delete machinery (visibility hidden, content masked, undo within grace period) but the auto hard-delete job never picks them up. Engagement-gating, withdrawal semantics, and audit-chain preservation become a focused follow-up.

### participates_in_hard_delete

`SoftDeletable` exposes a `participates_in_hard_delete` class-level opt-in. Only `Note` opts in. For non-participating models, `soft_delete!` does not set `hard_delete_after`, and `undo_delete!` does not raise on time-based grounds — undo remains possible indefinitely.

### DataDeletionManager API

- Existing `delete_note!` / `delete_decision!` / `delete_commitment!` instance methods are unchanged — console admin nuke remains available.
- New `DataDeletionManager.system_finalize_note!(note:)` class method dispatches at expiry: tombstones if other-user references exist, otherwise destroys via the existing cascade. Only system entry point this PR introduces.

### Bug fixes

Land in the same PR as prerequisite commits before the grace-period machinery.

## Implementation plan

### ✅ Commit 1 — Bug fix: add Event to `delete_collective!` cascade

Clear `Event` (and its dependent `Notification`/`NotificationRecipient`/`WebhookDelivery` rows) before the rest of the cascade. Replaces the `skip`'d BUG test with a real reproduction.

### ✅ Commit 2 — Validate parent/child `collective_id` consistency

Add `CollectiveIdMatchesParent` concern. Include in `Option`, `Vote`, `DecisionParticipant`, `CommitmentParticipant`, `DecisionAuditEntry`. `NoteHistoryEvent`/`ChatMessage`/`AutomationRuleRun` already have inline equivalents.

### ✅ Commit 3 — Migration: add `hard_delete_after` to soft-deletable tables

Indexed datetime on `notes`, `decisions`, `commitments`. Backfills existing soft-deleted rows.

### ✅ Commit 4 — Rework `SoftDeletable#soft_delete!` + accessor masking

`soft_delete!` becomes metadata-only. Accessor masking on Note/Decision/Commitment, with `raw_*` escape hatches. `undo_delete!` added. `scrub_content!` removed; reminder cancellation moved to `on_soft_delete` hook.

### Commit 5 — `participates_in_hard_delete` opt-in + Note tombstone schema

- Add `participates_in_hard_delete` class attribute to `SoftDeletable`.
- Have `Note` opt in.
- Update `soft_delete!` to only set `hard_delete_after` when the model opts in.
- Update `undo_delete!` to only enforce the grace-period cutoff when the model opts in.
- Update tests: remove `hard_delete_after` assertions from Decision/Commitment soft-delete tests.
- Add migration: `tombstoned_at :datetime` column on `notes` (indexed).

### Commit 6 — `system_finalize_note!` on DataDeletionManager

Class method that, inside a transaction:
- Inspects the note for non-creator-owned references (child comments, history events by other users, links from other users' notes).
- **If any exist**: tombstone — `update_columns(title: nil, text: nil, table_data: nil, tombstoned_at: Time.current)`. Purge `attachments` if present. Leave NoteHistoryEvent rows, Link rows, child comments untouched.
- **If none exist**: call existing private `cascade_delete_note` (destroys row + A's own NoteHistoryEvent/Link rows).

The other-user-reference predicates live as small private class methods (`has_other_user_comments?`, `has_other_user_history?`, `has_other_user_link?`) so they're independently testable.

### Commit 7 — `HardDeleteExpiredRecordsJob`

`class HardDeleteExpiredRecordsJob < SystemJob`. Daily schedule. Scoped to `Note` only. Across all tenants, finds notes where `hard_delete_after < Time.current AND tombstoned_at IS NULL`, calls `DataDeletionManager.system_finalize_note!(note:)` on each. One-record-per-transaction so a failure on one note doesn't poison the batch.

### Commit 8 — Tests

- `soft_deletable_test.rb`: tombstoned? predicate, undo behavior under non-participating model, `participates_in_hard_delete` semantics.
- `data_deletion_manager_test.rb`: `system_finalize_note!` — tombstones when other-user comments exist; tombstones when other-user read confirmation exists; tombstones when other-user link exists; hard-deletes when only creator-owned references exist; preserves children/history/links on tombstone; sets tombstoned_at.
- `hard_delete_expired_records_job_test.rb`: finalizes eligible notes, skips fresh ones, skips already-tombstoned, cross-tenant safe, one-failure-doesn't-block-rest.

### Commit 9 — Plan doc cleanup

Update `data-lifecycle-management.md` to reflect Phase 2 status (Notes-only hard-delete shipped; Decision/Commitment hard-delete deferred). Move this plan to `completed/2026/05/phased-deletion.md` on PR-merge.

## Risks / things to watch

- **Decision/Commitment soft-delete is open-ended**: with `participates_in_hard_delete = false`, a soft-deleted Decision sits indefinitely. `default_scope` hides it from feeds, undo works forever. There's no UI today that surfaces "your soft-deleted decisions" — so they're effectively trash that the user can only get back to via the URL. Acceptable as an interim; the follow-up phase needs to address it.
- **Tombstone UX for orphan comments**: when B's comment's `commentable` returns a tombstoned note, controllers/views need to render `[deleted]` instead of crashing or returning 404. Tombstoned notes still have `deleted_at` set so the accessor masking returns `[deleted]` and `default_scope` hides them from listings — but `with_deleted` lookups will find the row. Verify that existing rendering paths for "view a note with comments" handle a deleted (with_deleted) parent gracefully.
- **Hard-delete-or-tombstone decision is racy at the boundary**: a non-creator user could add a read confirmation in the ~minute between the job's predicate check and the row deletion. Mitigation: do the predicate check inside the same transaction as the finalize action; lock the note row with `note.lock!` before the check.
- **Attachment purging timing**: attachments preserved during grace period, purged at tombstone time. If a note has multi-GB attachments, the tombstone update gets slow. Acceptable for now — most notes have small attachments — but watch for it.

## Out of scope (deferred)

- Decision/Commitment hard-delete and tombstone semantics — needs design conversation about ownership-after-engagement, withdrawal, audit chain.
- Close-on-soft-delete for Decisions/Commitments — depends on the above design.
- Per-tenant grace period configuration.
- "Deleted on DATE" placeholder UI (Phase 4 transparency).
- Account closure flow (Phase 3).
- Audit chain tombstoning for Decisions (Phase 5).
