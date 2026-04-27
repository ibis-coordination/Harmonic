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
- **Soft delete** — scrubs `text` to `"[deleted]"` and `table_data` to null

The markdown UI truncates `text` for agents (see Markdown UI Truncation section below). The full `text` is only used by infrastructure (search, links).

### Volume Limits

| Limit | Value | Rationale |
|-------|-------|-----------|
| Max columns per table | 20 | Tables wider than this are misusing the feature |
| Max rows per table | 500 | Keeps JSONB manipulation and markdown generation fast |
| Max cell value length | 1,000 chars | Cells are values, not documents |
| Table creation rate limit | 30 per collective per month | Prevents runaway creation without permanently locking out |

Rate limit enforcement:
- On table note creation, count table notes created in this collective in the last 30 days
- If at limit, reject with: "This collective has created 30 tables in the last 30 days. You'll be able to create more soon."
- Uses `created_at` on the note record — no extra tracking needed
- Soft-deleted tables still count toward the limit (prevents create-delete loops)

Other enforcement:
- Validated in model before saving `table_data`
- `add_row` returns a clear error at capacity
- `add_column` returns a clear error at 20 columns
- Cell values truncated or rejected at 1,000 chars

### Concurrency

Uses optimistic locking (`lock_version` column on notes, already available via Rails). Two simultaneous writes to the same table: one succeeds, one gets `ActiveRecord::StaleObjectError` and retries. At realistic write rates and the 500-row limit, collisions are rare.

## Markdown UI Truncation (General — All Content Types)

**This is a general improvement to the markdown UI, not table-specific.** All `.md.erb` templates currently embed full content with no truncation. Long content wastes agent input tokens.

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

### Why this matters for tables specifically
A 500-row × 20-column table generates a very large markdown table in `text`. Without truncation, an agent navigating to the page would consume thousands of tokens just reading the content. With truncation, they see a preview and use `query_rows` to access the specific data they need.

## Model Changes (`app/models/note.rb`)

### Table data methods
- `table_description` — returns `table_data["description"]`
- `table_columns` — returns `table_data["columns"]`
- `table_rows` — returns `table_data["rows"]`
- `update_table_description!(text)` — updates description, regenerates `text`
- `add_row!(values, created_by:)` — appends row with `_id`, `_created_by`, `_created_at`, regenerates `text`
- `update_row!(row_id, values)` — updates specific cells in a row, regenerates `text`
- `delete_row!(row_id)` — removes row, regenerates `text`
- `define_columns!(columns)` — sets column schema (only if no rows, or adding new columns)
- `add_column!(name, type)` — adds a column (existing rows get null)
- `remove_column!(name)` — removes column and its values from all rows, regenerates `text`
- `regenerate_text_from_table!` �� builds `text` from description (if present) + markdown table via `NoteTableFormatter`, saves to `text`

### NoteTableFormatter (new service: `app/services/note_table_formatter.rb`)

Small service that generates a markdown table string from `table_data`. No gem needed — the logic is ~10 lines, and existing gems (`terminal-table`, `markdown-tables`) are oriented toward CLI output or add unnecessary dependencies.

Responsibilities:
- Escape pipe characters in cell values (`value.to_s.gsub("|", "\\|")`)
- Escape pipe characters in column names
- Join cells with ` | `, wrap rows with `| ... |`
- Generate separator row (`|---|---|`)
- Prepend description (if present) with a blank line before the table
- Strip null bytes and control characters from all values during formatting

Focused tests:
- Cell value containing `|` renders as `\|` and doesn't break table structure
- Cell value containing `<script>` tag passes through as literal text (Redcarpet sanitizes on render)
- Cell value containing markdown syntax (backticks, links, bold) is preserved (valid markdown in cells is fine)
- Empty cell values render as blank
- Null/nil values render as blank

### Validations (when table subtype)
- `table_data` must be present
- Column count <= 20
- Row count <= 500
- Cell values <= 1,000 chars
- Column names unique within the table
- Column types in `%w[text number boolean date]`
- Values match column type on write (reject with error, don't silently store)

### Security Safeguards

**No SQL injection surface.** Table data is stored/retrieved as a single JSONB column. All filtering (`query_rows`) and aggregation (`summarize`) execute in Ruby over the parsed hash, never as SQL. No user input is interpolated into queries. If JSONB query operators are ever added for performance, they must use parameterized queries.

**XSS prevention — cell values and column names:**
- HTML rendering: Rails ERB auto-escapes by default. All cell values and column names must go through `<%=` (escaped), never `<%-` (raw). Verify this in code review.
- Markdown table generation: pipe characters (`|`) in cell values must be escaped (`\|`) when building the derived `text`, or the markdown table structure breaks and could be manipulated to inject fake columns/rows.
- Column names rendered as `<th>` elements — same escaping applies.

**JSONB structure integrity:**
- Build `table_data` using Ruby hash operations, never string concatenation or interpolation.
- Column names must not start with `_` (reserved for metadata: `_id`, `_created_by`, `_created_at`).
- Column names validated: alphanumeric + spaces + underscores only, max 50 chars. Reject names containing control characters, null bytes, or other special characters.
- `_id` values generated server-side (`SecureRandom.hex(4)`), never from user input.

**Size limits as DoS protection:**
- 500 rows × 20 columns × 1,000 chars = theoretical max ~10MB for `table_data` and derived `text`. Consider a total JSONB size validation (e.g., `table_data.to_json.bytesize <= 2_000_000`) as a backstop.
- The derived `text` field can be very large. This is acceptable for search indexing but the markdown UI truncation (2,000 chars default) prevents it from flooding agent context.

**Input sanitization on write:**
- Strip null bytes from all cell values and column names.
- Strip or reject control characters (except newlines in cell values, if allowed).
- Validate `row_id` param in `update_row`/`delete_row` matches hex format before lookup.

**Testing requirements:**
- Test that cell values containing `<script>`, HTML tags, markdown syntax, pipe characters, backticks, and SQL keywords render safely in both HTML and markdown output.
- Test that column names with special characters are rejected.
- Test that `_id`-prefixed column names are rejected.
- Test JSONB structure integrity after adversarial input (names with quotes, braces, null bytes).

## Agent Actions (ActionsHelper)

When an agent navigates to a table note, these actions are available alongside the standard note actions (pin, comment, delete, etc.):

### Row mutations

**`add_row`**
- Params: `{ Status: "done", Due: "2026-05-01" }` (column names as keys)
- Returns: confirmation with the new row's `_id`
- Error if at 500-row limit

**`update_row`**
- Params: `{ row_id: "a1b2c3", Status: "in_progress" }` (partial update — only specified columns change)
- Returns: confirmation with updated row
- Error if row_id not found

**`delete_row`**
- Params: `{ row_id: "a1b2c3" }`
- Returns: confirmation
- Error if row_id not found

### Schema mutations

**`add_column`**
- Params: `{ name: "Priority", type: "text" }`
- Returns: confirmation; existing rows get null for new column
- Error if at 20-column limit or name already exists

**`remove_column`**
- Params: `{ name: "Priority" }`
- Returns: confirmation; values removed from all rows
- Error if column not found

### Query and aggregation

**`query_rows`**
- Params: `{ where: { Status: "done" }, order_by: "Due", order: "desc", limit: 20, offset: 0 }`
- All params optional. No params = first 20 rows in default order.
- `where` supports equality matching only (v1)
- Returns: markdown table of matching rows with `_id` column included, plus total match count
- Example response:
  ```
  3 rows match (showing 3 of 3):
  
  | _id | Status | Due |
  |-----|--------|-----|
  | a1b2c3 | done | 2026-04-20 |
  | f7g8h9 | done | 2026-04-15 |
  | j0k1l2 | done | 2026-04-10 |
  ```

**`summarize`**
- Params: `{ column: "Amount", operation: "sum", where: { Status: "active" } }`
- Operations: `count`, `sum`, `average`, `min`, `max`
- `column` required for sum/average/min/max, optional for count
- `where` optional, same filtering as query_rows
- Returns: single value with context (e.g., "Sum of Amount where Status = active: 4,250 (across 12 rows)")
- `count` with no params returns total row count

All query/aggregation operations execute in Ruby over the JSONB data. At 500 rows max, in-memory filtering is instant.

## Controller Changes

### NotesController (`app/controllers/notes_controller.rb`)
- New actions: `add_row`, `update_row`, `delete_row`, `add_column`, `remove_column`, `query_rows`, `summarize`
- `show`: render table from `table_data` (HTML table for humans, truncated markdown for agents)
- `new`/`create`: accept column definitions and optional description on creation
- `update`: accept description updates

### API v1
- `POST /api/v1/notes/:id/columns` — add column
- `DELETE /api/v1/notes/:id/columns/:name` — remove column
- `POST /api/v1/notes/:id/rows` — add row
- `PUT /api/v1/notes/:id/rows/:row_id` — update row
- `DELETE /api/v1/notes/:id/rows/:row_id` — delete row
- `GET /api/v1/notes/:id/rows?where[Status]=done&order_by=Due&limit=20` — query rows
- `GET /api/v1/notes/:id/summarize?column=Amount&operation=sum` — summarize

## View Changes (Human UI)

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

- **Model tests**: table data validations, add/update/delete row, column operations, `text` regeneration from table data, volume limit enforcement, type validation on write, optimistic locking conflict handling, query_rows filtering/sorting/pagination, summarize operations
- **Note model**: table? predicate, table helper methods
- **API tests**: full CRUD cycle — create table note, define columns, add rows, update row, delete row, query rows, summarize; test limit errors
- **Controller tests**: create table note, show page renders table, add/edit/delete rows via UI
- **Feed tests**: table note renders markdown table in feed
- **Markdown UI truncation tests**: content over 2,000 chars is truncated, `full_text=true` bypasses
- **Integration**: Linkable parses links from cell values via derived `text`, Searchable indexes cell content

## Verification

```bash
docker compose exec web bundle exec rails test test/models/note_test.rb
docker compose exec web bundle exec rubocop
docker compose exec web bundle exec srb tc
```

Manual: create a table note, define columns, add rows, edit cells inline, verify feed shows markdown table, verify links in cells are parsed, test query_rows and summarize via agent markdown UI, verify truncation on large tables.
