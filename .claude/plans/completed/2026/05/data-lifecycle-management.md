# Data Lifecycle Management

High-level roadmap for data portability, phased deletion, GDPR compliance, and user transparency.

## Context

Harmonic needs a unified data lifecycle for GDPR-like compliance and user trust. Users should be able to export their data, understand what "deleted" means, and have confidence that deletion is thorough. The existing `DataDeletionManager` is admin-only and console-only. `SoftDeletable` exists for content but has no grace period or hard-delete pipeline. There is no data export capability.

## Phase 1: Data Export & Import (Portability)

### Phase 1a: Collective export + import — **shipped**

*Detailed plan: [completed/2026/05/data-export.md](completed/2026/05/data-export.md)*

Export an entire collective as a ZIP of JSON files + attachments, designed for re-import into another Harmonic instance (e.g., hosted → self-hosted migration). Export is a collective-admin action; import is a tenant-admin action (creates a new collective, not self-service). Users are matched by UUID on import; unmatched users become placeholder accounts.

### Phase 1b: Per-user data export — **planned**

*Detailed plan: [per-user-data-export.md](per-user-data-export.md)*

User-triggered export of records the user owns within a collective (GDPR Article 20 portability). Scope mirrors account-closure deletion scope — only records that would be deleted/scrubbed on closure are in the export. Main collective only initially; private-collective export deferred until ownership policy is resolved. One-way archive (no import).

## Phase 2: Phased Deletion — **shipped (Notes only); Decisions/Commitments deferred**

*Detailed plan: [phased-deletion.md](phased-deletion.md)*

`SoftDeletable` extended with a 30-day grace period and accessor-masking defense-in-depth. `soft_delete!` is metadata-only — content is preserved at rest, hidden by `default_scope`, and masked to `[deleted]` via overridden readers (with `raw_*` escape hatches for audit/undo paths). `undo_delete!` clears the timestamps and restores accessors.

**Notes** opt into `participates_in_hard_delete`. Once `hard_delete_after` passes, `HardDeleteExpiredRecordsJob` (daily) calls `DataDeletionManager.system_tombstone_note!` which always tombstones: nulls `title`/`text`/`table_data`, purges attachments, destroys Link records, sets `tombstoned_at`. The row stays in the DB so external references (other-user comments, NoteHistoryEvents) keep resolving. Full row destruction remains available via the console admin `delete_note!` method.

**Decisions** and **Commitments** still soft-delete (hidden, content masked, undo reversible) but never auto-finalize. Their deletion semantics — ownership-after-engagement, audit-chain preservation, withdrawal vs. delete — are deferred to a follow-up phase.

Bug fixes shipped alongside:
- `Event` cleanup added to `delete_collective!` cascade (FK violation fix)
- `CollectiveIdMatchesParent` concern enforces `collective_id` consistency on `Option`, `Vote`, `DecisionParticipant`, `CommitmentParticipant`, `DecisionAuditEntry`

Defense-in-depth guard added to `ReminderDeliveryJob` to skip delivery if the linked note has been soft-deleted (in case a partial `cancel!` left an orphan notification).

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

1. ✅ **Data Export** — shipped (Phase 1a + 1b)
2. ✅ **Phase 2 Notes pipeline** — shipped (grace period, accessor masking, tombstone job, bug fixes)
3. **Decision/Commitment deletion semantics** — design follow-up (ownership-after-engagement, withdrawal vs. delete, audit-chain preservation)
4. **Account closure flow** (UI + `force_delete: true`)
5. **Transparency UI** updates
6. **Audit chain tombstoning**
