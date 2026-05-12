# Phase 2: Phased Deletion

Add a 30-day grace period between user-initiated soft-delete and permanent hard-delete. Fix two pre-existing bugs in `DataDeletionManager` that the hard-delete pipeline will rely on.

## Context

Today's `SoftDeletable#soft_delete!` is misleadingly named: it sets `deleted_at` **and immediately scrubs content** (writes `[deleted]` over titles/text via `scrub_content!`). There is no grace period, no undo, and no hard-delete pipeline. A "30-day undo" on top of the current scheme would be hollow because the content is gone the moment soft-delete runs.

`DataDeletionManager` has two known bugs (currently captured as `skip`'d tests in `test/services/data_deletion_manager_test.rb`):
- `delete_collective!` doesn't include `Event` in its deletion list → FK violation on `events.collective_id`.
- `delete_collective!` has no validation that all child records were deleted, so a partial deletion (e.g. options that landed in the wrong collective during a buggy code path) leaves orphans that trip later FK violations.

Phase 2 builds the grace-period machinery on top of `SoftDeletable` and fixes both bugs so the daily hard-delete job can safely delegate to `DataDeletionManager`.

## Resolved decisions

- **Grace-period content semantics**: `soft_delete!` becomes purely metadata — sets `deleted_at` and `hard_delete_after`, removes from search index, unpins. **No DB content scrubbing.** Content is preserved at rest during the grace period, so undo is just clearing timestamps. The DB row is destroyed entirely by `HardDeleteExpiredRecordsJob` at expiry.
- **Defense-in-depth via accessor masking**: Override the content attribute readers on each soft-deletable model so that when `deleted?` is true they return `[deleted]` (or `nil` for `table_data`), even though the DB still has the real values. This preserves the current behavior of "soft-deleted content reads as `[deleted]` everywhere" without actually destroying the content — so existing tests that assert `[deleted]` keep passing, and any code path that bypasses `default_scope` (e.g. `with_deleted`) still can't accidentally render real content. Provide `raw_*` escape hatches (`raw_title`, `raw_text`, `raw_question`, `raw_description`, `raw_table_data`) for the few legitimate readers: `content_snapshot`, admin recovery, and undo verification.
- **Daily job ↔ DataDeletionManager**: Add new system-job entry points on `DataDeletionManager` (e.g. `system_delete_note!`, `system_delete_decision!`, `system_delete_commitment!`) that skip the user+token guard but require an explicit `from_system_job: true` kwarg. Existing `delete_*!` methods stay unchanged for the console workflow.
- **Bug fixes**: Land in the same PR as Phase 2 work, as separate prerequisite commits before the grace-period machinery.

## Scope

Three models include `SoftDeletable` today: `Note`, `Decision`, `Commitment`. Phase 2 applies to all three uniformly.

## Implementation plan

### Commit 1 — Bug fix: add Event to `delete_collective!` cascade

- `Event` has `belongs_to :tenant, :collective` and `has_many :notifications, :webhook_deliveries, dependent: :destroy`.
- Add `Event` to the model list in `delete_collective!`. Use `.destroy_all` (not `.delete_all`) so the `dependent: :destroy` cascades fire for notifications and webhook_deliveries. Order: before `Decision`/`Note`/`Commitment` (since events reference those as polymorphic subjects — though that FK is not DB-enforced, ordering still keeps the cleanup sane).
- Un-skip `test "BUG: delete_collective! fails when collective has events"` and rewrite it as a real test that creates an Event, calls `delete_collective!`, and asserts no FK violation.

### Commit 2 — Bug fix: validate all child records cleared in `delete_collective!`

- After the deletion loop, query each model class to confirm zero rows remain with `collective_id: collective.id`. If any class has leftovers, raise with a clear message (the transaction will roll back).
- This converts silent partial-deletion bugs into loud failures and gives the hard-delete job a safety net.
- Un-skip the second BUG test and rewrite it as a real test that exercises the validation path.

### Commit 3 — Migration: add `hard_delete_after` to soft-deletable tables

- `add_column :notes, :hard_delete_after, :datetime` (indexed). Same for `decisions`, `commitments`.
- No default; populated by `soft_delete!`. Existing soft-deleted rows are out of scope (none in production yet for this codebase, or any that exist are old enough to skip the grace period — confirm with a console check before deploying).

### Commit 4 — Rework `SoftDeletable#soft_delete!` semantics + accessor masking

- Remove the `scrub_content!` call from `soft_delete!`. Delete the `scrub_content!` method from each model — accessor masking replaces it.
- Remove `attachments.destroy_all` from `soft_delete!`. Attachments are preserved during grace period and purged by the hard-delete job.
- Keep search index removal and unpin (these are visibility concerns, correct on soft-delete).
- `soft_delete!` now sets `deleted_at`, `deleted_by_id`, and `hard_delete_after = deleted_at + grace_period`.
- Grace period: constant `SoftDeletable::DEFAULT_GRACE_PERIOD = 30.days` for now. Per-tenant override deferred to a follow-up.
- Add `undo_delete!(by:)` that clears `deleted_at`, `deleted_by_id`, `hard_delete_after`. Re-adds to search index. Raises if `hard_delete_after` has passed (defensive — the row should already be gone by then; if the job is behind, undo should still refuse rather than resurrect something past its window).
- **Accessor masking** on each soft-deletable model. Pattern (illustrative, per-model):

  ```ruby
  # Note
  alias_method :raw_title, :title
  alias_method :raw_text, :text
  alias_method :raw_table_data, :table_data

  def title;      deleted? ? "[deleted]" : raw_title; end
  def text;       deleted? ? "[deleted]" : raw_text;  end
  def table_data; deleted? ? nil         : raw_table_data; end
  ```

  Fields to mask per model:
  - `Note`: `title`, `text`, `table_data` (→ nil)
  - `Decision`: `question`, `description`
  - `Commitment`: `title`, `description`
- `content_snapshot` switches to reading `raw_*` so it captures real content even when called on a deleted record. Callers (`api_helper.rb` snapshot capture for abuse reports / admin-deletion audit logs) become safer — order-of-operations no longer matters.
- Write-path is untouched: setters still write to the real columns. Tests that assert `[deleted]` after `soft_delete!` keep passing because they read through the masked accessor.

### Commit 5 — System-job entry points on `DataDeletionManager`

- Add `DataDeletionManager.system_delete_note!(note:)`, `system_delete_decision!(decision:)`, `system_delete_commitment!(commitment:)` as class methods (no actor required).
- Internally these call the same cascade logic as the existing `delete_*!` methods but skip the user/token guard. Refactor the cascade bodies into private class methods shared between the instance and class entry points.
- Guard: each system entry checks it's running inside a `SystemJob` (by checking a thread-local set by `SystemJob#before_perform`, or by accepting an explicit `from_system_job: true` kwarg). Simpler: just require explicit `from_system_job: true` — no thread-local needed.

### Commit 6 — `HardDeleteExpiredRecordsJob`

- `class HardDeleteExpiredRecordsJob < SystemJob`.
- Daily schedule (sidekiq-cron config).
- Across all tenants, finds `Note`, `Decision`, `Commitment` with `hard_delete_after < Time.current` (use `with_deleted` since `default_scope` hides them; need `unscoped_for_system_job` semantics).
- For each, calls the appropriate `DataDeletionManager.system_delete_*!` and logs the result. Wrap each in its own transaction so one failing record doesn't block the rest.
- Counts and reports per-tenant totals to the existing `SecurityAuditLog` or `Rails.logger` (sketch — confirm during impl).

### Commit 7 — Tests

- `test/models/concerns/soft_deletable_test.rb`: new test class. Cases:
  - `soft_delete!` sets `deleted_at` + `hard_delete_after`
  - `soft_delete!` does NOT scrub the DB (raw columns retain real values)
  - Accessors return `[deleted]` after soft-delete; `raw_*` returns the original content
  - `soft_delete!` removes from search index
  - `undo_delete!` clears all three timestamps and restores search index
  - After `undo_delete!`, accessors return real content again
  - `undo_delete!` raises if `hard_delete_after` has passed
  - `content_snapshot` returns real content even when called after soft_delete (via `raw_*`)
- `test/jobs/hard_delete_expired_records_job_test.rb`: new test class. Cases:
  - Hard-deletes records past `hard_delete_after`, leaves fresh ones alone
  - Crosses tenants safely
  - One failing record doesn't block siblings
  - Cascades correctly (links, votes, audit entries, etc. — the existing DDM tests already cover this; spot-check end-to-end)
- Existing model tests asserting `[deleted]` text after `soft_delete!` should continue to pass without modification — the accessor masking preserves that contract.

### Commit 8 — Plan doc cleanup

- Update `data-lifecycle-management.md` to mark Phase 2 status.
- Move this plan to `completed/2026/05/phased-deletion.md` at PR-merge time.

## Risks / things to watch

- **Edit-form footgun (accessor masking)**: if an admin view loads a soft-deleted record (via `with_deleted`) and renders an editable form, the form field will pre-fill with `[deleted]` and a save would write `[deleted]` to the real column. Mitigation: any admin view that uses `with_deleted` MUST render read-only or explicitly use `raw_*` for form prefill. Add a comment in the concern and a brief note in `docs/ARCHITECTURE.md` if applicable.
- **Other masking bypass paths**: `read_attribute(:title)`, `record[:title]`, `record.attributes`, raw SQL, and JSON serialization that goes through `attributes_for_database` would return real values. We rely on `default_scope` keeping deleted rows out of normal queries. Document this explicitly so future developers know the masking is "render-layer defense", not absolute.
- **Search index after undo**: undo needs to re-add the record. Confirm `SearchIndexer` exposes an `add`/`upsert` method symmetric to `delete`.
- **Attachments during grace period**: blob storage costs persist for 30 days post-delete. Acceptable for now; revisit if it becomes a real cost.
- **Existing soft-deleted rows in production**: their DB content is already scrubbed to `[deleted]` and they have no `hard_delete_after`. Backfill option: set `hard_delete_after = deleted_at + 30.days` for existing rows. They'll be hard-deleted immediately by the first job run, which is correct. Confirm count before deploying.
- **`Event` cascade order**: Events have polymorphic `subject_type/id` that's not DB-enforced, but deleting Events first is the safe order. Double-check that Notifications/WebhookDeliveries' `dependent: :destroy` is preserved when using `.destroy_all` instead of `.delete_all`.

## Out of scope (deferred to later phases)

- Per-tenant grace period configuration (Phase 4 transparency UI).
- "Deleted on DATE" placeholder UI (Phase 4).
- Account closure flow (Phase 3).
- Audit chain tombstoning for Decisions (Phase 5) — but the hard-delete job will need to be aware of it once Phase 5 lands.
- Restoring purged attachments — once hard-deleted, attachments are gone. No restore path.
