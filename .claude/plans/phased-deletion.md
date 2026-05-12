# Phase 2: Phased Deletion

Add a 30-day grace period between user-initiated soft-delete and **tombstoning** of Notes (null content, preserve row). Phase 2's auto-finalize pipeline applies to **Notes only** and only tombstones — never hard-destroys the row. Hard-destroy remains available via the existing console admin `delete_note!` method.

`Decision` and `Commitment` soft-delete works (grace period, accessor masking, undo) but never auto-finalizes — their deletion semantics are a separate design conversation deferred to a follow-up phase.

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

### Tombstone (at expiry, Notes only)

When `hard_delete_after` passes, the `HardDeleteExpiredRecordsJob` calls `DataDeletionManager.system_tombstone_note!(note:)`, which:

- Nulls `title`, `text`, `table_data` via `update_columns`
- Purges attachments
- Destroys all `Link` records involving the note (links are system-generated from parsed `@`-references; they don't belong to any user, and `LinkParser` already treats soft-deleted items as unresolvable, so destroying them on tombstone keeps behavior consistent)
- Sets `tombstoned_at = Time.current`
- **Leaves the row in place** — `NoteHistoryEvent` rows, child comments, and any other records that reference the note continue to resolve

Always tombstones — no conditional logic, no audit of who-owns-what among references. The row stays forever (until an admin invokes the console `delete_note!` to nuke it). This avoids the complex "who owns this reference?" question and keeps the system pipeline minimal.

The action runs inside a transaction with a row lock on the note so concurrent updates are serialized.

### Why Notes only

For `Decision` and `Commitment`, the parent record is a *container* for collectively-authored data (options, votes, audit-chain entries, participants). The question/description are A's contribution; everything else belongs to other users. Nulling the question would render every existing vote semantically meaningless (`B voted accept on [deleted]`) and the audit chain pins option titles via hashed `option_title` fields, so option content can't be altered without destroying the chain.

That ambiguity ("does a Decision belong to its creator once others engage?") is a real philosophy question we shouldn't half-answer inside this PR. Scope decision: `Decision` and `Commitment` still get the grace-period soft-delete machinery (visibility hidden, content masked, undo within grace period) but the auto hard-delete job never picks them up. Engagement-gating, withdrawal semantics, and audit-chain preservation become a focused follow-up.

### participates_in_hard_delete

`SoftDeletable` exposes a `participates_in_hard_delete` class-level opt-in. Only `Note` opts in. For non-participating models, `soft_delete!` does not set `hard_delete_after`, and `undo_delete!` does not raise on time-based grounds — undo remains possible indefinitely.

### DataDeletionManager API

- Existing `delete_note!` / `delete_decision!` / `delete_commitment!` instance methods are unchanged — console admin nuke remains available for full row destruction.
- New `DataDeletionManager.system_tombstone_note!(note:)` class method is the only system entry point this PR introduces. Always tombstones; never destroys the row.

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

### Commit 6 — `system_tombstone_note!` on DataDeletionManager

Class method that, inside a transaction with a row lock on the note:
- Purges attachments
- Destroys all Link records involving the note
- `update_columns(title: nil, text: nil, table_data: nil, tombstoned_at: Time.current)`

`delete_note!` is refactored to share `cascade_delete_note` (private class helper) so the console admin nuke path stays available unchanged.

### Commit 7 — `HardDeleteExpiredRecordsJob`

`class HardDeleteExpiredRecordsJob < SystemJob`. Daily schedule. Scoped to `Note` only. Across all tenants, finds notes where `hard_delete_after < Time.current AND tombstoned_at IS NULL`, calls `DataDeletionManager.system_tombstone_note!(note:)` on each. One-record-per-transaction so a failure on one note doesn't poison the batch.

### Commit 8 — Tests

- `soft_deletable_test.rb`: tombstoned? predicate, undo behavior under non-participating model, `participates_in_hard_delete` semantics. (Done in commit 5.)
- `data_deletion_manager_test.rb`: `system_tombstone_note!` — nulls content fields, sets tombstoned_at, preserves row, destroys Link records, preserves NoteHistoryEvents and child comments. (Done in commit 6.)
- `hard_delete_expired_records_job_test.rb`: tombstones eligible notes, skips fresh ones, skips already-tombstoned, cross-tenant safe, one-failure-doesn't-block-rest.

### Commit 9 — Plan doc cleanup

Update `data-lifecycle-management.md` to reflect Phase 2 status (Notes-only hard-delete shipped; Decision/Commitment hard-delete deferred). Move this plan to `completed/2026/05/phased-deletion.md` on PR-merge.

## Risks / things to watch

- **Decision/Commitment soft-delete is open-ended**: with `participates_in_hard_delete = false`, a soft-deleted Decision sits indefinitely. `default_scope` hides it from feeds, undo works forever. There's no UI today that surfaces "your soft-deleted decisions" — so they're effectively trash that the user can only get back to via the URL. Acceptable as an interim; the follow-up phase needs to address it.
- **Tombstone UX for orphan comments**: when B's comment's `commentable` returns a tombstoned note, controllers/views need to render `[deleted]` instead of crashing or returning 404. Tombstoned notes still have `deleted_at` set so the accessor masking returns `[deleted]` and `default_scope` hides them from listings — but `with_deleted` lookups will find the row. Verify that existing rendering paths for "view a note with comments" handle a deleted (with_deleted) parent gracefully.
- **Tombstones accumulate**: the row stays forever once tombstoned. For very high-volume tenants this is mostly empty rows, but they're not free. If table size becomes a problem later, a focused follow-up can decide which old tombstones are safe to drop (e.g. no remaining child comments or history events) and add a separate cleanup pass.
- **Attachment purging timing**: attachments preserved during grace period, purged at tombstone time. If a note has multi-GB attachments, the tombstone update gets slow. Acceptable for now — most notes have small attachments — but watch for it.

## Out of scope (deferred)

- Decision/Commitment hard-delete and tombstone semantics — needs design conversation about ownership-after-engagement, withdrawal, audit chain.
- Close-on-soft-delete for Decisions/Commitments — depends on the above design.
- Per-tenant grace period configuration.
- "Deleted on DATE" placeholder UI (Phase 4 transparency).
- Account closure flow (Phase 3).
- Audit chain tombstoning for Decisions (Phase 5).
