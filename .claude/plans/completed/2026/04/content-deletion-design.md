# Plan: Content Deletion (Soft Delete) — Design & Implementation

## Context

Users currently have no way to delete content they've created. This plan adds **soft deletion** for notes, decisions, and commitments. Soft-deleted content has its text scrubbed but the record is preserved, so all dependent data (comments, votes, participants, links, read confirmations) remains intact.

This is a prerequisite for content reporting — admins need a way to remove specific content when acting on reports.

**Scope:** Notes, decisions, and commitments only. Decision option deletion is deferred to a separate plan.

## Design Decisions

### 1. Soft delete only

Every deletion is a soft delete. The record stays in the database with:
- `deleted_at` timestamp set
- `deleted_by_id` set to the user who performed the deletion
- Text content scrubbed (replaced with `"[deleted]"`)

All dependent records (comments by other users, votes, participants, links, read confirmations, attachments) are preserved. The creator's text is gone but the collective's contributions remain.

### 2. What gets scrubbed

| Model | Fields scrubbed (set to `"[deleted]"`) |
|-------|---------------------------------------|
| Note | `text`, `title` |
| Decision | `question`, `description` |
| Commitment | `title`, `description` |

`"[deleted]"` is used instead of `nil` because `Decision` validates `question` presence and `Commitment` validates `title` presence. Using a consistent sentinel value across all fields avoids validation issues and makes the pattern clear.

Attachments are also purged during soft delete — if the text is scrubbed for safety, attached files should go too. Attachments are the creator's own uploads.

### 3. How deleted content displays

**On its own page** (e.g., `/n/abc123`):
- "[This note has been deleted]" (or decision/commitment equivalent)
- Author and date still shown
- Comments section still visible below
- No edit/settings/pin actions available

**In feeds and lists** (pulse, search results):
- Excluded. Soft-deleted content does not appear in feeds or search.
- Achieved via default scope: `where(deleted_at: nil)` added to Note, Decision, Commitment.

**As a link target** (backlinks from other content):
- Shows "[deleted]" — consistent with existing `DeletedRecordProxy` pattern.

**As a comment parent** (note is a comment on deleted content):
- Comment remains visible. Parent shows "[deleted]" with author attribution.

**In search index:**
- Removed from search index on soft delete (explicit `SearchIndexer.delete` call, since the Searchable concern's auto-delete only fires on `destroy`).

### 4. Audit trail — evidence capture at deletion time

Once text is scrubbed, the evidence of what was deleted is gone. For accountability and dispute resolution, `soft_delete!` captures the original content **before** scrubbing and logs it to the security audit log.

**When a user deletes their own content:** No audit logging. This is routine — it's their content.

**When an admin deletes someone else's content:** `soft_delete!` captures the original text before scrubbing and the caller (ApiHelper) logs it to the security audit. This is not inside `soft_delete!` itself — the model doesn't know whether the caller is the author or an admin. The controller/service layer makes that distinction.

```ruby
# In ApiHelper:
def delete_note(note)
  authorize_delete!(note)
  admin_deleting = (note.created_by_id != current_user.id)
  snapshot = note.content_snapshot if admin_deleting
  note.soft_delete!(by: current_user)
  if admin_deleting
    SecurityAuditLog.log_content_deleted(
      content: note,
      deleted_by: current_user,
      ip: request_ip,
      snapshot: snapshot,
    )
  end
end
```

Each model implements `content_snapshot` returning a hash of the text fields:
- Note: `{ title: title, text: text }`
- Decision: `{ question: question, description: description }`
- Commitment: `{ title: title, description: description }`

The snapshot is stored in the security audit log JSON (append-only, not user-visible). Fields are truncated to a reasonable limit (e.g., 2000 chars) to avoid bloating the log.

The content reporting plan also captures a snapshot at report time (on the ContentReport record), so for reported-then-deleted content there are two evidence points: what the reporter saw when they reported it, and what the admin saw when they deleted it.

### 5. Who can delete

- **Content creator** — can delete their own notes, decisions, and commitments
- **Collective admin** — can delete any content in their collective (moderation)
- **App admin** — can delete any content across tenants (via admin tools, later via report review)

### 5. Where the delete action lives

**On content settings pages** (`/n/:id/settings`, `/d/:id/settings`, `/c/:id/settings`):
- "Delete" section at the bottom, danger-styled, behind a `<details>` disclosure
- Confirmation: "This will permanently remove the content of this [note/decision/commitment]. Comments and other contributions from other users will be preserved. This cannot be undone."
- Only shown to users with delete permission (creator or collective admin)

**On comments** (notes that are comments):
- Small "Delete" link on each comment authored by current user
- `data-turbo-confirm` for lightweight confirmation
- Same soft-delete behavior: text scrubbed, record preserved, child replies remain

**Not in the main content action bar.** Delete is destructive and rare; settings is the right place.

### 6. Redirect after deletion

- Deleting from settings page → redirect to collective pulse
- Deleting a comment → stay on parent content page (comment shows as "[deleted]")

## Implementation

### Phase 1: Migration

```ruby
class AddSoftDeleteToContent < ActiveRecord::Migration[7.2]
  def change
    add_column :notes, :deleted_at, :datetime
    add_column :notes, :deleted_by_id, :uuid
    add_column :decisions, :deleted_at, :datetime
    add_column :decisions, :deleted_by_id, :uuid
    add_column :commitments, :deleted_at, :datetime
    add_column :commitments, :deleted_by_id, :uuid

    add_index :notes, :deleted_at
    add_index :decisions, :deleted_at
    add_index :commitments, :deleted_at
  end
end
```

### Phase 2: SoftDeletable concern

New concern `app/models/concerns/soft_deletable.rb`:
- `soft_delete!(by:)` — in a transaction: scrubs content, purges attachments, sets deleted_at/deleted_by_id, removes from search index
- `deleted?` — checks deleted_at presence
- `content_snapshot` — abstract, each model overrides to return a hash of text fields (for audit logging by the caller)
- `scrub_content!` — abstract, each model overrides to set text fields to `"[deleted]"`
- Scope: `not_deleted` → `where(deleted_at: nil)`

Include in Note, Decision, Commitment.

Note: `soft_delete!` does not log to SecurityAuditLog. The caller (ApiHelper) decides whether to log based on whether the deletion is by the author or by an admin.

### Phase 2b: SecurityAuditLog.log_content_deleted

New method on `SecurityAuditLog` (only called for admin deletions):
```ruby
def self.log_content_deleted(content:, deleted_by:, ip:, snapshot:)
  log_event(
    event: "content_deleted",
    severity: :warn,
    content_type: content.class.name,
    content_id: content.id,
    content_truncated_id: content.truncated_id,
    deleted_by_id: deleted_by.id,
    deleted_by_email: deleted_by.email,
    ip: ip,
    snapshot: snapshot.transform_values { |v| v&.truncate(2000) },
  )
end
```

### Phase 3: Default scope

Add `not_deleted` filtering to each model's default scope. This automatically excludes deleted content from all feed queries (Cycle#notes, Cycle#decisions, etc.), search results, and listings.

For show pages that need to render deleted content, use `unscope(where: :deleted_at)` or access via `find` (which may need adjustment depending on how the controller loads the record).

### Phase 4: ApiHelper delete methods

Add to `app/services/api_helper.rb`:
- `delete_note(note)` — check authorization, call `note.soft_delete!(by: current_user)`
- `delete_decision(decision)` — same
- `delete_commitment(commitment)` — same

Authorization check: `content.created_by == current_user` OR user is collective admin.

### Phase 5: Routes and controller actions

```ruby
# Notes
post 'n/:id/actions/delete' => 'notes#execute_delete'
# Decisions
post 'd/:id/actions/delete' => 'decisions#execute_delete'
# Commitments
post 'c/:id/actions/delete' => 'commitments#execute_delete'
```

Each controller action:
1. Find the content (must bypass `deleted_at` scope for idempotency)
2. Call ApiHelper delete method
3. Flash success
4. Redirect (pulse for top-level content, parent for comments)

### Phase 6: Views

**Settings pages** — add delete section at bottom:
- `<details>` disclosure with danger styling (same pattern as suspend in admin)
- Confirmation text explaining what happens
- POST button

**Show pages** — handle deleted state:
- If `@note.deleted?`, render "[This note has been deleted]" placeholder
- Still show author, date, and comment section
- Hide action buttons (edit, settings, pin, etc.)

**Comment delete links:**
- "Delete" text link on each comment authored by current user
- `button_to` with `data-turbo-confirm`

**Feed views** — no changes needed (default scope handles filtering).

### Phase 7: Tests

**Model:**
- `soft_delete!` sets deleted_at, deleted_by_id, scrubs text fields
- `deleted?` returns correct value
- Default scope excludes deleted records
- Dependent records preserved after soft delete
- Search index removed after soft delete
- Attachments purged after soft delete

**Controller:**
- Creator can delete own content
- Collective admin can delete others' content
- Regular user cannot delete others' content
- Deleted content show page renders placeholder
- Deleted content excluded from pulse feed
- Comment deletion stays on parent page

**Integration:**
- Full flow: create → delete → verify scrubbed → verify feed excludes → verify show page placeholder → verify comments preserved

## Open Questions

1. **Should deleted content be restorable?** Not in V1. Scrubbed text is gone. If undo is needed later, we'd store scrubbed content in a separate table before scrubbing.

2. **Notifications that reference deleted content?** The notification URL leads to a page showing "[deleted]". Acceptable for V1.

3. **Pins referencing deleted content?** Stale pins are already handled gracefully (find_by returns nil, views guard against nil). Deleted content should also be unpinned during soft delete to keep things clean.

## Dependencies

- **Blocking** should be implemented first (separate plan)
- **Content reporting** depends on this (admins need deletion as a moderation tool)
