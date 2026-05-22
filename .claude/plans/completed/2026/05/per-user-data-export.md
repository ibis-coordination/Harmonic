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

### User-authored content

- `Note` records where `created_by_id ∈ subject` (includes comments — they're Notes with `subtype: "comment"`)
- `Decision` records where `created_by_id ∈ subject`
- `Option` records whose `decision_participant.user_id ∈ subject` (Option has no `created_by_id` — authorship flows through the participant)
- `Commitment` records where `created_by_id ∈ subject`
- `Link` records where either endpoint (Note / Decision / Commitment) is owned by the subject (Link has no `created_by_id`; the relationship vanishes on account closure when the linked content is deleted)
- `Attachment` records where `created_by_id ∈ subject`, with binary file content under `attachments/`

### Participation records (records of the subject's actions)

Actions the subject took on records they don't necessarily own — parallel to votes, all carry the subject's `user_id` (or `actor_id`):

- `Vote` rows by anyone in the subject (joins via `DecisionParticipant`) — denormalized with `option_title` and `decision_question` snapshots
- `DecisionParticipant` rows where `user_id ∈ subject` — denormalized with `decision_question` snapshot
- `CommitmentParticipant` rows where `user_id ∈ subject` — denormalized with `commitment_title` snapshot
- `NoteHistoryEvent` rows where `user_id ∈ subject` — read confirmations, reminder acknowledgments, and edits the subject performed on any note. Denormalized with `note_title` snapshot.
- `DecisionAuditEntry` rows where `actor_id ∈ subject` — **receipts of the subject's actions** (not a verifiable chain). Carry `option_title` and action-specific metadata natively; further denormalized with `decision_question` and `decision_truncated_id` for receipt-URL reconstruction.
- `Invite` rows where `created_by_id ∈ subject` — invites the subject sent. Received invites (`invited_user_id = subject`) are excluded.
- `TrusteeGrant` rows where the subject is either party (`granting_user_id ∈ subject` OR `trustee_user_id ∈ subject`). Both directions vanish on either user's closure. Tenant-scoped (no collective_id).
- `RepresentationSession` rows where `representative_user_id ∈ subject` AND `collective_id IS NULL` — user-to-user sessions (via a `TrusteeGrant`). The main collective has no representatives, so collective-rep sessions (which have `collective_id` set) are out of scope.
- `RepresentationSessionEvent` rows linked to the user-to-user sessions above — per-action detail of what the subject did while representing.

### Account-level personal data

- `User` rows for the parent and every AI agent child (`parent_id = user.id`): email, name, avatar, user_type, agent_configuration
- `TenantUser` row(s) for each subject user in this tenant: handle, display_name, per-tenant settings
- `OauthIdentity` rows for the parent user (AI agents don't have these): provider linkages and timestamps (auth_data is NEVER exported — see exclusions)
- `OmniAuthIdentity` rows for the parent user: email, name, otp_enabled (credentials NEVER exported — see exclusions)
- `CollectiveMember` rows for each subject user in the main collective: roles, settings, joined_at

### Cheap denormalization (snapshots, not records)

To keep the v1 archive legible, a few labels are snapshotted onto participation/action records at export time. These are read-only strings, not the parent records:

| Record | Snapshot fields |
|---|---|
| `Vote` | `option_title`, `decision_question` |
| `DecisionParticipant` | `decision_question` |
| `CommitmentParticipant` | `commitment_title` |
| `NoteHistoryEvent` | `note_title` |
| `DecisionAuditEntry` | `decision_question`, `decision_truncated_id` (for receipt URL reconstruction) |

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

**Recursive nested structure.** The top level is the human user's export. Inside, an `ai_agents/` directory contains one subdirectory per AI agent child, each of which is a fully self-contained export with the same file layout and its own `manifest.json`. An agent's directory is tarball-able and would be a valid standalone export on its own.

```
harmonic-user-export-<date>-<id>/
├── manifest.json            # describes THIS view (the parent)
├── users.json               # just the parent user
├── tenant_users.json
├── collective_members.json
├── oauth_identities.json
├── omni_auth_identities.json
├── notes.json
├── decisions.json
├── options.json
├── commitments.json
├── votes.json
├── decision_participants.json
├── commitment_participants.json
├── decision_audit_entries.json
├── note_history_events.json
├── invites.json
├── trustee_grants.json
├── representation_sessions.json
├── representation_session_events.json
├── links.json
├── attachments.json
├── attachments/             # binary blobs referenced by attachments.json
└── ai_agents/
    └── <agent_handle>/      # mirror of the layout above, scoped to this agent
        ├── manifest.json
        ├── users.json       # just the agent
        ├── ...
        └── attachments/
```

Each view's `manifest.json` declares its own subject (`user_id`, `user_type`, `source_parent_id`, `collective_id`), record counts, and SHA-256 checksums of the files in that view. Manifests don't cross-reference other views — each is self-contained.

### Cross-subject records appear in both views

Records that span two subjects (e.g., a TrusteeGrant where the agent is granting_user and the parent is trustee_user; or a Link with one endpoint on the parent's content and the other on the agent's) appear in **both** the parent's and the agent's directories. Each view stays consistent from its user's perspective. This is intentional duplication — not redundancy in a relational sense, because each view is "what this user did / was party to."

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

## Known acceptable consequences

### Pre-scrub exports persist past account closure

The export includes `actor_token` and `actor_token_salt` on each audit-chain receipt where the subject was the actor. Post-account-closure, the live DB scrubs both `actor_id` and `actor_token_salt` on those entries, but a previously-issued export still contains them. This is **intentional**: it lets the user prove their own past actions even after closing their account.

Implication: an attacker who later obtains a user's pre-closure export ZIP could re-link the user's identity to entries that are now scrubbed in the live chain. This is an acceptable trade-off because the user explicitly requested the export, knows what's in it, and can manage their own copy. Future maintainers should NOT try to "fix" this by stripping the salt — the user attesting to their own scrubbed entries is a feature, not a bug.

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

### Service-level (pinned)

- Each in-scope record type includes only the subject's rows, excludes others'
- Cross-collective leak protection: participations in non-main collectives are excluded; explicit `collective_id` filters as defense-in-depth
- AI agent children's data appears in parent's export (notes, votes, audit entries with actor=agent, trustee grants)
- Soft-deleted notes are excluded (relies on Note default scope)
- RepresentationSessions: user-to-user (collective_id IS NULL) included; collective-rep sessions in other collectives excluded
- TrusteeGrants: both grantor-side and trustee-side rows included; third-party grants excluded
- NoteHistoryEvent: subject's read confirmations on others' notes ARE included (parallel to votes)
- Invites sent by subject included; received invites excluded
- Cheap denormalization fields are populated on the documented record types
- Attachment binary content is in the ZIP for subject's blobs only
- Credentials (password_digest, otp_secret, OAuth tokens, auth_data) are never present in any JSON file — pinned per-record
- `SecurityAuditLog` entries are never present
- Empty export (user with no activity) produces a valid ZIP with empty arrays
- Service guards: refuses if export_type != "user"; refuses if subject user_type != "human"; refuses if collective != tenant's main_collective

### Job- and controller-level (pending)

- Per-tenant scope: user with data in two tenants gets two separate exports when triggered from each
- Authorization: non-owner cannot trigger another user's export
- Rate limiting fires
- Reverification required
- File expiry honors the configured TTL
- `export_type` discriminator: collective-export queries don't accidentally surface user exports and vice versa
