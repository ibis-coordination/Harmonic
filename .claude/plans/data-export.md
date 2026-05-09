# Collective Data Export & Import

## Context

Users of the Harmonic-hosted instance can export an entire collective's data and re-import it into a separate (e.g., self-hosted) instance. This is Phase 1a of the [data lifecycle management](data-lifecycle-management.md) roadmap.

## Current status

### Completed

- [x] Migrations: `data_exports`, `data_imports` tables
- [x] Models: `DataExport`, `DataImport` with ActiveStorage, status tracking, Sorbet RBIs
- [x] `CollectiveExportService`: 16 model types to ZIP of JSON + binary attachments, SHA-256 checksums
- [x] `CollectiveImportService`: full ID remapping, user matching/placeholders, iterative comment nesting (arbitrary depth), timestamp preservation
- [x] Text rewriting: internal links (full URLs, markdown paths), @ mentions, attachment UUIDs across all text fields (Note title/text, Decision question/description, Commitment title/description, Option title/description)
- [x] Side effect suppression: `Current.importing_data` flag in Tracked, Searchable, TracksUserItemStatus, InvalidatesSearchIndex, Linkable — thread-safe via `CurrentAttributes`
- [x] Vote trigger: `deadline < NOW()` → `deadline < NEW.updated_at` (allows historical vote import)
- [x] `deadline_event_fired_at` preserved on import (prevents duplicate deadline events)
- [x] Reminder notes: `reminder_scheduled_for` preserved, `reminder_notification_id` cleared
- [x] Background jobs: `CollectiveExportJob`, `CollectiveImportJob` (TenantScopedJob), `CleanupExpiredExportsJob` (SystemJob)
- [x] Controllers: `CollectiveDataTransfersController` (export, collective admin) and `TenantAdminController` (import, tenant admin) — scoped queries, RequiresReverification
- [x] Views: export list (collective), import list/upload/status (tenant admin)
- [x] Routes: exports under `/collectives/:handle/`; imports under `/tenant-admin/imports`
- [x] Rate limiting: Rack::Attack 3/hr per IP + app-level 1 concurrent per collective
- [x] `LinkParser` nil text fix (latent bug in existing code)
- [x] `imported_placeholder` user type added to User model
- [x] Search reindex enqueued as best-effort after import completes
- [x] Link records regenerated from rewritten text via `LinkParser` after import
- [x] Reverification: `data_transfer` scope on export controller; `admin` scope on tenant-admin import actions (inherited from `TenantAdminController`)
- [x] `SecurityAuditLog` entries for `data_export_created`, `data_export_downloaded`, `data_import_created`
- [x] Controller authorization tests: non-admin rejected, cross-collective rejected, cross-tenant rejected, reverification required
- [x] `DataExportMailer.export_ready` (HTML + text), delivered by `CollectiveExportJob` after successful export
- [x] `CleanupExpiredExportsJob` registered in sidekiq-cron (daily at 3 AM)
- [x] Settings page integration: "Export Data" link in collective settings; "Manage Imports" in tenant admin dashboard
- [x] Verified: import creates a new collective and never mutates the triggering collective's data
- [x] 77+ tests across services, jobs, controllers, mailers

### Not started

#### Security hardening

- [x] **Authorization audit**:
  - ActiveStorage URL TTL: `urls_expire_in = 1.hour` set globally; export download uses explicit `expires_in: 5.minutes` for defense in depth
  - Import file purged after successful import (was retained indefinitely)
  - Verified import never modifies the triggering collective's data — always creates a new collective
  - `error_message` stores raw `e.message` from service exceptions; admin-only visibility, accepted as low risk
- [ ] **Export encryption** (deferred — consider encrypting ZIP with key, adds complexity to import)

#### Operational

- [ ] **Status page auto-refresh**: Turbo Stream or polling for export/import progress
- [ ] **Manual browser testing**: End-to-end UI flow verification with Playwright MCP

#### Deferred features

- [ ] **Import wizard/guide**: Walk admins through options before executing import (see "Import access policy" below)
- [ ] **Placeholder user claiming**: Allow real users to claim imported placeholder accounts via email verification
- [ ] **Automation rules export/import**: Complex — references external webhooks, agents, trigger configs that may not exist in target
- [ ] **User-level personal data export** (Phase 1b): GDPR Article 20 — export a single user's data across tenants, separate from collective export
- [ ] **Full tenant export/import**: Export all collectives + tenant settings as a unit (see "Tenant export" below)

## Design details

### Export format

Single ZIP file. One JSON file per model type, plus `attachments/` directory for binary files.

```
harmonic-collective-export-YYYY-MM-DD-<export-id>/
  manifest.json           # format version, app version, checksums, source hostname/subdomain
  collective.json         # collective record + settings + created_by_id
  users.json              # all referenced users (email, name, handle, type)
  members.json            # memberships + roles + archived_at
  notes.json              # all subtypes: text, reminder, table, comment, statement
  decisions.json          # all subtypes: vote, lottery, executive
  options.json
  decision_participants.json
  votes.json
  decision_audit_entries.json
  commitments.json
  commitment_participants.json
  links.json              # exported for reference; regenerated on import
  note_history_events.json
  invites.json            # active only
  heartbeats.json
  representation_sessions.json
  representation_session_events.json
  attachments.json        # metadata
  attachments/            # binary files (<uuid>-<filename>)
```

### What's included (16 model types)

All 43 collective-scoped tables in the database are accounted for — 16 exported, rest explicitly excluded (Events, SearchIndex, UserItemStatus, ChatSessions, AutomationRules, ContentReports, etc.).

### User identity strategy

On import, users are matched by email. Matched → mapped to existing account. Unmatched → `imported_placeholder` account (display-only, no auth credentials).

### ID handling

Export preserves original UUIDs as `source_id` fields. Import generates new UUIDs, maintains in-memory `@id_map` (`source_id → new_id`) for FK remapping. `participant_uid` fields regenerated. `truncated_id` fields auto-generated from new UUIDs.

### Text rewriting

Post-import pass across all text fields:
- Internal links: truncated_ids, collective handles, hostnames, scope prefixes preserved
- @ mentions: source handle → target handle (single-pass regex, sorted longest-first)
- Attachment UUIDs in URL suffixes
- Link records regenerated via `LinkParser` directly (bypassing suppressed Linkable concern)

### Side effect suppression

`Current.importing_data` attribute (`ActiveSupport::CurrentAttributes`). Guards in 5 concerns return early when set. Thread-safe, auto-resets. Search reindex enqueued after flag cleared.

### Comment nesting

Iterative multi-pass: first pass imports non-comment/statement notes, second pass iterates comments layer by layer until all parents are resolved. Handles arbitrary depth and any JSON ordering.

### Audit chain handling

Entries preserved as historical records with `metadata.imported = true`. Decision `audit_chain_hash` cleared. New actions start fresh chains.

### Vote trigger

`deadline < NEW.updated_at` instead of `deadline < NOW()`. Import sets timestamps before save. Normal app behavior unchanged.

### Handle collisions

Import appends `-imported-N` suffix if collective handle already exists in target tenant.

### User identity & matching policy

**Privacy: emails are not exported.** A member's email is private within Harmonic — never displayed to other members, only known to the user themselves. Including emails in an export would let a collective admin extract member emails they were never authorized to see in-app, so `users.json` contains `source_id`, `name`, `handle`, `user_type` only.

**Matching strategy on import** (in priority order, per user):

1. **`use_placeholders` import option** → always create placeholder (sandbox/test scenario)
2. **UUID match** — `User.find_by(id: source_id)`. Succeeds for same-instance imports because the User table is shared across tenants. Likely the most common scenario.
3. **Handle→email map** — admin uploads a JSON map (`{"alice": "alice@example.com", ...}`) at import time. For cross-instance migrations where the importing admin already has the emails through some legitimate channel. Map is stored on the `DataImport` for audit.
4. **Fallback** — create placeholder with synthetic `@imported.invalid` email.

**Membership policy** (once a user is matched or created):

- Matched user is active in target tenant → active collective membership
- Matched user is archived in target tenant → archived collective membership (preserves data relationships without granting access)
- Matched user not in target tenant → added to tenant + collective
- New placeholder → added to tenant + collective with `imported_placeholder` user_type (display-only, no auth)

**Known limitations / deferred:**

- AI agents from the source aren't preserved as such — they import as `imported_placeholder` because the export doesn't capture their parent (`User#parent_id`) and AI agents require a parent. We'll address this when we build user merging.
- No post-import user merging UI yet. Placeholders sit until either a follow-up admin tool merges them, or a future "self-claim" flow lets real users adopt them via email confirmation.

### Tenant export (future)

Full tenant export would be a superset of collective export. Design considerations:

- **Scope**: All collectives (including main collective and private workspaces) + tenant settings + TenantUser records (handles, display names) + cross-collective data (TrusteeGrants, cross-collective RepresentationSessions)
- **Approach**: Export tenant config, then iterate all collectives using existing `CollectiveExportService`. Import: create tenant, then import each collective. Per-collective machinery already works.
- **Identity**: On a different instance, users would be created as new accounts. On the same instance (different subdomain), users matched by email.
- **Main collective**: Special handling — every tenant has one, auto-created with tenant. Import would need to use the target tenant's main collective rather than creating a new one.
- **Private workspaces**: Auto-created per user per tenant. Export for completeness, but could also be recreated on import since they're per-user.
- **Billing/Stripe**: Not exported — billing is instance-specific.

## Key files

| File | Purpose |
|------|---------|
| `app/services/collective_export_service.rb` | Export: gathers 16 model types, builds ZIP |
| `app/services/collective_import_service.rb` | Import: ID remapping, text rewriting, side effect suppression |
| `app/models/data_export.rb` | Export record with ActiveStorage |
| `app/models/data_import.rb` | Import record with ActiveStorage |
| `app/controllers/collective_data_transfers_controller.rb` | Export actions (collective admin, reverification scope `data_transfer`) |
| `app/controllers/tenant_admin_controller.rb` | Import actions (tenant admin, reverification scope `admin`) |
| `app/jobs/collective_export_job.rb` | Background export — sends `DataExportMailer.export_ready` after success |
| `app/jobs/collective_import_job.rb` | Background import |
| `app/jobs/cleanup_expired_exports_job.rb` | Purge expired exports (daily at 3 AM via sidekiq-cron) |
| `app/mailers/data_export_mailer.rb` | "Your export is ready" notification |
| `app/models/current.rb` | `importing_data` attribute |
| `app/models/concerns/tracked.rb` | Import guard |
| `app/models/concerns/searchable.rb` | Import guard |
| `app/models/concerns/tracks_user_item_status.rb` | Import guard |
| `app/models/concerns/invalidates_search_index.rb` | Import guard |
| `app/models/concerns/linkable.rb` | Import guard |
| `app/services/link_parser.rb` | Nil text fix |
| `db/migrate/20260508185124_update_vote_trigger_to_use_updated_at.rb` | Vote trigger change |
| `test/services/collective_export_service_test.rb` | 19 export tests |
| `test/services/collective_import_service_test.rb` | 56 import tests |
| `test/jobs/collective_export_job_test.rb` | 2 job tests |
