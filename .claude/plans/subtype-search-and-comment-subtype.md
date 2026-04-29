# Subtype Search & Comment Subtype

## Context

The search system has a `subtype:` filter that only recognizes `"comment"`. But notes now have real subtypes (text, reminder, table), and decisions (vote, lottery, log) and commitments (action, calendar_event, policy) also have subtypes. Users can't search for `subtype:table` or `subtype:reminder`. Additionally, "comment" isn't a real subtype value on the Note model — it's an implicit distinction based on `commentable_type`/`commentable_id` being set, while the actual `subtype` column stays `"text"`.

**Goals:**
1. Make "comment" a real `subtype` value on the Note model
2. Index all subtypes (Note, Decision, Commitment) in the search index
3. Make `subtype:` filter work for all subtypes across all item types

## Change 1: Make "comment" a real subtype

### Model changes

**`app/models/note.rb`**:
- Add `"comment"` to `SUBTYPES`: `%w[text reminder table comment].freeze`
- Change `comments_must_be_text_subtype` → `comments_must_be_comment_subtype`: validate that notes with `commentable` set must have `subtype: "comment"`, and notes without `commentable` must NOT have `subtype: "comment"`
- Text validation: `validates :text, presence: true, unless: -> { is_table? }` — comments have text, so this still works

**`app/models/concerns/commentable.rb`**:
- `add_comment`: add `subtype: "comment"` to the create attributes

**`app/services/api_helper.rb`**:
- `create_note`: when `commentable` is provided, force `subtype: "comment"` regardless of what params say

### Migration

- `UPDATE notes SET subtype = 'comment' WHERE commentable_type IS NOT NULL AND commentable_id IS NOT NULL`
- This is a data-only migration — no schema change needed since `subtype` is already a varchar column

### Risk assessment

- `is_text?` returns false for comments (was true before) — only used in the `comments_must_be_text_subtype` validation itself, nowhere else
- `where(subtype: "text")` queries — grep found none in app code
- Feed builder filters by `where(commentable_type: nil)`, not by subtype — unaffected
- `Note::SUBTYPES.include?(params[:subtype])` in the controller defaults to "text" for unknown values — "comment" would now be recognized, but the creation form doesn't offer it as a tab (correct, comments are created through the comment flow)

## Change 2: Index all subtypes in search

### SearchIndexer

**`app/services/search_indexer.rb`** — `subtype` method:
- Return `@item.subtype` for all item types (Note, Decision, Commitment all have a `subtype` column)
- This replaces the special-case `"comment"` check — since Change 1 makes "comment" a real subtype value, `@item.subtype` returns `"comment"` for comment notes automatically

### SearchQueryParser

**`app/services/search_query_parser.rb`**:
- Change `"subtype" => { values: ["comment"], multi: true }` to accept all known subtypes:
  ```ruby
  "subtype" => { values: Note::SUBTYPES + Decision::SUBTYPES + Commitment::SUBTYPES, multi: true }
  ```
- This automatically extends when new subtypes are added to any model

### SearchQuery

**`app/services/search_query.rb`** — `apply_subtype_filter`:
- Simplify the exclusion logic: since all items now have a non-null `subtype`, the `IS NULL` handling is no longer needed for new records
- Keep backwards-compatible NULL handling for any old records not yet reindexed

### Help documentation

**`app/views/help/search.md.erb`**:
- Update the subtype filter docs to list all valid values

### Reindex

- After deploying, run a full reindex to populate subtype for all existing records
- Can be done via `SearchIndex.reindex_all!` or a rake task if one exists

## Files Changed

| File | Change |
|------|--------|
| `app/models/note.rb` | Add "comment" to SUBTYPES, update validation |
| `app/models/concerns/commentable.rb` | Add `subtype: "comment"` to add_comment |
| `app/services/api_helper.rb` | Force `subtype: "comment"` when commentable present |
| `app/services/search_indexer.rb` | Return `@item.subtype` for all types |
| `app/services/search_query_parser.rb` | Expand allowed subtype values |
| `app/services/search_query.rb` | Simplify NULL handling (keep backwards-compat) |
| `app/views/help/search.md.erb` | Update subtype filter docs |
| `db/migrate/XXXX_set_comment_subtype.rb` | Data migration for existing comments |
| Tests for all of the above |

## Verification

```bash
# Tests
docker compose exec web bundle exec rails test test/models/note_test.rb test/services/search_indexer_test.rb test/services/search_query_test.rb test/services/search_query_parser_test.rb test/controllers/notes_controller_test.rb test/services/api_helper_test.rb

# Type checks
docker compose exec web bundle exec srb tc

# Manual verification
# 1. Create a reminder note, table note, and comment
# 2. Search for subtype:reminder, subtype:table, subtype:comment
# 3. Search for -subtype:comment to exclude comments
# 4. Verify comment creation still works through the UI
```
