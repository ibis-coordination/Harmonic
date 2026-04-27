# Content Subtypes — Table Note

## Context

A "table" note is a lightweight table — structured, tabular data with named columns and typed rows. It serves both humans (rendered as an editable table) and AI agents (row-level API operations for memory, logging, coordination, and state tracking).

This is strictly record-oriented and tabular. JSON blobs, YAML documents, and freeform structured text belong in regular text notes.

**Depends on:** [Foundation](content-subtypes-foundation.md)

## Agent Use Cases

- **Action log** — agent appends rows as it takes actions (append-only audit trail)
- **Task tracker** — agent maintains a table of tasks with status, humans can view and edit it too
- **Observations/metrics** — agent records structured data over time (dates, numbers, categories)
- **Coordination table** — multiple agents share state ("I'm handling X, you handle Y")
- **Configuration** — agent stores settings as a two-column key/value table instead of the limited 10KB scratchpad
- **Shared state** — unlike the per-agent scratchpad, table notes are visible to the whole collective

## Data Model

### Storage

One new JSONB column on notes. No new tables.

```ruby
add_column :notes, :table_data, :jsonb, null: true
```

Null for all non-table notes. For table notes, structure:

```json
{
  "description": "Tracks outstanding tasks for the Q2 launch.",
  "columns": [
    { "name": "Status", "type": "text" },
    { "name": "Due", "type": "date" }
  ],
  "rows": [
    { "_id": "a1b2c3", "_created_by": "user-uuid", "_created_at": "2026-04-27T...", "Status": "done", "Due": "2026-04-20" },
    { "_id": "d4e5f6", "_created_by": "user-uuid", "_created_at": "2026-04-27T...", "Status": "in_progress", "Due": "2026-04-28" }
  ]
}
```

`description` is optional free text describing the table's purpose.

Row `_id` values are generated on insert (e.g., `SecureRandom.hex(4)`) for use in `update_row`/`delete_row`.

### Derived `text` Column

After every table mutation (add/update/delete row, add/remove column), the note's `text` column is regenerated as the full markdown table. This is the complete content — all rows, not truncated.

```markdown
Tracks outstanding tasks for the Q2 launch.

| Status | Due |
|--------|-----|
| done | 2026-04-20 |
| in_progress | 2026-04-28 |
```

The description (if present) is prepended before the markdown table. This means existing infrastructure works without special-case logic for table notes:
- **Linkable** — parses links from `text` as normal (all cell values included)
- **Searchable** — indexes `text` as normal (all cell values searchable)
- **Tracked** — content snapshots include the markdown table
- **Feed rendering** — existing text rendering shows the table
- **Soft delete** — scrubs `text` to `"[deleted]"` and `table_data` to null (table validation is skipped when `deleted_at` is set)

The markdown UI truncates `text` for agents (see Markdown UI Truncation section below). The full `text` is only used by infrastructure (search, links).

### Volume Limits

| Limit | Value | Rationale |
|-------|-------|-----------|
| Max columns per table | 20 | Tables wider than this are misusing the feature |
| Max rows per table | 500 | Keeps JSONB manipulation and markdown generation fast |
| Max cell value length | 1,000 chars | Cells are values, not documents |
| Max total JSONB size | 2 MB | Backstop against combined large content |

Enforcement via `NoteTableValidator` — validated on every save. No per-collective rate limit (table notes have the same storage footprint as regular notes with the JSONB design).

## Architecture: Service Objects

Table-specific logic lives in three typed service objects, not in the Note model or concerns:

- **`NoteTableService`** (`app/services/note_table_service.rb`, typed: true) — mutations, queries, aggregation, batch operations
- **`NoteTableValidator`** (`app/services/note_table_validator.rb`, typed: true) — validation logic, constants
- **`NoteTableFormatter`** (`app/services/note_table_formatter.rb`, typed: true) — markdown generation with pipe escaping and sanitization

The Note model has only thin hooks:
- `validate :validate_table_data` — delegates to `NoteTableValidator.validate`
- `scrub_content!` — sets `table_data = nil` on soft delete

Usage pattern:
```ruby
table = NoteTableService.new(note)
table.add_row!({ "Status" => "done" }, created_by: user)
table.query_rows(where: { "Status" => "done" })
table.batch_update! do |t|
  t.add_row!({ "Status" => "a" }, created_by: user)
  t.add_row!({ "Status" => "b" }, created_by: user)
end
```

### Batch Operations

`batch_update!` wraps multiple mutations in a block — changes accumulate in memory, then save once at the end. One save = one history event = one automation trigger. Use when making multiple changes in a single request.

## Markdown UI Truncation (General — All Content Types)

**Not yet implemented.** This is a general improvement to the markdown UI, not table-specific. All `.md.erb` templates currently embed full content with no truncation. Long content wastes agent input tokens.

### Behavior
- Default character limit: 2,000 characters for the content body
- When content exceeds the limit, truncate and append:
  ```
  ... (showing 2,000 of 42,547 characters)
  To view full content, navigate to: .../n/abc123?full_text=true
  ```
- `?full_text=true` query param bypasses truncation and returns the full content
- Applies to `@note.text`, `@decision.description`, `@commitment.description` in their respective `.md.erb` templates

### Files to modify
- `app/views/notes/show.md.erb`
- `app/views/decisions/show.md.erb`
- `app/views/commitments/show.md.erb`
- Could extract a shared helper: `MarkdownHelper.truncate_content(text, limit: 2000, url:)`

## NoteTableValidator (`app/services/note_table_validator.rb`)

Validations (when table subtype):
- `table_data` must be present (Hash)
- Column count <= 20
- Row count <= 500
- Cell values <= 1,000 chars
- Total JSONB size <= 2 MB
- Column names unique within the table
- Column names: alphanumeric + spaces + underscores only, max 50 chars, cannot start with `_`
- Column types in `%w[text number boolean date]`

Deferred for future iteration:
- Type checking on cell values (e.g., rejecting "abc" in a number column)

## NoteTableFormatter (`app/services/note_table_formatter.rb`)

Generates markdown table from `table_data`:
- Escapes pipe characters in cell values and column names
- Sanitizes null bytes and control characters from all values and description
- Prepends description (if present) with a blank line before the table

## Security Safeguards

**No SQL injection surface.** Table data is stored/retrieved as a single JSONB column. All filtering (`query_rows`) and aggregation (`summarize`) execute in Ruby over the parsed hash, never as SQL.

**XSS prevention:** Rails ERB auto-escapes by default. Pipe escaping in markdown generation prevents table structure manipulation.

**JSONB structure integrity:** Column names validated against `COLUMN_NAME_FORMAT`, `_` prefix reserved, `_id` values generated server-side. All data built with Ruby hash operations, never string interpolation.

**Input sanitization:** NoteTableFormatter strips null bytes and control characters from all values during markdown generation.

## Agent Actions (ActionsHelper)

**Not yet implemented.** When an agent navigates to a table note, these actions will be available:

### Row mutations
- **`add_row`** — `{ Status: "done", Due: "2026-05-01" }`
- **`update_row`** — `{ row_id: "a1b2c3", Status: "in_progress" }` (partial update)
- **`delete_row`** — `{ row_id: "a1b2c3" }`

### Schema mutations
- **`add_column`** — `{ name: "Priority", type: "text" }`
- **`remove_column`** — `{ name: "Priority" }`

### Query and aggregation
- **`query_rows`** — `{ where: { Status: "done" }, order_by: "Due", order: "desc", limit: 20, offset: 0 }`
- **`summarize`** — `{ column: "Amount", operation: "sum", where: { Status: "active" } }`

## Controller Changes

**Not yet implemented.**

### NotesController
- New actions for table operations, delegating to `NoteTableService`
- `show`: render table from `table_data` (HTML table for humans, truncated markdown for agents)
- `new`/`create`: accept column definitions and optional description on creation

### API v1
- `POST /api/v1/notes/:id/columns` — add column
- `DELETE /api/v1/notes/:id/columns/:name` — remove column
- `POST /api/v1/notes/:id/rows` — add row
- `PUT /api/v1/notes/:id/rows/:row_id` — update row
- `DELETE /api/v1/notes/:id/rows/:row_id` — delete row
- `GET /api/v1/notes/:id/rows?where[Status]=done&order_by=Due&limit=20` — query rows
- `GET /api/v1/notes/:id/summarize?column=Amount&operation=sum` — summarize

## View Changes (Human UI)

**Not yet implemented.**

### Creation form (`app/views/notes/new.html.erb`)
- When "Table" selected: show a column definer (name + type for each column)
- Start with 2-3 empty column fields, "add column" button
- No row entry on creation — add rows after

### Show page (`app/views/notes/show.html.erb`)
- Show editable description above the table (from `table_data["description"]`)
- Render as an HTML table with column headers and rows (from `table_data`, not `text`)
- Inline cell editing (click to edit, Stimulus controller)
- "Add row" button at bottom of table
- Row-level actions: delete row
- Column header shows type indicator
- Empty state: "No rows yet. Add a row to get started."

### Feed (`app/components/feed_item_component.rb` + template)
- Type label: "Table"
- The existing text rendering will show the markdown table naturally
- Could enhance later with a proper HTML table preview, but markdown works for v1

### ResourceHeaderComponent
- Type label: "Table"

## Testing

- **`test/services/note_table_service_test.rb`** — CRUD, schema mutations, batch operations, query, summarize
- **`test/services/note_table_formatter_test.rb`** — markdown generation, pipe escaping, null byte stripping, XSS safety
- **`test/models/note_test.rb`** — table validations (column limits, name rules, cell length, type rules, presence), soft delete

## Help Documentation

After actions and interfaces are implemented:
- Add help content explaining table notes (creating tables, adding rows, querying, batch operations)
- Document agent-specific capabilities (row-level actions, query_rows, summarize)
- Update any existing help pages that reference notes

## Verification

```bash
docker compose exec web bundle exec rails test test/models/note_test.rb test/services/note_table_service_test.rb test/services/note_table_formatter_test.rb
docker compose exec web bundle exec rubocop
docker compose exec web bundle exec srb tc
```

Manual: create a table note, define columns, add rows, edit cells inline, verify feed shows markdown table, verify links in cells are parsed, test query_rows and summarize via agent markdown UI, verify truncation on large tables.
