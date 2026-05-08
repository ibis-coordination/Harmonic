# Data Lifecycle Management

High-level roadmap for data portability, phased deletion, GDPR compliance, and user transparency.

## Context

Harmonic needs a unified data lifecycle for GDPR-like compliance and user trust. Users should be able to export their data, understand what "deleted" means, and have confidence that deletion is thorough. The existing `DataDeletionManager` is admin-only and console-only. `SoftDeletable` exists for content but has no grace period or hard-delete pipeline. There is no data export capability.

## Phase 1: Collective Data Export & Import (Portability)

*Detailed plan: [data-export.md](data-export.md)*

Export an entire collective as a ZIP of JSON files + attachments, designed for re-import into another Harmonic instance (e.g., hosted → self-hosted migration). Export is a collective-admin action; import is a tenant-admin action (creates a new collective, not self-service). Users are matched by email on import; unmatched users become placeholder accounts that can be claimed later.

Phase 1a: Collective export + import (built simultaneously, each validates the other)
Phase 1b: User-level personal data export (GDPR Article 20, separate scope)

## Phase 2: Phased Deletion

Extend `SoftDeletable` with a grace period before hard-delete:

1. **`hard_delete_after` column**: Set automatically in `soft_delete!` to `deleted_at + 30.days`. Configurable per-tenant.
2. **`HardDeleteExpiredRecordsJob < SystemJob`**: Runs daily. Finds records past grace period across all tenants. Calls `DataDeletionManager` for cascading associated data cleanup.
3. **Undo window**: `undo_delete!` clears `deleted_at` and `hard_delete_after` during grace period. Content is already scrubbed via `scrub_content!`, but `content_snapshot` preserves original text for admin recovery.
4. **Admin override**: Immediate hard-delete via existing `DataDeletionManager` console workflow.

Also fix the two known `DataDeletionManager` bugs:
- FK violation on events table during `delete_collective!` (missing `Event` in deletion list)
- Options with wrong `collective_id` during test setup

## Phase 3: Account Closure (GDPR Right to Erasure)

Implement the `force_delete: true` path in `DataDeletionManager#delete_user!`:

1. Require or trigger a data export before closure
2. Anonymize PII (already implemented: email, name, avatar)
3. Soft-delete all user-created content (enters 30-day pipeline from Phase 2)
4. Purge participation records (votes, decision participation, commitment participation)
5. Tombstone audit chain entries (see Phase 5)
6. Set `closed_at` on User record; block login

## Phase 4: User Transparency

Clear terminology across the app:

| State | Meaning | Reversible? | Data Visible? |
|-------|---------|-------------|---------------|
| **Archived** | Inactive membership/collective; data preserved | Yes | Yes, read-only |
| **Deleted** | Content removed; in 30-day grace period | Yes (content scrubbed) | No (hidden by default scope) |
| **Permanently deleted** | Hard-deleted after grace period | No | Gone |
| **Account closed** | User left; PII erased | No | Content enters deletion pipeline |

UI surfaces:
- Settings page: "Download my data" button, "Close my account" flow
- Deleted content: show "[This item was deleted on DATE]" placeholder
- Account closure: confirmation flow with password/2FA, offer export first

## Phase 5: Audit Chain Preservation

Decisions use a tamper-evident SHA-256 hash chain (`DecisionAuditEntry`). Hard-deleting entries or votes breaks chain integrity.

1. **Never hard-delete audit entries**: `DecisionAuditEntry` records are permanent.
2. **Tombstone votes on account closure**: Replace `actor_id` with nil, `actor_handle` with `[closed-account]`. Hash chain remains verifiable.
3. **Tombstone decisions on hard-delete**: Insert a final `decision_tombstoned` audit entry preserving the chain summary. Decision row replaced with a tombstone (id preserved, content nulled, `tombstoned_at` set).
4. **Verification continues to work**: `DecisionAuditVerifier` validates the hash chain of entries, not the decision content.

## Implementation Order

1. **Data Export** — this sprint (see detailed plan)
2. **DataDeletionManager bug fixes** — FK violation on events, options collective_id
3. **`hard_delete_after` + `HardDeleteExpiredRecordsJob`**
4. **Account closure flow** (UI + `force_delete: true`)
5. **Transparency UI** updates
6. **Audit chain tombstoning**
