# Export/Import — Deployment Readiness

Pre-deployment hardening and post-deployment follow-ups for the collective export/import feature ([data-export.md](data-export.md)). The core feature is implemented and tested; this document captures the gaps that surfaced during code review and end-to-end testing.

The ToS / privacy policy work is tracked separately and out of scope here.

## Pre-deployment work

### Feature flag gating export — DONE

`collective_export` feature flag (in `config/feature_flags.yml`) is off by default at the tenant level. Settings UI hides the button when off; the controller returns 404 when off. The flag will be turned on per-tenant only after the [ToS / privacy policy project](tos-and-privacy-policy.md) ships.

The import side (`/tenant-admin/imports`) is unaffected — it's already gated by tenant-admin auth and isn't covered by this flag. Imports are administratively useful (migrating into a fresh tenant) without raising the same disclosure concerns as export.

### Stuck-import sweeper job — DONE

`SweepStuckDataImportsJob < SystemJob`, scheduled hourly via sidekiq-cron, finds `DataImport` rows in `pending`/`validating`/`importing` whose `started_at` (or `created_at` for `pending`) is older than 1 hour and marks them `failed`. Modeled on `OrphanedTaskSweepJob`.

This is the safety net for the failure pattern that bit us on 2026-05-09: the rescue's `update!` itself failed with `InvalidForeignKey` (since fixed by switching to `update_columns`), but the structural pattern (worker dies → row stuck in non-terminal status → retry no-ops) remains a risk for any future bug of this shape.

### Notify collective members when an export happens — deferred to policy project

**Originally** flagged as a production blocker for transparency reasons. After deferring email export and adding the feature flag, this is no longer urgent:

- The export contains no information the admin doesn't already have access to (especially after the email-removal change). It's a re-packaging, not a new disclosure.
- The notification's framing depends on what the privacy policy commits to. Without that commitment, the wording is arbitrary.
- The feature flag prevents export from being used before the policy is in place.

**Decision:** defer to the [ToS / privacy policy project](tos-and-privacy-policy.md) as part of the broader question of "what acts do we commit to disclosing to members?" Re-evaluate the framing (transparency log entry vs. security alert), the trigger (creation, completion, download), and the channel (email, in-app, both) once the policy makes those choices explicit.

## High-priority follow-ups (should land within a sprint of deployment)

### Placeholder user claim flow

**Issue:** When data is imported to a target instance, placeholder accounts are created for source users. Those users have no idea the placeholder exists, can't log in, and have no way to exercise their rights (access, rectification, erasure) over data that pertains to them. This is the deepest agency gap in the current design.

**Fix:** When a user signs up (or signs in for the first time) on an instance that has unclaimed placeholders matching their handle/name, present a "Claim these accounts" flow. Verification by email + tenant admin approval. On claim, merge the placeholder's `id` into the real user's `id` (rewriting all FKs), or alternatively keep the placeholder and add an alias mapping. See "Identity merging" considerations.

**Acceptance:** a real user can claim their imported data and exercise standard account controls over it.

### Audit-chain attribution labels

**Issue:** Imported `DecisionAuditEntry` rows preserve `actor_handle` from the source. If `@alice` is a different person on the target instance, audit displays misattribute. The `metadata.imported = true` flag exists but isn't surfaced in the UI.

**Fix:** Audit-rendering UI checks `metadata["imported"]` and, when true, prepends/labels entries clearly: e.g. "imported from <source_instance> · @alice (source handle)". Apply this to both the HTML decision audit view and any markdown / API responses.

**Acceptance:** a target user reading an audit can immediately distinguish actions taken on this instance from imported entries; misattribution is impossible to miss.

### Failed-import file retention policy

**Issue:** Successful imports purge their uploaded ZIP on completion (we built this). Failed imports retain the ZIP indefinitely, accumulating storage cost. Multi-GB ZIPs from many failed attempts add up.

**Fix:** Add a daily sweeper (`PurgeStaleDataImportFilesJob`) that purges `data_import.file` for any DataImport whose `status` is `failed` and whose `updated_at` is older than 7 days. Don't destroy the row — keep the metadata (status, error_message) for forensics.

**Acceptance:** failed imports older than 7 days have no attached file; storage doesn't grow unboundedly.

### Orphaned ActiveStorage blob sweeper

**Issue:** On import failure mid-flight (after some attachments uploaded but before the transaction commits), `ActiveStorage::Blob` records exist with no parent `Attachment` (transaction rolled back). These blobs are never referenced, never cleaned up.

**Fix:** Add a daily sweeper that runs `ActiveStorage::Blob.unattached.where("created_at < ?", 1.day.ago).find_each(&:purge_later)`. The 1-day window avoids racing with in-flight uploads.

**Acceptance:** orphan blobs are purged within 24-48 hours of becoming orphaned.

### Trustee grant / representation session integrity

**Issue:** [collective_import_service.rb:600+](../../app/services/collective_import_service.rb#L600) imports `RepresentationSession` records but explicitly sets `trustee_grant_id: nil` ("cross-user, not collective-scoped"). The session record references a non-existent grant. UI / authorization code that loads the grant from the session sees nil and either crashes or treats the session as invalid.

**Fix:** Either (a) skip importing `RepresentationSession` entirely (acceptable — these are auth-time records that won't replay anyway), or (b) audit every code path that reads `RepresentationSession#trustee_grant` and confirm it tolerates nil. Recommend (a) for simplicity.

**Acceptance:** no NoExceptionFromNilGrant or similar errors in the imported collective; representation history either renders cleanly or doesn't render at all.

### Source URL alias mismatch

**Issue:** The text rewriter matches the exact `hostname + subdomain + collective_handle` from the manifest. If the source collective was reachable via an alias, custom domain, or non-canonical path, internal links remain pointing at the source instance after import. They'll either 404 or expose the source-instance to target-collective members.

**Fix:** Either (a) collect *all* known source URLs at export time and ship them in the manifest as `source_aliases: [...]`, then rewrite each, or (b) post-import, scan rewritten text for any remaining absolute URLs to non-target-instance hostnames and surface them in the import status as warnings the admin should review.

**Acceptance:** common alias mismatches are either auto-rewritten or flagged for review; no silent broken links.

## Medium-priority concerns

### Export snapshot consistency

**Issue:** Export iterates 16 model types under default `READ COMMITTED` isolation. Concurrent writes during export can produce inconsistent ZIPs (e.g., a vote whose `decision_participant_id` references a participant that wasn't captured because they were created during the gather).

**Fix:** Wrap the gather methods in `ActiveRecord::Base.transaction(isolation: :repeatable_read) do ... end` so the whole export sees a single snapshot.

**Acceptance:** an export taken during heavy concurrent activity passes its own re-import without `Unmapped ID` errors.

### Tenant collective-count quota check

**Issue:** Imports create new `Collective` records without checking whatever quota / billing limits `CollectivesController#create` enforces. A tenant can exceed plan limits via imports.

**Fix:** Before `import_collective` creates the new collective, run the same quota check. Reject the import (mark failed with a clear error) if it would push the tenant over limit.

### Search index reindex on Redis outage

**Issue:** `enqueue_search_reindex_for_imported_collective rescue nil` silently swallows failures. If Redis is down, imported content is invisible in search until the next reindex (next write). Users won't know.

**Fix:** Replace `rescue nil` with `rescue => e; Rails.logger.warn("..."); end` so the failure is at least logged. Optionally surface a "Search index pending" badge on the imported collective until a reindex completes.

### Attachments-without-blobs handling

**Issue:** `gather_attachments` writes metadata for every Attachment record, but only writes the binary if the blob is `attached?`. On import, an Attachment is created with byte_size and metadata but no file. UI may break trying to render.

**Fix:** Either (a) skip metadata-only attachments on export, or (b) ensure every render path tolerates `Attachment#file.attached? == false`. Audit `_pulse_attachments.html.erb` and similar.

### Tmpdir disk capacity

**Issue:** `Dir.mktmpdir` writes to the system `/tmp`. On a constrained container, large imports can exhaust the tmpfs allocation.

**Fix:** Configure the import tmpdir to a known-large persistent volume, or document the disk requirement and have ops size containers accordingly.

### CPU starvation on long imports

**Issue:** Decompression + text rewriting on a multi-GB import can saturate a worker for minutes. Other low-priority Sidekiq jobs queue behind it.

**Fix:** Run import jobs on a dedicated low-priority queue with its own (small) worker pool, isolating them from other work. Or, accept the trade-off and document expected behavior.

## Lower-priority / UX

### Status page auto-refresh

**Issue:** Status page never refreshes; admin sees a stale status until they reload.

**Fix:** Turbo Stream broadcast on status change, or simple meta-refresh / polling.

### Cancel a running import

**Issue:** Admin can't kill a running import. If they uploaded the wrong file, they must wait it out.

**Fix:** "Cancel" button that sets a `cancelled_at` flag on the DataImport; the import service checks the flag at each major step and aborts with rollback.

### Browser-driven e2e test

**Issue:** Relying on manual testing for the full UI flow.

**Fix:** Playwright spec covering: collective admin exports → email arrives → ZIP downloads → tenant admin imports → status reaches completed → admin can access imported collective.

### Reject exports/imports of private workspaces and chat collectives

**Issue:** `Collective#add_user!` raises if `private_workspace? && user != created_by`. So `ensure_importer_is_admin_member!` will fail when the imported collective is a private workspace where created_by is the source user (placeholder or matched). Chat collectives have a 2-member limit that import bypasses.

**Fix:** Reject at the export step: `create_export` returns an error if the collective is `private_workspace?` or `chat?`. Document why.

## Out of scope here

- ToS / privacy policy: tracked separately
- User-level personal data export (GDPR Art. 20 individual portability): in [data-lifecycle-management.md](data-lifecycle-management.md) as Phase 1b
- Cross-instance erasure propagation: technically intractable; addressed via documentation/customer-policy rather than code
