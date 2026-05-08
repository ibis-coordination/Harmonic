# Plan: Data Lifecycle Plan Docs

## Context
Creating two plan documents for data lifecycle management: a high-level roadmap and a detailed collective export/import plan.

## Deliverables

### File 1: `.claude/plans/data-lifecycle-management.md`
High-level roadmap: collective export/import, phased deletion, account closure, transparency, audit chain preservation.

### File 2: `.claude/plans/data-export.md`
Detailed collective export/import plan. Key design decisions:
- Collective-scoped (not user-scoped) — full collective portability for hosted → self-hosted migration
- Export + import built simultaneously, round-trip test validates both
- Users matched by email on import; unmatched become placeholder accounts
- Tenant-scoped DataExport/DataImport models
- 16 model types exported, all 43 collective-scoped tables accounted for
- Text link rewriting on import (truncated_ids, handles, hostnames change)
- Cross-collective representation session resources use DeletedRecordProxy
- Imported audit chains treated as pre-launch (audit_chain_hash set to nil)
- Heartbeats included; automation rules TBD
- Links regenerated from text, not imported directly
- Soft-deleted items lose backlinks (acceptable)
- Content reports excluded (moderation state)
