# Search DSL Design

## Overview

Replace the multi-field search form with a single text input that parses a search DSL. Users type a single query string that includes both search terms and filter/sort/group operators.

## Goals

1. **Single input** - One text field for everything
2. **Intuitive** - Familiar patterns from GitHub, Gmail, Slack search
3. **Discoverable** - Autocomplete and help text guide users
4. **Backwards compatible** - Plain text still works as a simple search
5. **Explicit operators** - Operator names are clear and unambiguous

## DSL Syntax

### Basic Search

Plain text searches content using trigram matching:

```
budget proposal
```

### Quoted Phrases

Exact phrase matching (still uses trigram, but requires all words in order):

```
"budget proposal"
```

### Negation

Prefix operators with `-` to negate:

```
-creator:@alice       # Not created by alice
-type:note            # Exclude notes
-read-by:@myhandle    # Items I haven't read
```

### Operators

Operators use `key:value` syntax. No spaces around the colon.

#### Location Scope

| Operator | Values | Description |
|----------|--------|-------------|
| `studio:` | handle | Scope to a specific studio |
| `scene:` | handle | Scope to a specific scene |

#### User Filters

All user filters accept `@handle` format.

| Operator | Description |
|----------|-------------|
| `creator:` | Created by user |
| `read-by:` | Read by user |
| `voter:` | User voted on decision |
| `participant:` | User joined commitment |
| `mentions:` | User is @mentioned in content |
| `replying-to:` | Comment on content created by user |

#### Type Filters

| Operator | Values | Description |
|----------|--------|-------------|
| `type:` | `note`, `decision`, `commitment` | Filter by item type |
| `subtype:` | `comment` | Filter by subtype |
| `status:` | `open`, `closed` | Open (future deadline) or closed (past deadline) |

#### Boolean Filters

| Operator | Values | Description |
|----------|--------|-------------|
| `critical-mass-achieved:` | `true`, `false` | Commitment reached critical mass |

#### Integer Filters (min/max)

Count-based filters use `min-*:N` and `max-*:N` syntax.

| Operator | Description |
|----------|-------------|
| `min-links:` / `max-links:` | Outgoing link count |
| `min-backlinks:` / `max-backlinks:` | Incoming backlink count |
| `min-comments:` / `max-comments:` | Comment count |
| `min-readers:` / `max-readers:` | Reader count (notes only) |
| `min-voters:` / `max-voters:` | Voter count (decisions only) |
| `min-participants:` / `max-participants:` | Participant count (commitments only) |

#### Time Filters

| Operator | Values | Description |
|----------|--------|-------------|
| `cycle:` | See cycle values below | Named time window |
| `after:` | `YYYY-MM-DD` or `-Nd/w/m/y` | Items created after date |
| `before:` | `YYYY-MM-DD` or `+Nd/w/m/y` | Items with deadline before date |

#### Display Options

| Operator | Values | Description |
|----------|--------|-------------|
| `sort:` | `newest`, `oldest`, `updated`, `deadline`, `relevance`, `backlinks` | Sort order |
| `group:` | `type`, `status`, `date`, `week`, `month`, `none` | Grouping |
| `limit:` | `1-100` | Results per page |

### Cycle Values

Cycles are named time periods. The search filters to items where `created_at < cycle.end_date AND deadline > cycle.start_date`.

| Value | Description |
|-------|-------------|
| `today` | Current day |
| `yesterday` | Previous day |
| `tomorrow` | Next day |
| `this-week` | Current week |
| `last-week` | Previous week |
| `next-week` | Next week |
| `this-month` | Current month |
| `last-month` | Previous month |
| `next-month` | Next month |
| `this-year` | Current year |
| `last-year` | Previous year |
| `next-year` | Next year |
| `N-days-ago` | N days ago (e.g., `2-days-ago`) |
| `N-weeks-ago` | N weeks ago (e.g., `3-weeks-ago`) |
| `N-months-ago` | N months ago |
| `N-years-ago` | N years ago |
| `all` | No time restriction |

### Custom Date Ranges

Use `after:` and `before:` for explicit date boundaries:

**Absolute dates** use `YYYY-MM-DD` format:
```
after:2024-01-01                    # Created after Jan 1, 2024
before:2024-12-31                   # Deadline before Dec 31, 2024
after:2024-01-01 before:2024-03-31  # Q1 2024
```

**Relative dates** require an explicit sign (`+` for future, `-` for past):
```
after:-7d                           # Created after 7 days ago (last week)
after:-2w                           # Created after 2 weeks ago
before:+14d                         # Deadline before 14 days from now
before:+1m                          # Deadline before 1 month from now
after:-1y                           # Created after 1 year ago
```

Supported units: `d` (days), `w` (weeks), `m` (months), `y` (years)

**Invalid** (no sign = treated as search text):
```
after:7d                            # Invalid - parsed as search text "after:7d"
```

These override `cycle:` if both are specified.

### Operator Aliases

For convenience, common operators have short forms:

| Short | Full |
|-------|------|
| `type:n` | `type:note` |
| `type:d` | `type:decision` |
| `type:c` | `type:commitment` |
| `sort:new` | `sort:newest` |
| `sort:old` | `sort:oldest` |

### Multiple Values

Use commas for OR within an operator:

```
type:note,decision       # Notes OR decisions
creator:@alice,@bob      # Created by alice OR bob
```

### Examples

```
# Everything in mystudio from the last 7 days that I haven't seen yet
studio:mystudio after:-7d -read-by:@myhandle -voter:@myhandle -participant:@myhandle

# Decisions I haven't voted on yet
type:decision status:open -voter:@myhandle

# Commitments I've joined that reached critical mass
type:commitment participant:@myhandle critical-mass-achieved:true

# Original notes (not comments)
type:note -subtype:comment

# Notes with many readers
type:note min-readers:10

# Items I created that have backlinks
creator:@myhandle min-backlinks:1

# Search in a specific scene
scene:planning-session budget

# Replies to my content
replying-to:@myhandle

# Items that mention me
mentions:@myhandle

# Complex query
"quarterly review" type:note,decision status:open sort:newest limit:10
```

## Parsing Rules

1. **Tokenization**: Split on whitespace, respecting quoted strings
2. **Operator detection**: Tokens matching `key:value` or `-key:value` are operators
3. **Remaining tokens**: Everything else is the search text
4. **Multiple operators**: Later operators override earlier ones (except negations which accumulate)
5. **Invalid operators**: Treated as search text (e.g., `foo:bar` searches for "foo:bar")

### Parsing Examples

| Input | Parsed As |
|-------|-----------|
| `budget type:note` | query="budget", type=["note"] |
| `type:note budget` | query="budget", type=["note"] |
| `"hello world" status:open` | query="hello world", status="open" |
| `foo:bar` | query="foo:bar" (invalid operator) |
| `type:note type:decision` | type=["decision"] (last wins) |
| `-creator:@me -status:closed` | exclude mine AND closed |

## Data Model Requirements

### SearchIndex Changes

Add `reader_count` column to search_index table:

```ruby
class AddReaderCountToSearchIndex < ActiveRecord::Migration[7.0]
  def change
    add_column :search_index, :reader_count, :integer, default: 0
  end
end
```

Update `SearchIndexer` to calculate reader count from `NoteHistoryEvent` read confirmations.

### Query Implementation

User-based filters require joining with `user_item_status` table:

| Filter | Join/Query |
|--------|------------|
| `creator:@handle` | `search_index.created_by_id` → `tenant_users.handle` |
| `read-by:@handle` | JOIN `user_item_status` WHERE `has_read = true` |
| `voter:@handle` | JOIN `user_item_status` WHERE `has_voted = true` |
| `participant:@handle` | JOIN `user_item_status` WHERE `is_participating = true` |
| `mentions:@handle` | JOIN `user_item_status` WHERE `is_mentioned = true` |
| `replying-to:@handle` | Notes WHERE `commentable.created_by.handle = @handle` |

## Implementation

### Files to Modify

| File | Changes |
|------|---------|
| `app/services/search_query_parser.rb` | Add new operators, remove old ones |
| `app/services/search_query.rb` | Implement user-based filters with joins |
| `app/services/search_indexer.rb` | Add reader_count calculation |
| `app/models/search_index.rb` | Add reader_count attribute |
| `db/migrate/*_add_reader_count.rb` | New migration |

### View Updates

#### Header Search Controller

Update `app/javascript/controllers/header_search_controller.ts`:
- Change auto-populated prefix from `in:${handle}` to `studio:${handle}` or `scene:${handle}`
- Need superagent type to determine which operator to use

Update `app/views/layouts/_top_right_menu.html.erb`:
- Pass `superagent_type` value to the controller
- Add `data-header-search-superagent-type-value` attribute

```erb
<%# Before %>
data-header-search-superagent-handle-value="<%= search_superagent&.handle %>"

<%# After %>
data-header-search-superagent-handle-value="<%= search_superagent&.handle %>"
data-header-search-superagent-type-value="<%= search_superagent&.superagent_type %>"
```

```typescript
// header_search_controller.ts
onFocus(): void {
  const handle = this.superagentHandleValue
  const type = this.superagentTypeValue // "studio" or "scene"

  if (!this.hasAutoPopulated && input.value.trim() === "" && handle && type) {
    input.value = `${type}:${handle} `
    // ...
  }
}
```

#### Search Results Page (HTML)

Update `app/views/search/show.html.erb` help section:

```erb
<table class="pulse-table" style="font-size: 0.85rem;">
  <thead>
    <tr><th>Operator</th><th>Values</th><th>Example</th></tr>
  </thead>
  <tbody>
    <tr><td><code>type:</code></td><td>note, decision, commitment</td><td><code>type:note</code></td></tr>
    <tr><td><code>subtype:</code></td><td>comment</td><td><code>-subtype:comment</code></td></tr>
    <tr><td><code>status:</code></td><td>open, closed</td><td><code>status:open</code></td></tr>
    <tr><td><code>studio:</code></td><td>studio handle</td><td><code>studio:my-studio</code></td></tr>
    <tr><td><code>scene:</code></td><td>scene handle</td><td><code>scene:planning</code></td></tr>
    <tr><td><code>creator:</code></td><td>@handle</td><td><code>creator:@alice</code></td></tr>
    <tr><td><code>read-by:</code></td><td>@handle</td><td><code>-read-by:@myhandle</code></td></tr>
    <tr><td><code>voter:</code></td><td>@handle</td><td><code>-voter:@myhandle</code></td></tr>
    <tr><td><code>participant:</code></td><td>@handle</td><td><code>participant:@myhandle</code></td></tr>
    <tr><td><code>mentions:</code></td><td>@handle</td><td><code>mentions:@myhandle</code></td></tr>
    <tr><td><code>replying-to:</code></td><td>@handle</td><td><code>replying-to:@myhandle</code></td></tr>
    <tr><td><code>min-*/max-*:</code></td><td>links, backlinks, comments, readers, voters, participants</td><td><code>min-backlinks:1</code></td></tr>
    <tr><td><code>critical-mass-achieved:</code></td><td>true, false</td><td><code>critical-mass-achieved:true</code></td></tr>
    <tr><td><code>sort:</code></td><td>newest, oldest, updated, deadline, relevance</td><td><code>sort:newest</code></td></tr>
    <tr><td><code>group:</code></td><td>type, status, date, week, month, none</td><td><code>group:type</code></td></tr>
    <tr><td><code>cycle:</code></td><td>today, this-week, last-month, etc.</td><td><code>cycle:this-week</code></td></tr>
    <tr><td><code>after:</code></td><td>YYYY-MM-DD or -Nd/-Nw/-Nm/-Ny</td><td><code>after:-7d</code></td></tr>
    <tr><td><code>before:</code></td><td>YYYY-MM-DD or +Nd/+Nw/+Nm/+Ny</td><td><code>before:+2w</code></td></tr>
    <tr><td><code>limit:</code></td><td>1-100</td><td><code>limit:25</code></td></tr>
  </tbody>
</table>
<p style="font-size: 0.85rem; color: var(--color-fg-muted); margin-top: 0.75rem;">
  <strong>Examples:</strong>
  <code style="display: block; margin: 0.25rem 0;">budget type:note status:open sort:newest</code>
  <code style="display: block; margin: 0.25rem 0;">type:decision -voter:@myhandle status:open</code>
  <code style="display: block; margin: 0.25rem 0;">studio:team-alpha after:-7d -read-by:@myhandle</code>
</p>
```

#### Search Results Page (Markdown)

Update `app/views/search/show.md.erb` to show current filters using new operator names:

```erb
<% if @search.superagent.present? -%>
<%= @search.superagent.superagent_type %>: <%= @search.superagent.handle %>
<% end -%>
```

#### Input Placeholder

Update placeholder text in both header search and search page:

```erb
<%# _top_right_menu.html.erb %>
placeholder="Search (try studio:handle or type:note)"

<%# search/show.html.erb %>
placeholder="budget type:note status:open studio:my-studio"
```

### SearchQueryParser Updates

```ruby
OPERATORS = {
  # Location scope
  "studio" => { pattern: /^[a-zA-Z0-9-]+$/i, multi: false },
  "scene" => { pattern: /^[a-zA-Z0-9-]+$/i, multi: false },

  # User filters
  "creator" => { pattern: /^@[a-zA-Z0-9_-]+$/, multi: true },
  "read-by" => { pattern: /^@[a-zA-Z0-9_-]+$/, multi: true },
  "voter" => { pattern: /^@[a-zA-Z0-9_-]+$/, multi: true },
  "participant" => { pattern: /^@[a-zA-Z0-9_-]+$/, multi: true },
  "mentions" => { pattern: /^@[a-zA-Z0-9_-]+$/, multi: true },
  "replying-to" => { pattern: /^@[a-zA-Z0-9_-]+$/, multi: true },

  # Type filters
  "type" => { values: %w[note decision commitment n d c], multi: true },
  "subtype" => { values: %w[comment], multi: true },
  "status" => { values: %w[open closed], multi: false },

  # Boolean filters
  "critical-mass-achieved" => { values: %w[true false], multi: false },

  # Integer filters (min/max)
  "min-links" => { pattern: /^\d+$/, multi: false },
  "max-links" => { pattern: /^\d+$/, multi: false },
  "min-backlinks" => { pattern: /^\d+$/, multi: false },
  "max-backlinks" => { pattern: /^\d+$/, multi: false },
  "min-comments" => { pattern: /^\d+$/, multi: false },
  "max-comments" => { pattern: /^\d+$/, multi: false },
  "min-readers" => { pattern: /^\d+$/, multi: false },
  "max-readers" => { pattern: /^\d+$/, multi: false },
  "min-voters" => { pattern: /^\d+$/, multi: false },
  "max-voters" => { pattern: /^\d+$/, multi: false },
  "min-participants" => { pattern: /^\d+$/, multi: false },
  "max-participants" => { pattern: /^\d+$/, multi: false },

  # Time filters
  "cycle" => { pattern: CYCLE_PATTERN, multi: false },
  "after" => { pattern: DATE_PATTERN, multi: false },
  "before" => { pattern: DATE_PATTERN, multi: false },

  # Display options
  "sort" => { values: %w[newest oldest updated deadline relevance backlinks new old], multi: false },
  "group" => { values: %w[type status date week month none], multi: false },
  "limit" => { pattern: /^\d+$/, multi: false },
}.freeze
```

## Migration Path

1. Add `reader_count` to search_index, update SearchIndexer
2. Update SearchQueryParser with new operators
3. Implement user-based filter joins in SearchQuery
4. Update views with new syntax help
5. Remove deprecated operators (`is:`, `has:`, `by:`, `in:`)

## Backwards Compatibility

The old operators will be removed. Users will need to update their bookmarked searches:

| Old | New |
|-----|-----|
| `by:@alice` | `creator:@alice` |
| `by:me` | `creator:@myhandle` |
| `is:mine` | `creator:@myhandle` |
| `is:open` | `status:open` |
| `is:closed` | `status:closed` |
| `is:pinned` | (removed - use pinned view instead) |
| `has:backlinks` | `min-backlinks:1` |
| `has:links` | `min-links:1` |
| `has:participants` | `min-participants:1` |
| `has:comments` | `min-comments:1` |
| `in:handle` | `studio:handle` or `scene:handle` |

## Design Decisions

1. **Explicit operator names** - No vague operators like `is:`, `has:`, `by:`, `in:`
2. **`@handle` required** - No `me` shorthand; always use explicit handle
3. **Separate `studio:` and `scene:`** - Type-specific scope operators
4. **Integer filters use min/max** - No exact match (e.g., `min-readers:5` not `readers:5`)
5. **`status:` for open/closed** - Clear semantic meaning
6. **User filters via `user_item_status`** - Efficient per-user-item tracking
7. **`reader_count` in search_index** - Denormalized for query performance
