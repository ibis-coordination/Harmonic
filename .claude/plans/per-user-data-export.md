# Per-User Data Export

User-triggered export of the records a user owns within a collective. This is Phase 1b of the [data lifecycle management](data-lifecycle-management.md) roadmap — the user-side complement to the admin-side collective export (Phase 1a, shipped).

## Guiding principle

**Export scope = deletion scope.** What gets included in a user's export is exactly what would be deleted or scrubbed if the user closed their account. This gives the work a sharp boundary and a natural correctness check: if a record is in scope for deletion, it should also be in scope for export.

This principle also defers the harder ownership questions cleanly. A vote the user cast IS theirs (deleted on closure). The decision they voted on is NOT theirs (preserved on closure — belongs to whoever authored it).

## Scope (v1)

### Collective scope: main collective only

Each tenant has a `main_collective` ([tenant.rb](../../app/models/tenant.rb)). The main collective is the public-by-default sharing space where all members can read all content — making "you can export your own content from here" trivially safe (you're not exporting anything anyone else couldn't already read).

Per-user export from private collectives is deferred until the ownership policy for private-collective data is decided (see [data-lifecycle-management.md](data-lifecycle-management.md) Phase 1b note).

### No import

The export is a one-way archive. The user receives a ZIP they can keep as a record. We don't build the inverse "import my user data" pipeline because (a) the export is intentionally minimal — it doesn't carry the surrounding context needed to reconstruct decisions on a new instance, and (b) the use case isn't established yet.

## Export subject

The **subject** of a user's export is the parent user **plus all `User` rows where `parent_id = user.id`** (the user's AI agents). AI agent data is included in the parent user's export, not in a separate one.

This matches account closure: when a parent human user closes their account, the data attributed to their AI agents is also removed. Same scope → same export.

AI agents cannot trigger their own export — the settings-page UI is only shown for `user_type: "human"`. Collective identities (`user_type: "collective_identity"`) are out of scope for v1 entirely; they'll get their own plan when we get there.

In the filters below, "owned by user" means `created_by_id ∈ {user.id, *ai_agent_ids}` (or `actor_id`, `user_id`, etc., depending on the column). The export bundles all of this under the parent user's identity.

## In-scope records

Every record below is one that would be deleted, purged, or scrubbed on account closure. **Soft-deleted records are excluded** — once the user soft-deletes content, it's no longer "theirs" for export purposes (and we don't want exports to resurrect content the user intentionally hid).

### User-authored content (created_by ∈ subject)

- `Note` records where `created_by_id ∈ subject` (includes comments — they're Notes with `subtype: "comment"`)
- `Decision` records where `created_by_id ∈ subject`
- `Option` records where `created_by_id ∈ subject`
- `Commitment` records where `created_by_id ∈ subject`
- `Link` records where the user created the link
- ActiveStorage blobs attached to the above

### Participation records (records of the subject's actions)

- `Vote` rows by anyone in the subject — denormalized with `option_title` and `decision_question` snapshots (see below)
- `DecisionParticipant` rows where `user_id ∈ subject` — denormalized with `decision_question` snapshot
- `CommitmentParticipant` rows where `user_id ∈ subject` — denormalized with `commitment_title` snapshot
- `DecisionAuditEntry` rows where `actor_id ∈ subject` — included as **receipts of the subject's actions**, not as a verifiable chain (the surrounding entries belong to the collective). These already carry `option_title` and action-specific metadata snapshots natively.

### Account-level personal data

- `User` rows for the parent and every AI agent child (`parent_id = user.id`): email, name, avatar
- `TenantUser` row(s) for each subject user in this tenant: handle, display_name, per-tenant settings
- `OauthIdentity` / `OmniAuthIdentity` rows for the parent user (AI agents don't have these): provider linkages and timestamps (NOT the access/refresh tokens)
- `CollectiveMember` rows for each subject user in the main collective: roles, joined_at

### Cheap denormalization (snapshots, not records)

To keep the v1 archive minimally useful, a few labels are snapshotted onto participation records at export time. These are read-only strings, not the parent records:

- `Vote` rows include `option_title` and `decision_question` from the time of export
- `DecisionParticipant` rows include `decision_question`
- `CommitmentParticipant` rows include `commitment_title`

This is the minimum to make the archive legible. It does not extend to including full parent records, related options the user didn't act on, other participants' votes, etc. — those remain out of scope.

## Out-of-scope records (intentional exclusions)

### Content owned by others

- `Decision`, `Option`, `Commitment` rows where `created_by_id ∉ subject`, even when the user voted/participated. The user's action on the record is theirs (and included as a Vote / participation row with the denormalized label); the parent record is not.
- `Note` records authored by other users, even when they comment on the user's content.
- Other participants' votes on the user's decisions.

### Soft-deleted records

Anything with `deleted_at IS NOT NULL` is excluded. The user soft-deleted it intentionally; the export shouldn't resurface it. Account closure will eventually hard-delete these via the Phase 2 pipeline.

### Credentials and security artifacts

Credentials aren't "personal data" in the GDPR Article 20 sense — they're system artifacts that identify the user, not data about the user. Including them creates an unnecessary attack surface if the export is intercepted.

- `ApiToken` secrets (the existence of API tokens is shown on the settings page for revocation; secrets are never exported)
- TOTP shared secrets, OAuth access/refresh tokens, session tokens
- Password hashes (none — we don't have passwords)

### System-level audit data

- `SecurityAuditLog` entries — these are system-level audit records, not user data. They're operational state for the platform, not personal data the user provided.

### Other user types

- `collective_identity` users: deferred to a separate plan when collective-identity export is needed
- AI agents triggering their own export: not supported; their data is included in their parent human's export

### Contextual enrichment (deferred to future versions)

Beyond the cheap denormalization listed in the in-scope section, v1 does not include:

- Full parent records (the decision text and all its options, not just the one the user voted on)
- Other participants' actions on the user's content
- HTML explorer / human-readable rendering (like Twitter's archive viewer)

## Format

Same ZIP + JSON shape as the existing collective export ([CollectiveExportService](../../app/services/collective_export_service.rb)):

- `manifest.json` — metadata (export type = "per_user", user id, main collective id, timestamp, schema version)
- Per-record-type JSON files: `notes.json`, `decisions.json`, `options.json`, `commitments.json`, `votes.json`, `decision_participants.json`, `commitment_participants.json`, `decision_audit_entries.json`, `links.json`, `user.json`, `tenant_user.json`, `oauth_identities.json`, `collective_member.json`
- `attachments/` — binary blobs referenced by record IDs
- SHA-256 checksums in the manifest

Each JSON file contains an array of records with their database fields preserved. Foreign keys to records not in the export (e.g., a Vote's `decision_id`) remain as UUIDs — orphan FKs are accepted as a v1 constraint. The user can always look up the parent decision in the main collective UI while their account is active.

## Implementation approach

### Schema migration

Add `export_type` to `data_exports`:

```ruby
add_column :data_exports, :export_type, :string, null: false, default: "collective"
add_index  :data_exports, :export_type
```

`collective_id` remains required for both types (per-user exports always scope to the main collective). `user_id` already exists on `DataExport` (the triggering user); for `export_type = "user"` it's also the subject of the export.

Models add `enum` or constant for `export_type ∈ {"collective", "user"}` and scope queries accordingly.

### Service

New `UserDataExportService`, sibling of `CollectiveExportService`. Centralizes the per-record-type "ownership" predicates that resolve the subject set (parent user + AI agent children) and filter records accordingly. The same predicates will be reused by the Phase 3 deletion flow — the export/deletion symmetry is the principle's correctness check.

Shared infrastructure (manifest, ZIP, attachments, checksum, ActiveStorage upload) is not pre-abstracted — if duplication becomes concrete, factor it then.

### Job

New `UserDataExportJob` (mirrors `CollectiveExportJob`):

- `TenantScopedJob`
- On success: send `DataExportMailer.export_ready` — likely a new template tailored to user export (different copy than the collective version)
- File retention follows the same expiry as collective exports (cleaned up by `CleanupExpiredExportsJob`, which gets an `export_type`-agnostic sweep)

### Controller / surface

UI lives in user settings (account-level), not collective settings:

- Settings page: "Download my data" button (no collective selector in v1 — implicitly the main collective)
- Triggers export, shows status, sends email when ready
- Download link with same TTL as collective export (5 min)
- Rate-limited (per-user; reuse Rack::Attack pattern from collective export)
- Reverification required (same `data_transfer` scope used for collective export)
- Visible to `user_type: "human"` users only. Hidden for AI agents and collective identities.

### Authorization

- User can only export their own data — controller scopes by `current_user`
- The export subject includes the user's AI agent children automatically; no separate admin path for "export this user's data on their behalf"
- `SecurityAuditLog` entry: `user_data_export_created`, `user_data_export_downloaded`

## Resolved decisions

### Service organization

`UserDataExportService` is a sibling of `CollectiveExportService`. The two have different authorization models (admin-only vs. user-only), different filter logic (per-collective vs. per-user-across-AI-agents), and different denormalization rules, so a shared service with branching would be more confusing than two parallel services.

If concrete duplication emerges around manifest construction, ZIP assembly, or attachment collection, factor those into a shared parent class or module — but don't pre-emptively abstract. The two services should evolve independently until duplication is concrete and painful.

### Storage model

**Reuse the `DataExport` table** with a new `export_type` discriminator column.

Trade-offs we considered:

| | Reuse `DataExport` | New `UserDataExport` table |
|---|---|---|
| Schema clarity | Mixed: needs `export_type` discriminator; `collective_id` semantics differ per type | Clean: each table represents one concept |
| Code reuse | High: ActiveStorage attachment, status state machine, cleanup job, mailer all reusable directly | Low: each table needs its own job, mailer, cleanup, status handling |
| Migration cost | One column + backfill default | New table + migrations for jobs/policies |
| Authorization branching | Queries must filter by `export_type` | None |
| Adding a third export type later | Discriminator grows | Each new type = new table |

The deciding factor: the infrastructure around `DataExport` (status state machine, attachment handling, expiry, cleanup job, mailer scaffolding) is non-trivial and currently works. Duplicating it for a structurally similar use case is more cost than the discriminator's complexity. The `export_type` column is one source of branching; queries that scope by type are explicit, not surprising.

If we eventually add a third type (admin SAR exports, per-collective-per-user exports), revisit. Two types share cleanly; four would not.

### SecurityAuditLog entries

Excluded. These are system-level audit records, not user data. They live in the platform's operational state, not in the user's personal data.

### AI agent inclusion

A human user's export includes their AI agent children's data (notes, votes, audit entries actor=agent, etc.). The agents themselves cannot trigger an export. Account closure deletes the same set, so the export and deletion scopes stay aligned.

### Soft-deleted records

Excluded from the export. The user soft-deleted them intentionally; v1 doesn't re-surface them.

### Denormalization

Cheap label snapshots on participation/vote rows (`option_title`, `decision_question`, `commitment_title`) at export time. Not parent record copies, just enough to make the archive legible.

## Future versions (out of scope for v1)

- Per-user export from private collectives (waits on ownership policy)
- Contextual enrichment: denormalized option titles, decision questions, etc.
- HTML/Markdown rendering of the archive for human readability
- Re-importability into a different instance (would require resolving the orphan-FK problem)
- Export of data the user is mentioned in or that references them (out of Article 20's "data provided" scope but might be desirable for transparency)

## Relationship to other phases

- **Phase 1a (Collective Export)**: shipped. This work reuses its infrastructure.
- **Phase 3 (Account Closure)**: will use the same per-record ownership predicates this work centralizes. The "export = deletion scope" principle means both flows operate on the same record set.
- **Phase 4 (Transparency UI)**: the "Download my data" button is part of the settings-page UX that Phase 4 builds out more fully.

## Test plan

- Export contains every in-scope record type for a user with mixed authored / participated data
- Export excludes records authored by others, even when the user has touched them (commented, voted, participated)
- Soft-deleted records (deleted_at IS NOT NULL) are excluded
- AI agent children's data is included in the parent's export (notes, votes, audit entries with actor=agent)
- AI agents cannot trigger their own export (controller rejects)
- Collective identities cannot trigger an export (controller rejects)
- Denormalized labels (`option_title`, `decision_question`, `commitment_title`) appear on participation/vote rows
- Credentials (API token secrets, TOTP, OAuth tokens) are never present in any JSON file
- `SecurityAuditLog` entries are never present in the export
- Empty export (user with no activity) produces a valid ZIP with empty arrays
- Per-tenant scope: user with data in two tenants gets two separate exports when triggered from each
- Authorization: non-owner cannot trigger another user's export
- Rate limiting fires
- Reverification required
- File expiry honors the configured TTL
- `export_type` discriminator: collective-export queries don't accidentally surface user exports and vice versa
