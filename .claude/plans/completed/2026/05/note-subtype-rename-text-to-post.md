# Rename Note Subtype `text` → `post`

After Phase 2 of the image-handling work, the `text` note subtype can carry images, links, tables-of-contents, and other rich content — not just text. The name became misleading. This plan renames the subtype value across the codebase, DB, and external surfaces. Clean break, no backwards-compatibility alias.

## Why `post`

- Names the role ("a free-form thing a user posts to a collective"), not the content shape.
- Familiar from social/messaging products; no new mental model.
- Not recursive like `note` (which would force `note.subtype == "note"`).
- Open-ended enough that future content-shape additions (embedded polls, code blocks, etc.) don't make the name lie again.

Alternative `standard` was considered and rejected as too colorless for a user-facing label.

## Scope

This is a values-column rename, not a schema rename. The column stays `notes.subtype`; only the value `"text"` becomes `"post"`. Other subtypes (`reminder`, `table`, `comment`, `statement`) are unaffected.

### Code

| Area | What changes |
|---|---|
| [app/models/note.rb](../../app/models/note.rb) | `SUBTYPES` constant: `"text"` → `"post"`. `is_text?` method renamed to `is_post?` and its body updated. All call sites of `is_text?` updated. |
| [app/controllers/notes_controller.rb](../../app/controllers/notes_controller.rb) | `@subtype = ... ? params[:subtype] : "text"` default → `"post"`. `create` dispatcher's `else create_text_note` branch renamed to `else create_post_note` (and its definition). |
| [app/services/api_helper.rb](../../app/services/api_helper.rb) | `subtype: commentable ? "comment" : (params[:subtype] || "text")` default → `"post"`. |
| [app/views/notes/new.html.erb](../../app/views/notes/new.html.erb) | Button label "Text" → "Post". `@subtype == 'text'` checks → `'post'`. |
| [app/javascript/controllers/note_subtype_controller.ts](../../app/javascript/controllers/note_subtype_controller.ts) | `subtype === "text"` checks → `"post"`. `selectText()` method renamed to `selectPost()`. Hidden input default value `"text"` → `"post"`. Target name `textBtn` → `postBtn` (for consistency) or leave as a CSS-class style legacy name (decision: rename for clarity). |
| Markdown + view templates | Any references to `"text"` as subtype label updated. The string `"Text"` as a user-facing label becomes `"Post"`. |
| Tests | All `subtype: "text"` fixtures → `"post"`. `is_text?` assertions updated. Stimulus controller tests updated. |
| Help docs | [app/views/help/notes.md.erb](../../app/views/help/notes.md.erb) — "Use the **Text** / **Table** toggle" → "**Post** / **Table**". [app/views/help/search.md.erb:26](../../app/views/help/search.md.erb#L26) — search filter `text` → `post`. |

### DB migration

A small Rails migration:

```ruby
class RenameTextSubtypeToPost < ActiveRecord::Migration[7.2]
  def up
    Note.unscoped.where(subtype: "text").in_batches.update_all(subtype: "post")
  end

  def down
    Note.unscoped.where(subtype: "post").in_batches.update_all(subtype: "text")
  end
end
```

`unscoped` because the migration runs without a tenant context. `in_batches` to avoid a single huge UPDATE. The `down` path lets us roll back if the deploy reveals a missed code path.

### Search index

Each Note's `search_indexes` row caches `subtype` for filter queries (`subtype:post`). Two paths:

1. Let the existing per-note reindex job catch up naturally as users edit notes. Slow but free.
2. Run a one-shot rake task that batches `SearchIndex.where(item_type: "Note", subtype: "text").update_all(subtype: "post")` after the DB migration.

Recommend path 2 — same migration window, predictable end state. Add as a second step in the migration above (after the `Note.update_all`).

### API contract — clean break

Any external client sending `subtype: "text"` to `POST /collectives/.../note` or `POST /api/v1/notes` will hit `validates :subtype, inclusion: { in: SUBTYPES }` and get a 422. No silent aliasing. Communicate the change to:

- Anything in `mcp-server/` that posts notes (audit first).
- Anything in `agent-runner/` (audit first).
- External users via release notes / CHANGELOG.

Audit each integration before merge — list every code path that constructs a `subtype:` param, confirm it now sends `"post"`. Static check: a one-time grep for `subtype.*text` across `mcp-server/`, `agent-runner/`, and any vendored agent code.

### Search filter syntax — clean break

`subtype:text` in a search query stops matching anything after the data migration. Search filter docs are updated to say `subtype:post`. Saved searches with the old syntax silently return empty results. Acceptable: the search UI lists active filters, so users see what they have.

## Order of operations

1. PR: code rename + DB migration + index rake task + docs update + test updates.
2. Deploy the code. The migration runs as part of deploy.
3. Search-index backfill task runs as a post-deploy step (Rake invocation or one-shot Sidekiq job).
4. Watch error logs for any 422s on `subtype: "text"` — those are external callers we missed.

## Risks

- **External integrations sending `"text"`** silently break. Mitigation: pre-merge audit of every known caller. Documenting the break in release notes.
- **In-flight HTTP requests** during deploy that submit `subtype: "text"` get 422'd. Acceptable; same window as any normal deploy.
- **Saved search URLs** with `subtype:text` return empty. Acceptable; visible in the filter UI.
- **Cached pages / CDN** could render the old "Text" label briefly. Acceptable; flushes within minutes.

## Non-goals

- Renaming the `is_comment?` / `is_reminder?` / `is_statement?` predicate family — those names still describe their content shape accurately.
- Refactoring how subtypes are stored (still a `string` column, not STI).
- Backwards-compatibility shim — explicit non-goal per the decision to take a clean break.

## Test plan

- All existing Note tests pass after the rename (fixtures updated).
- New test: `Note.create!(subtype: "text")` raises `ActiveRecord::RecordInvalid` (proves no legacy value sneaks through).
- New test: the DB migration's `up` correctly transitions `"text"` → `"post"`; `down` reverses it.
- Stimulus controller tests: clicking the "Post" button sets the hidden input to `"post"`.
- A grep-based CI guard (small shell script in `scripts/`) that fails if any source file contains the literal `'text'` or `"text"` adjacent to `subtype` outside the migration file. Prevents reintroducing the old value during long-lived branches.

## Estimated size

~30-35 files. Half are tests. Mechanical; one PR; one reviewer pass.
