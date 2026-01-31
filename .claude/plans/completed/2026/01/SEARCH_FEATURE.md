# Search Feature Design

## Overview

A comprehensive search system that allows users to filter, sort, and group results across Notes, Decisions, and Commitments. Built on pre-computed infrastructure for performance and extensibility.

**Related documents:**
- [SEARCH_DSL.md](SEARCH_DSL.md) - Search query language syntax and operators
- [SEMANTIC_SEARCH.md](SEMANTIC_SEARCH.md) - Future semantic/AI search features

## Goals

1. **Single search input** — One text field using a DSL for all filtering
2. **Composable filters** — Combine multiple filters with AND logic
3. **User-specific filters** — Support "unread by me", "voted by me", etc.
4. **Trigram text search** — Find partial matches across titles, bodies, comments, and options
5. **Performance at scale** — Pre-computed indexes, cursor pagination, partitioned tables

---

## Architecture

### Database Tables

Two pre-computed tables power the search:

| Table | Purpose | Partitioned |
|-------|---------|-------------|
| `search_index` | Denormalized searchable content | Yes (16 hash partitions by tenant_id) |
| `user_item_status` | Per-user engagement tracking | Yes (16 hash partitions by tenant_id) |

### Key Components

| Component | Location | Purpose |
|-----------|----------|---------|
| `SearchIndex` | `app/models/search_index.rb` | Model for search index records |
| `UserItemStatus` | `app/models/user_item_status.rb` | Model for user engagement tracking |
| `SearchQuery` | `app/services/search_query.rb` | Query builder and executor |
| `SearchQueryParser` | `app/services/search_query_parser.rb` | DSL parser |
| `SearchIndexer` | `app/services/search_indexer.rb` | Index record builder |
| `Searchable` | `app/models/concerns/searchable.rb` | Auto-reindex concern for models |
| `TracksUserItemStatus` | `app/models/concerns/tracks_user_item_status.rb` | Auto-track user engagement |
| `InvalidatesSearchIndex` | `app/models/concerns/invalidates_search_index.rb` | Reindex related items on change |

---

## Table 1: `search_index`

Pre-computed, denormalized search table partitioned by tenant_id.

### Schema

```sql
CREATE TABLE search_index (
  id uuid NOT NULL,
  tenant_id uuid NOT NULL,
  superagent_id uuid NOT NULL,
  item_type varchar NOT NULL,  -- 'Note', 'Decision', 'Commitment'
  item_id uuid NOT NULL,
  truncated_id varchar(8) NOT NULL,

  -- Searchable content
  title text NOT NULL,
  body text,
  searchable_text text NOT NULL,  -- Concatenated: title + body + comments + options

  -- Timestamps
  created_at timestamp NOT NULL,
  updated_at timestamp NOT NULL,
  deadline timestamp NOT NULL,
  created_by_id uuid,
  updated_by_id uuid,

  -- Pre-computed counts
  link_count integer DEFAULT 0,
  backlink_count integer DEFAULT 0,
  participant_count integer DEFAULT 0,
  voter_count integer DEFAULT 0,
  option_count integer DEFAULT 0,
  comment_count integer DEFAULT 0,
  reader_count integer DEFAULT 0,

  -- Status flags
  is_pinned boolean DEFAULT false,

  -- Pagination
  sort_key bigserial,

  -- Constraints
  PRIMARY KEY (tenant_id, id),
  UNIQUE (tenant_id, item_type, item_id)
) PARTITION BY HASH (tenant_id);
```

### Indexes

- `idx_search_index_trigram` - GIN index for pg_trgm similarity search
- `idx_search_index_tenant_superagent` - Scoping queries
- `idx_search_index_created` - Sorting by created_at
- `idx_search_index_deadline` - Sorting by deadline
- `idx_search_index_cursor` - Cursor-based pagination

### Text Search

Uses **pg_trgm trigram matching** instead of tsvector:

```ruby
# word_similarity() finds the search term as a complete word within longer text
@relation
  .where("word_similarity(?, searchable_text) >= ?", query, 0.3)
  .select("search_index.*, word_similarity(#{quoted_query}, searchable_text) AS relevance_score")
```

**Why pg_trgm over tsvector?**
- PostgreSQL tsvector uses the 'english' dictionary which filters stop words
- Queries like "more" or "the" return empty results with tsvector
- pg_trgm uses 3-character sequences that match any text
- `word_similarity()` finds complete word matches within longer text

---

## Table 2: `user_item_status`

Pre-computed user-item relationships partitioned by tenant_id for instant user-specific filtering.

### Schema

```sql
CREATE TABLE user_item_status (
  id uuid NOT NULL,
  tenant_id uuid NOT NULL,
  user_id uuid NOT NULL,
  item_type varchar NOT NULL,
  item_id uuid NOT NULL,

  -- Status flags
  has_read boolean DEFAULT false,
  read_at timestamp,
  has_voted boolean DEFAULT false,
  voted_at timestamp,
  is_participating boolean DEFAULT false,
  participated_at timestamp,
  is_creator boolean DEFAULT false,
  last_viewed_at timestamp,
  is_mentioned boolean DEFAULT false,  -- For future @mentions

  -- Constraints
  PRIMARY KEY (tenant_id, id),
  UNIQUE (tenant_id, user_id, item_type, item_id)
) PARTITION BY HASH (tenant_id);
```

### Partial Indexes

```sql
-- Fast lookup for unread items
CREATE INDEX idx_user_item_status_unread
ON user_item_status (tenant_id, user_id, item_type)
WHERE has_read = false;

-- Fast lookup for items not voted on
CREATE INDEX idx_user_item_status_not_voted
ON user_item_status (tenant_id, user_id, item_type)
WHERE has_voted = false;

-- Fast lookup for items not participating in
CREATE INDEX idx_user_item_status_not_participating
ON user_item_status (tenant_id, user_id, item_type)
WHERE is_participating = false;
```

---

## Keeping Data Fresh

### Real-Time Updates via Callbacks

Instead of database triggers, the system uses ActiveRecord callbacks through concerns:

#### 1. `Searchable` Concern

Models that should be searchable include this concern:

```ruby
# app/models/note.rb
class Note < ApplicationRecord
  include Searchable
  # ...
end
```

The concern triggers background reindexing:

```ruby
module Searchable
  extend ActiveSupport::Concern

  included do
    after_commit :enqueue_search_reindex, on: [:create, :update]
    after_commit :delete_from_search_index, on: :destroy
  end

  private

  def enqueue_search_reindex
    ReindexSearchJob.perform_later(item_type: self.class.name, item_id: id)
  end

  def delete_from_search_index
    SearchIndexer.delete(self)
  end
end
```

#### 2. `TracksUserItemStatus` Concern

Models that track user engagement include this concern:

```ruby
# app/models/note_history_event.rb
class NoteHistoryEvent < ApplicationRecord
  include TracksUserItemStatus

  private

  def user_item_status_updates
    return [] unless event_type == "read_confirmation"
    return [] if user_id.blank?

    [{
      tenant_id: tenant_id,
      user_id: user_id,
      item_type: "Note",
      item_id: note_id,
      has_read: true,
      read_at: happened_at,
    }]
  end
end
```

#### 3. `InvalidatesSearchIndex` Concern

Models that affect parent item counts include this concern:

```ruby
# app/models/vote.rb
class Vote < ApplicationRecord
  include InvalidatesSearchIndex

  private

  def search_index_items
    [decision].compact  # Reindex parent when vote is added
  end
end
```

### Models Using These Concerns

| Model | Searchable | TracksUserItemStatus | InvalidatesSearchIndex |
|-------|------------|---------------------|----------------------|
| Note | ✓ | ✓ (creator tracking) | ✓ (comment reindex) |
| Decision | ✓ | ✓ (creator tracking) | — |
| Commitment | ✓ | ✓ (creator tracking) | — |
| Vote | — | ✓ (vote tracking) | ✓ |
| CommitmentParticipant | — | ✓ (participation tracking) | ✓ |
| NoteHistoryEvent | — | ✓ (read tracking) | ✓ |

### Backfill Job

For initial data population or repair:

```ruby
# Run for all tenants
BackfillSearchIndexJob.perform_now

# Run for a specific tenant
BackfillSearchIndexJob.perform_now(tenant_id: "uuid")
```

---

## Query DSL

The search uses a single text input that parses a DSL. Full documentation is in [SEARCH_DSL.md](SEARCH_DSL.md).

### Quick Reference

```
# Basic search
budget proposal

# Type filter
type:note

# User filters
creator:@alice
-read-by:@myhandle    # Items I haven't read
-voter:@myhandle      # Decisions I haven't voted on

# Status
status:open
status:closed

# Count filters
min-backlinks:1
max-participants:10

# Time filters
cycle:this-week
after:-7d
before:+2w

# Display options
sort:newest
group:type
limit:25

# Location scope
studio:team-alpha
scene:planning
```

### Full Example

```
studio:team-alpha type:decision status:open -voter:@myhandle sort:deadline
```

This finds: Open decisions in the team-alpha studio that I haven't voted on yet, sorted by deadline.

---

## SearchQuery Service

The main query executor that builds and runs searches.

### Constructor

```ruby
SearchQuery.new(
  tenant: @current_tenant,
  current_user: @current_user,
  raw_query: "type:note min-backlinks:1",  # DSL string
  params: {}  # Legacy parameter hash (deprecated)
)
```

### Key Methods

| Method | Returns | Description |
|--------|---------|-------------|
| `results` | `ActiveRecord::Relation` | Full query (before pagination) |
| `paginated_results` | `ActiveRecord::Relation` | With cursor pagination applied |
| `grouped_results` | `Array[[key, items]]` | Results grouped by group_by field |
| `total_count` | `Integer` | Total matching items |
| `next_cursor` | `String?` | Cursor for next page |
| `query` | `String?` | Parsed search text |
| `superagent` | `Superagent?` | Resolved from studio:/scene: |

### Access Control

Searches automatically filter to accessible superagents:
- All scenes (public) in the tenant
- Studios the current user is a member of

---

## Controller & Routes

### Route

```ruby
# config/routes.rb
get "search" => "search#show"
```

### Controller

```ruby
# app/controllers/search_controller.rb
class SearchController < ApplicationController
  def show
    @search = SearchQuery.new(
      tenant: @current_tenant,
      current_user: @current_user,
      raw_query: params[:q],
    )

    @results = @search.paginated_results
    @grouped_results = @search.grouped_results
    @total_count = @search.total_count
    @next_cursor = @search.next_cursor

    respond_to do |format|
      format.html
      format.md
      format.json { render json: search_json }
    end
  end
end
```

---

## Implementation Status

### ✅ Completed

- [x] `search_index` table with partitioning (16 hash partitions)
- [x] `user_item_status` table with partitioning (16 hash partitions)
- [x] `SearchIndex` model
- [x] `UserItemStatus` model
- [x] `SearchIndexer` service
- [x] `SearchQuery` service with all filters
- [x] `SearchQueryParser` DSL parser
- [x] `Searchable` concern for auto-reindexing
- [x] `TracksUserItemStatus` concern for engagement tracking
- [x] `InvalidatesSearchIndex` concern for count updates
- [x] `BackfillSearchIndexJob` for initial population
- [x] `ReindexSearchJob` for background reindexing
- [x] pg_trgm trigram search (replaced tsvector)
- [x] `reader_count` column for Notes
- [x] HTML and Markdown views
- [x] Cursor-based pagination
- [x] All DSL operators implemented

### 🚫 Not Implemented (by design)

- [ ] `search_queries` analytics table (dropped - not needed for MVP)
- [ ] `is:pinned` filter (pinning is user-specific, not stored in search_index)
- [ ] `replying-to:@handle` filter (comments not indexed directly)

### 🔮 Future Enhancements

- [ ] `mentions:@handle` filter (requires @mention parsing)
- [ ] Semantic search (see [SEMANTIC_SEARCH.md](SEMANTIC_SEARCH.md))
- [ ] Search analytics for query optimization
- [ ] Autocomplete suggestions

---

## Performance Characteristics

### Partition Pruning

Both tables are hash-partitioned by tenant_id across 16 partitions. All queries include tenant_id, enabling PostgreSQL to prune to a single partition.

### Query Performance

| Operation | Target | Strategy |
|-----------|--------|----------|
| Text search | < 100ms | pg_trgm GIN index |
| User filters | < 50ms | Indexed join to user_item_status |
| Pagination | O(log n) | Cursor-based using sort_key index |
| Count queries | < 100ms | Partition pruning |

### Index Freshness

- Create/update: Background job via Sidekiq (< 5 second delay)
- Delete: Synchronous (immediate)
- User status: Synchronous via after_commit (immediate)

---

## Security Considerations

1. **SQL Injection**: All user input parameterized via ActiveRecord
2. **Operator validation**: Only whitelisted operators accepted by parser
3. **Handle lookup**: Uses tenant-scoped TenantUser to prevent cross-tenant access
4. **Pagination limits**: `per_page` clamped to 1-100 to prevent DoS
5. **Superagent access**: Queries filtered to accessible superagents only
6. **User ID in JOIN**: Sanitized via ActiveRecord quoting
