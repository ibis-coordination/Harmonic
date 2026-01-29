# Search Feature Design

## Overview

A comprehensive search system that allows users to filter, sort, and group results across Notes, Decisions, and Commitments using query string parameters. Built on pre-computed infrastructure for performance and extensibility.

**Related:** For semantic search and AI features, see [SEMANTIC_SEARCH.md](SEMANTIC_SEARCH.md).

## Goals

1. **Query string driven** — All search state lives in the URL for shareability and bookmarking
2. **Composable filters** — Combine multiple filters with AND logic
3. **User-specific filters** — Support "unread by me", "voted by me", etc.
4. **Full-text search** — Search across titles, bodies, comments, and options
5. **Performance at scale** — Pre-computed indexes, cursor pagination, sub-100ms queries

---

## Infrastructure

### Table 1: `search_index`

A denormalized, pre-computed search table that consolidates all searchable content.

```sql
CREATE TABLE search_index (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),

  -- Identity
  tenant_id uuid NOT NULL REFERENCES tenants(id),
  superagent_id uuid NOT NULL REFERENCES superagents(id),
  item_type varchar NOT NULL,  -- 'Note', 'Decision', 'Commitment'
  item_id uuid NOT NULL,
  truncated_id varchar(8) NOT NULL,

  -- Searchable content
  title text NOT NULL,
  body text,
  searchable_text text NOT NULL,  -- Concatenated: title + body + comments + options
  searchable_tsvector tsvector GENERATED ALWAYS AS (
    to_tsvector('english', searchable_text)
  ) STORED,

  -- Metadata
  created_at timestamp NOT NULL,
  updated_at timestamp NOT NULL,
  deadline timestamp NOT NULL,
  created_by_id uuid REFERENCES users(id),
  updated_by_id uuid REFERENCES users(id),

  -- Pre-computed counts
  link_count integer DEFAULT 0,
  backlink_count integer DEFAULT 0,
  participant_count integer DEFAULT 0,
  voter_count integer DEFAULT 0,
  option_count integer DEFAULT 0,
  comment_count integer DEFAULT 0,

  -- Status flags
  is_open boolean GENERATED ALWAYS AS (deadline > NOW()) STORED,
  is_pinned boolean DEFAULT false,

  -- For cursor pagination
  sort_key bigint GENERATED ALWAYS AS IDENTITY,

  -- Constraints
  UNIQUE (tenant_id, item_type, item_id)
);

-- Indexes
CREATE INDEX idx_search_index_tenant_superagent
  ON search_index (tenant_id, superagent_id);
CREATE INDEX idx_search_index_fulltext
  ON search_index USING GIN (searchable_tsvector);
CREATE INDEX idx_search_index_created
  ON search_index (tenant_id, superagent_id, created_at DESC);
CREATE INDEX idx_search_index_deadline
  ON search_index (tenant_id, superagent_id, deadline);
CREATE INDEX idx_search_index_cursor
  ON search_index (tenant_id, superagent_id, sort_key);
CREATE INDEX idx_search_index_item
  ON search_index (item_type, item_id);
```

**Benefits:**
- Single table query instead of UNION view
- Pre-computed tsvector for fast full-text search
- Body content and comments included in search
- Cursor-friendly sort_key for efficient pagination
- Indexes on the actual data, not computed on the fly

### Table 2: `user_item_status`

Pre-computed user-item relationships for instant user-specific filtering.

```sql
CREATE TABLE user_item_status (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),

  -- Identity
  tenant_id uuid NOT NULL REFERENCES tenants(id),
  user_id uuid NOT NULL REFERENCES users(id),
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
  UNIQUE (tenant_id, user_id, item_type, item_id)
);

-- Indexes
CREATE INDEX idx_user_item_status_user
  ON user_item_status (tenant_id, user_id);
CREATE INDEX idx_user_item_status_unread
  ON user_item_status (tenant_id, user_id, item_type)
  WHERE has_read = false;
CREATE INDEX idx_user_item_status_not_voted
  ON user_item_status (tenant_id, user_id, item_type)
  WHERE has_voted = false;
```

**Benefits:**
- User-specific filters become simple WHERE clauses
- No subqueries needed
- Partial indexes for common filter patterns
- Can track additional engagement signals (views, mentions)

### Table 3: `search_queries` (Analytics)

Track search behavior for improvement.

```sql
CREATE TABLE search_queries (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),

  -- Context
  tenant_id uuid NOT NULL REFERENCES tenants(id),
  superagent_id uuid REFERENCES superagents(id),
  user_id uuid REFERENCES users(id),

  -- Query details
  query_text text,
  filters jsonb,
  sort_by varchar,
  group_by varchar,

  -- Results
  result_count integer,
  page integer DEFAULT 1,

  -- Engagement
  clicked_item_id uuid,
  clicked_at timestamp,

  -- Timing
  executed_at timestamp DEFAULT NOW(),
  duration_ms integer,

  -- Session
  session_id varchar
);

-- Indexes
CREATE INDEX idx_search_queries_tenant_time
  ON search_queries (tenant_id, executed_at DESC);
CREATE INDEX idx_search_queries_text
  ON search_queries USING GIN (to_tsvector('english', query_text));
```

**Benefits:**
- Identify common searches to optimize
- Detect failed searches (result_count = 0)
- Track click-through for relevance tuning
- Power "popular searches" or "trending" features

---

## Keeping Data Fresh

### Trigger-Based Updates for search_index

```sql
-- Function to update search_index when a note changes
CREATE OR REPLACE FUNCTION update_search_index_for_note()
RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO search_index (
    tenant_id, superagent_id, item_type, item_id, truncated_id,
    title, body, searchable_text,
    created_at, updated_at, deadline, created_by_id, updated_by_id,
    link_count, backlink_count, comment_count
  )
  SELECT
    NEW.tenant_id,
    NEW.superagent_id,
    'Note',
    NEW.id,
    NEW.truncated_id,
    NEW.title,
    NEW.body,
    COALESCE(NEW.title, '') || ' ' || COALESCE(NEW.body, '') || ' ' ||
      COALESCE((SELECT string_agg(c.body, ' ') FROM notes c WHERE c.parent_id = NEW.id), ''),
    NEW.created_at,
    NEW.updated_at,
    NEW.deadline,
    NEW.created_by_id,
    NEW.updated_by_id,
    (SELECT COUNT(*) FROM links WHERE from_linkable_id = NEW.id AND from_linkable_type = 'Note'),
    (SELECT COUNT(*) FROM links WHERE to_linkable_id = NEW.id AND to_linkable_type = 'Note'),
    (SELECT COUNT(*) FROM notes WHERE parent_id = NEW.id)
  ON CONFLICT (tenant_id, item_type, item_id)
  DO UPDATE SET
    title = EXCLUDED.title,
    body = EXCLUDED.body,
    searchable_text = EXCLUDED.searchable_text,
    updated_at = EXCLUDED.updated_at,
    deadline = EXCLUDED.deadline,
    updated_by_id = EXCLUDED.updated_by_id,
    link_count = EXCLUDED.link_count,
    backlink_count = EXCLUDED.backlink_count,
    comment_count = EXCLUDED.comment_count;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_note_search_index
  AFTER INSERT OR UPDATE ON notes
  FOR EACH ROW
  EXECUTE FUNCTION update_search_index_for_note();
```

### Trigger-Based Updates for user_item_status

```sql
-- Update user_item_status when a read is confirmed
CREATE OR REPLACE FUNCTION update_user_item_status_on_read()
RETURNS TRIGGER AS $$
BEGIN
  IF NEW.event_type = 'confirmed_read' THEN
    INSERT INTO user_item_status (
      tenant_id, user_id, item_type, item_id, has_read, read_at
    )
    VALUES (
      NEW.tenant_id, NEW.user_id, 'Note', NEW.note_id, true, NEW.created_at
    )
    ON CONFLICT (tenant_id, user_id, item_type, item_id)
    DO UPDATE SET
      has_read = true,
      read_at = COALESCE(user_item_status.read_at, EXCLUDED.read_at);
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_note_history_user_status
  AFTER INSERT ON note_history_events
  FOR EACH ROW
  EXECUTE FUNCTION update_user_item_status_on_read();

-- Update user_item_status when a vote is cast
CREATE OR REPLACE FUNCTION update_user_item_status_on_vote()
RETURNS TRIGGER AS $$
DECLARE
  v_user_id uuid;
  v_tenant_id uuid;
BEGIN
  SELECT dp.user_id, dp.tenant_id INTO v_user_id, v_tenant_id
  FROM decision_participants dp
  WHERE dp.id = NEW.decision_participant_id;

  IF v_user_id IS NOT NULL THEN
    INSERT INTO user_item_status (
      tenant_id, user_id, item_type, item_id, has_voted, voted_at
    )
    VALUES (
      v_tenant_id, v_user_id, 'Decision', NEW.decision_id, true, NEW.created_at
    )
    ON CONFLICT (tenant_id, user_id, item_type, item_id)
    DO UPDATE SET
      has_voted = true,
      voted_at = COALESCE(user_item_status.voted_at, EXCLUDED.voted_at);
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_vote_user_status
  AFTER INSERT ON votes
  FOR EACH ROW
  EXECUTE FUNCTION update_user_item_status_on_vote();

-- Update user_item_status when joining a commitment
CREATE OR REPLACE FUNCTION update_user_item_status_on_participate()
RETURNS TRIGGER AS $$
BEGIN
  IF NEW.user_id IS NOT NULL THEN
    INSERT INTO user_item_status (
      tenant_id, user_id, item_type, item_id, is_participating, participated_at
    )
    VALUES (
      NEW.tenant_id, NEW.user_id, 'Commitment', NEW.commitment_id, true, NEW.created_at
    )
    ON CONFLICT (tenant_id, user_id, item_type, item_id)
    DO UPDATE SET
      is_participating = true,
      participated_at = COALESCE(user_item_status.participated_at, EXCLUDED.participated_at);
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_commitment_participant_user_status
  AFTER INSERT ON commitment_participants
  FOR EACH ROW
  EXECUTE FUNCTION update_user_item_status_on_participate();
```

### Background Job for Bulk Reindexing

```ruby
# app/jobs/reindex_search_job.rb

class ReindexSearchJob < ApplicationJob
  queue_as :low_priority

  def perform(tenant_id: nil, item_type: nil, since: nil)
    scope = build_scope(tenant_id, item_type, since)

    scope.find_each(batch_size: 100) do |item|
      SearchIndexer.reindex(item)
    end
  end

  private

  def build_scope(tenant_id, item_type, since)
    # Build appropriate scope based on params
  end
end
```

---

## Query String Schema

```
/studios/:handle/search?q=...&type=...&cycle=...&filters=...&sort_by=...&group_by=...&cursor=...&per_page=...
```

### Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `q` | string | — | Full-text search query |
| `type` | string | `all` | Item types: `note`, `decision`, `commitment`, or comma-separated |
| `cycle` | string | `today` | Time window: `today`, `this-week`, `this-month`, `all`, etc. |
| `filters` | string | — | Comma-separated filter expressions |
| `sort_by` | string | `created_at-desc` | Sort field and direction |
| `group_by` | string | `item_type` | Grouping field, or `none` |
| `cursor` | string | — | Cursor for pagination (sort_key of last item) |
| `per_page` | integer | `25` | Results per page (max 100) |

---

## Text Search: `q`

Full-text search across title, body, comments, and option titles.

```
?q=budget
?q=quarterly review
?q=team coordination
```

### Implementation

Uses PostgreSQL `tsvector` with GIN index for fast, ranked results:

```ruby
def apply_text_search
  return unless query.present?

  @relation = @relation
    .where("searchable_tsvector @@ plainto_tsquery('english', ?)", query)

  if sort_field == "relevance"
    @relation = @relation
      .select("search_index.*, ts_rank(searchable_tsvector, plainto_tsquery('english', #{connection.quote(query)})) AS relevance_score")
      .order("relevance_score DESC")
  end
end
```

---

## Type Filter: `type`

Filter by item type. Multiple types use OR logic.

```
?type=note
?type=decision
?type=commitment
?type=note,decision
?type=all              # default, all types
```

---

## Time Window: `cycle`

Reuses existing `Cycle` model for date range calculation.

```
?cycle=today
?cycle=yesterday
?cycle=this-week
?cycle=last-month
?cycle=this-year
?cycle=2-weeks-ago
?cycle=all             # no time restriction
```

---

## Filters: `filters`

Comma-separated filter expressions. All filters combine with AND logic.

### Ownership Filters

| Filter | Description |
|--------|-------------|
| `mine` | Created by current user |
| `not_mine` | Created by others |
| `created_by:handle` | Created by specific user |

### Status Filters

| Filter | Description |
|--------|-------------|
| `open` | Deadline in future |
| `closed` | Deadline passed |

### Presence Filters

| Filter | Description |
|--------|-------------|
| `has_backlinks` | Has incoming links |
| `has_links` | Has outgoing links |
| `has_participants` | Has participants |
| `updated` | Has been edited |

### User-Specific Filters

| Filter | Applies To | Description |
|--------|------------|-------------|
| `unread` | Notes | Notes I haven't confirmed reading |
| `read` | Notes | Notes I have confirmed reading |
| `voted` | Decisions | Decisions I've voted on |
| `not_voted` | Decisions | Open decisions I haven't voted on |
| `participating` | Commitments | Commitments I've joined |
| `not_participating` | Commitments | Open commitments I haven't joined |

### Numeric Comparisons

| Syntax | Example | Description |
|--------|---------|-------------|
| `field>N` | `backlink_count>5` | Greater than |
| `field>=N` | `participant_count>=3` | Greater than or equal |
| `field<N` | `voter_count<10` | Less than |
| `field<=N` | `option_count<=5` | Less than or equal |
| `field=N` | `backlink_count=0` | Equal to |

**Valid numeric fields:** `backlink_count`, `link_count`, `participant_count`, `voter_count`, `option_count`, `comment_count`

### Date Filters

| Syntax | Example | Description |
|--------|---------|-------------|
| `field_after:DATE` | `created_after:2024-01-01` | After specific date |
| `field_before:DATE` | `deadline_before:2024-12-31` | Before specific date |
| `field_within:DURATION` | `updated_within:7d` | Within relative duration |

**Valid date fields:** `created`, `updated`, `deadline`

**Duration units:** `h` (hours), `d` (days), `w` (weeks), `m` (months)

---

## Sorting: `sort_by`

Format: `field-direction` where direction is `asc` or `desc`.

| Field | Description |
|-------|-------------|
| `created_at` | Creation timestamp |
| `updated_at` | Last update timestamp |
| `deadline` | Deadline timestamp |
| `title` | Alphabetical by title |
| `backlink_count` | Number of incoming links |
| `link_count` | Number of outgoing links |
| `participant_count` | Number of participants |
| `relevance` | Text search relevance (only when `q` present) |

```
?sort_by=created_at-desc      # newest first (default)
?sort_by=deadline-asc         # soonest deadline first
?sort_by=backlink_count-desc  # most linked first
?sort_by=relevance-desc       # best matches first (requires q)
```

---

## Grouping: `group_by`

Group results by a field. Use `none` for a flat list.

| Field | Description |
|-------|-------------|
| `none` | No grouping (flat list) |
| `item_type` | Note, Decision, Commitment |
| `status` | Open, Closed |
| `created_by` | Creator's handle |
| `date_created` | Date of creation |
| `week_created` | Week of creation |
| `month_created` | Month of creation |
| `date_deadline` | Deadline date |
| `week_deadline` | Deadline week |
| `month_deadline` | Deadline month |

---

## Pagination

Uses cursor-based pagination for efficiency at scale.

```
?per_page=25
?cursor=12345          # sort_key of last item from previous page
```

- `per_page`: Results per page, 1-100 (default: 25)
- `cursor`: The `sort_key` of the last item from the previous page

**Why cursor pagination?**
- OFFSET pagination requires scanning all previous rows
- For page 100 at 25/page, OFFSET scans 2,475 rows before returning results
- Cursor pagination uses indexed lookup: O(log n) instead of O(n)

---

## Example Queries

```bash
# Find my unread notes from last month
/studios/team/search?type=note&cycle=last-month&filters=unread

# Open decisions I haven't voted on
/studios/team/search?type=decision&filters=open,not_voted

# All items mentioning "budget" with backlinks
/studios/team/search?q=budget&cycle=all&filters=has_backlinks

# My items updated in the last week
/studios/team/search?filters=mine,updated_within:7d&sort_by=updated_at-desc

# Commitments with 5+ participants, closing soon
/studios/team/search?type=commitment&filters=open,participant_count>=5&sort_by=deadline-asc

# Items by alice, grouped by month
/studios/team/search?filters=created_by:alice&group_by=month_created&cycle=all

# High-engagement closed items
/studios/team/search?filters=closed,backlink_count>=10&sort_by=backlink_count-desc
```

---

## SearchQuery Service

```ruby
# app/services/search_query.rb
# typed: true

class SearchQuery
  extend T::Sig

  VALID_SORT_FIELDS = %w[
    created_at updated_at deadline title
    backlink_count link_count participant_count voter_count
  ].freeze

  VALID_NUMERIC_FIELDS = %w[
    backlink_count link_count participant_count voter_count option_count comment_count
  ].freeze

  VALID_DATE_FIELDS = %w[created updated deadline].freeze

  USER_FILTERS = %w[unread read voted not_voted participating not_participating].freeze

  sig do
    params(
      tenant: Tenant,
      superagent: Superagent,
      current_user: T.nilable(User),
      params: T::Hash[T.any(String, Symbol), T.untyped]
    ).void
  end
  def initialize(tenant:, superagent:, current_user:, params: {})
    @tenant = tenant
    @superagent = superagent
    @current_user = current_user
    @params = params.with_indifferent_access
  end

  sig { returns(ActiveRecord::Relation) }
  def results
    @results ||= build_query
  end

  sig { returns(ActiveRecord::Relation) }
  def paginated_results
    relation = results
    relation = relation.where("sort_key < ?", cursor) if cursor.present?
    relation.limit(per_page)
  end

  sig { returns(T::Array[T::Array[T.untyped]]) }
  def grouped_results
    rows = paginated_results.to_a
    return [[nil, rows]] if group_by.nil?

    grouped = {}
    rows.each do |row|
      key = row.public_send(group_by)
      grouped[key] ||= []
      grouped[key] << row
    end

    group_order.filter_map { |key| [key, grouped[key]] if grouped[key].present? }
  end

  sig { returns(Integer) }
  def total_count
    @total_count ||= results.count
  end

  sig { returns(T.nilable(String)) }
  def next_cursor
    last_item = paginated_results.last
    last_item&.sort_key&.to_s
  end

  # Accessors for view/controller
  sig { returns(T.nilable(String)) }
  def query
    @query ||= @params[:q].to_s.strip.presence
  end

  sig { returns(String) }
  def sort_by
    @sort_by ||= @params[:sort_by].presence || "created_at-desc"
  end

  sig { returns(T.nilable(String)) }
  def group_by
    return @group_by if defined?(@group_by)

    requested = @params[:group_by].to_s.strip
    return @group_by = "item_type" if requested.blank?
    return @group_by = nil if requested == "none"

    @group_by = valid_group_bys.include?(requested) ? requested : "item_type"
  end

  sig { returns(T.nilable(String)) }
  def cursor
    @params[:cursor].presence
  end

  sig { returns(Integer) }
  def per_page
    @per_page ||= @params[:per_page].to_i.clamp(1, 100).nonzero? || 25
  end

  sig { returns(T::Hash[Symbol, T.untyped]) }
  def to_params
    {
      q: query,
      type: @params[:type],
      cycle: cycle_name,
      filters: @params[:filters],
      sort_by: sort_by,
      group_by: @params[:group_by],
      cursor: cursor,
      per_page: per_page,
    }.compact_blank
  end

  # Options for UI dropdowns
  sig { returns(T::Array[T::Array[String]]) }
  def sort_by_options
    options = [
      ["Created (newest)", "created_at-desc"],
      ["Created (oldest)", "created_at-asc"],
      ["Updated (newest)", "updated_at-desc"],
      ["Updated (oldest)", "updated_at-asc"],
      ["Deadline (soonest)", "deadline-asc"],
      ["Deadline (latest)", "deadline-desc"],
      ["Most backlinks", "backlink_count-desc"],
      ["Most participants", "participant_count-desc"],
      ["Title (A-Z)", "title-asc"],
      ["Title (Z-A)", "title-desc"],
    ]
    options.unshift(["Relevance", "relevance-desc"]) if query.present?
    options
  end

  sig { returns(T::Array[T::Array[String]]) }
  def group_by_options
    [
      ["Item type", "item_type"],
      ["None (flat list)", "none"],
      ["Status", "status"],
      ["Creator", "created_by"],
      ["Date created", "date_created"],
      ["Week created", "week_created"],
      ["Month created", "month_created"],
      ["Date deadline", "date_deadline"],
      ["Week deadline", "week_deadline"],
      ["Month deadline", "month_deadline"],
    ]
  end

  sig { returns(T::Array[T::Array[String]]) }
  def type_options
    [
      ["All types", "all"],
      ["Notes", "note"],
      ["Decisions", "decision"],
      ["Commitments", "commitment"],
    ]
  end

  sig { returns(T::Array[T::Array[String]]) }
  def filter_presets
    [
      ["None", ""],
      ["My items", "mine"],
      ["Unread notes", "unread"],
      ["Open items", "open"],
      ["My open items", "mine,open"],
      ["Needs my vote", "not_voted"],
      ["Has backlinks", "has_backlinks"],
      ["Recently updated", "updated_within:7d"],
    ]
  end

  private

  sig { returns(ActiveRecord::Relation) }
  def build_query
    @relation = SearchIndex.where(tenant_id: @tenant.id, superagent_id: @superagent.id)

    apply_text_search
    apply_type_filter
    apply_time_window
    apply_basic_filters
    apply_user_filters
    apply_sorting
    @relation
  end

  # ... (filter implementation methods - see full service code)
end
```

---

## SearchIndex Model

```ruby
# app/models/search_index.rb
# typed: true

class SearchIndex < ApplicationRecord
  self.table_name = "search_index"

  belongs_to :tenant
  belongs_to :superagent
  belongs_to :created_by, class_name: "User", optional: true
  belongs_to :updated_by, class_name: "User", optional: true

  # Virtual attribute for relevance scoring
  attribute :relevance_score, :float

  sig { returns(String) }
  def path
    case item_type
    when "Note" then "/n/#{truncated_id}"
    when "Decision" then "/d/#{truncated_id}"
    when "Commitment" then "/c/#{truncated_id}"
    end
  end

  sig { returns(String) }
  def status
    is_open ? "open" : "closed"
  end

  # Grouping helpers
  def date_created = created_at.to_date.to_s
  def week_created = created_at.strftime("%Y-W%V")
  def month_created = created_at.strftime("%Y-%m")
  def date_deadline = deadline.to_date.to_s
  def week_deadline = deadline.strftime("%Y-W%V")
  def month_deadline = deadline.strftime("%Y-%m")

  sig { returns(T::Hash[Symbol, T.untyped]) }
  def api_json
    {
      item_type: item_type,
      item_id: item_id,
      truncated_id: truncated_id,
      title: title,
      path: path,
      created_at: created_at,
      updated_at: updated_at,
      deadline: deadline,
      is_open: is_open,
      backlink_count: backlink_count,
      participant_count: participant_count,
      comment_count: comment_count,
    }
  end
end
```

---

## SearchIndexer Service

```ruby
# app/services/search_indexer.rb
# typed: true

class SearchIndexer
  extend T::Sig

  sig { params(item: T.any(Note, Decision, Commitment)).void }
  def self.reindex(item)
    new(item).reindex
  end

  sig { params(item: T.any(Note, Decision, Commitment)).void }
  def initialize(item)
    @item = item
  end

  sig { void }
  def reindex
    SearchIndex.upsert(
      build_attributes,
      unique_by: [:tenant_id, :item_type, :item_id]
    )
  end

  sig { void }
  def delete
    SearchIndex.where(
      tenant_id: @item.tenant_id,
      item_type: @item.class.name,
      item_id: @item.id
    ).delete_all
  end

  private

  sig { returns(T::Hash[Symbol, T.untyped]) }
  def build_attributes
    {
      tenant_id: @item.tenant_id,
      superagent_id: @item.superagent_id,
      item_type: @item.class.name,
      item_id: @item.id,
      truncated_id: @item.truncated_id,
      title: title,
      body: body,
      searchable_text: searchable_text,
      created_at: @item.created_at,
      updated_at: @item.updated_at,
      deadline: @item.deadline,
      created_by_id: @item.created_by_id,
      updated_by_id: @item.updated_by_id,
      link_count: link_count,
      backlink_count: backlink_count,
      participant_count: participant_count,
      voter_count: voter_count,
      option_count: option_count,
      comment_count: comment_count,
      is_pinned: @item.respond_to?(:is_pinned) && @item.is_pinned,
    }
  end

  sig { returns(String) }
  def title
    case @item
    when Note then @item.title
    when Decision then @item.question
    when Commitment then @item.title
    end
  end

  sig { returns(T.nilable(String)) }
  def body
    case @item
    when Note then @item.body
    when Decision then @item.description
    when Commitment then @item.description
    end
  end

  sig { returns(String) }
  def searchable_text
    parts = [title, body]
    parts.concat(@item.comments.pluck(:body)) if @item.is_a?(Note)
    parts.concat(@item.options.pluck(:title)) if @item.is_a?(Decision)
    parts.compact.join(" ")
  end

  def link_count = Link.where(from_linkable: @item).count
  def backlink_count = Link.where(to_linkable: @item).count
  def participant_count
    case @item
    when Note then @item.readers.count
    when Decision, Commitment then @item.participants.count
    else 0
    end
  end
  def voter_count = @item.is_a?(Decision) ? @item.voters.count : 0
  def option_count = @item.is_a?(Decision) ? @item.options.count : 0
  def comment_count = @item.is_a?(Note) ? @item.comments.count : 0
end
```

---

## Controller Integration

### Route

```ruby
# config/routes.rb
scope "studios/:handle" do
  get "search", to: "studios#search", as: :studio_search
end
```

### Controller Action

```ruby
# app/controllers/studios_controller.rb

def search
  @search = SearchQuery.new(
    tenant: @current_tenant,
    superagent: @current_superagent,
    current_user: @current_user,
    params: search_params,
  )

  @results = @search.paginated_results
  @grouped_results = @search.grouped_results
  @total_count = @search.total_count
  @next_cursor = @search.next_cursor

  respond_to do |format|
    format.html
    format.md { render_markdown_search }
    format.json { render json: search_json }
  end
end

private

def search_params
  params.permit(:q, :type, :cycle, :filters, :sort_by, :group_by, :cursor, :per_page)
end

def search_json
  {
    query: @search.to_params,
    total_count: @total_count,
    next_cursor: @next_cursor,
    results: @results.map(&:api_json),
  }
end
```

---

## Implementation Phases

### Phase 0: Infrastructure Foundation
- [ ] Create `search_index` table with migration
- [ ] Create `user_item_status` table with migration
- [ ] Create `SearchIndex` model
- [ ] Create `SearchIndexer` service
- [ ] Write database triggers for automatic updates
- [ ] Create backfill job for existing data
- [ ] Run backfill and verify data integrity

### Phase 1: Core Search
- [ ] Create `SearchQuery` service
- [ ] Implement full-text search with tsvector
- [ ] Implement type filter
- [ ] Implement time window (reuse Cycle)
- [ ] Implement basic filters (ownership, status, presence)
- [ ] Implement sorting with relevance ranking
- [ ] Implement cursor-based pagination
- [ ] Add controller action and route
- [ ] Create basic HTML view

### Phase 2: User-Specific Filters
- [ ] Write triggers for Vote, CommitmentParticipant, NoteHistoryEvent
- [ ] Backfill user_item_status from existing data
- [ ] Implement `unread`/`read` filters
- [ ] Implement `voted`/`not_voted` filters
- [ ] Implement `participating`/`not_participating` filters
- [ ] Add filter presets to UI

### Phase 3: Search Analytics
- [ ] Create `search_queries` table
- [ ] Log search queries with timing
- [ ] Track result clicks
- [ ] Build analytics dashboard
- [ ] Identify optimization opportunities

### Phase 4: Grouping & Polish
- [ ] Implement all group_by options
- [ ] Add `group_by=none` for flat list
- [ ] Implement `created_by` grouping
- [ ] Polish UI with Stimulus controllers
- [ ] Add URL state management
- [ ] Search result highlighting

---

## Data Migration

```ruby
# db/migrate/xxx_create_search_infrastructure.rb

class CreateSearchInfrastructure < ActiveRecord::Migration[7.0]
  def change
    create_table :search_index, id: :uuid do |t|
      t.uuid :tenant_id, null: false
      t.uuid :superagent_id, null: false
      t.string :item_type, null: false
      t.uuid :item_id, null: false
      t.string :truncated_id, limit: 8, null: false

      t.text :title, null: false
      t.text :body
      t.text :searchable_text, null: false

      t.timestamp :created_at, null: false
      t.timestamp :updated_at, null: false
      t.timestamp :deadline, null: false
      t.uuid :created_by_id
      t.uuid :updated_by_id

      t.integer :link_count, default: 0
      t.integer :backlink_count, default: 0
      t.integer :participant_count, default: 0
      t.integer :voter_count, default: 0
      t.integer :option_count, default: 0
      t.integer :comment_count, default: 0

      t.boolean :is_pinned, default: false

      t.index [:tenant_id, :superagent_id]
      t.index [:tenant_id, :item_type, :item_id], unique: true, name: "idx_search_index_unique_item"
      t.index [:item_type, :item_id]
    end

    # Add generated columns and GIN index
    execute <<~SQL
      ALTER TABLE search_index
      ADD COLUMN searchable_tsvector tsvector
      GENERATED ALWAYS AS (to_tsvector('english', searchable_text)) STORED;

      ALTER TABLE search_index
      ADD COLUMN is_open boolean
      GENERATED ALWAYS AS (deadline > NOW()) STORED;

      ALTER TABLE search_index
      ADD COLUMN sort_key bigserial;

      CREATE INDEX idx_search_index_fulltext
      ON search_index USING GIN (searchable_tsvector);

      CREATE INDEX idx_search_index_created
      ON search_index (tenant_id, superagent_id, created_at DESC);

      CREATE INDEX idx_search_index_deadline
      ON search_index (tenant_id, superagent_id, deadline);

      CREATE INDEX idx_search_index_cursor
      ON search_index (tenant_id, superagent_id, sort_key DESC);
    SQL

    create_table :user_item_status, id: :uuid do |t|
      t.uuid :tenant_id, null: false
      t.uuid :user_id, null: false
      t.string :item_type, null: false
      t.uuid :item_id, null: false

      t.boolean :has_read, default: false
      t.timestamp :read_at
      t.boolean :has_voted, default: false
      t.timestamp :voted_at
      t.boolean :is_participating, default: false
      t.timestamp :participated_at
      t.boolean :is_creator, default: false
      t.timestamp :last_viewed_at
      t.boolean :is_mentioned, default: false

      t.index [:tenant_id, :user_id]
      t.index [:tenant_id, :user_id, :item_type, :item_id], unique: true, name: "idx_user_item_status_unique"
    end

    # Partial indexes for common filter patterns
    execute <<~SQL
      CREATE INDEX idx_user_item_status_unread
      ON user_item_status (tenant_id, user_id, item_type)
      WHERE has_read = false;

      CREATE INDEX idx_user_item_status_not_voted
      ON user_item_status (tenant_id, user_id, item_type)
      WHERE has_voted = false;

      CREATE INDEX idx_user_item_status_not_participating
      ON user_item_status (tenant_id, user_id, item_type)
      WHERE is_participating = false;
    SQL

    create_table :search_queries, id: :uuid do |t|
      t.uuid :tenant_id, null: false
      t.uuid :superagent_id
      t.uuid :user_id

      t.text :query_text
      t.jsonb :filters
      t.string :sort_by
      t.string :group_by

      t.integer :result_count
      t.string :cursor

      t.uuid :clicked_item_id
      t.timestamp :clicked_at

      t.timestamp :executed_at, default: -> { "NOW()" }
      t.integer :duration_ms

      t.string :session_id

      t.index [:tenant_id, :executed_at]
    end
  end
end
```

---

## Backfill Job

```ruby
# app/jobs/backfill_search_index_job.rb

class BackfillSearchIndexJob < ApplicationJob
  queue_as :low_priority

  def perform
    Rails.logger.info "Starting search index backfill..."

    backfill_notes
    backfill_decisions
    backfill_commitments
    backfill_user_status

    Rails.logger.info "Search index backfill complete."
  end

  private

  def backfill_notes
    Note.find_each(batch_size: 100) { |note| SearchIndexer.reindex(note) }
  end

  def backfill_decisions
    Decision.find_each(batch_size: 100) { |decision| SearchIndexer.reindex(decision) }
  end

  def backfill_commitments
    Commitment.find_each(batch_size: 100) { |commitment| SearchIndexer.reindex(commitment) }
  end

  def backfill_user_status
    # Backfill reads
    NoteHistoryEvent.where(event_type: "confirmed_read").find_each(batch_size: 100) do |event|
      UserItemStatus.upsert(
        { tenant_id: event.tenant_id, user_id: event.user_id, item_type: "Note",
          item_id: event.note_id, has_read: true, read_at: event.created_at },
        unique_by: [:tenant_id, :user_id, :item_type, :item_id]
      )
    end

    # Backfill votes
    Vote.joins(:decision_participant).find_each(batch_size: 100) do |vote|
      participant = vote.decision_participant
      next unless participant.user_id

      UserItemStatus.upsert(
        { tenant_id: participant.tenant_id, user_id: participant.user_id, item_type: "Decision",
          item_id: vote.decision_id, has_voted: true, voted_at: vote.created_at },
        unique_by: [:tenant_id, :user_id, :item_type, :item_id]
      )
    end

    # Backfill participations
    CommitmentParticipant.where.not(user_id: nil).find_each(batch_size: 100) do |participant|
      UserItemStatus.upsert(
        { tenant_id: participant.tenant_id, user_id: participant.user_id, item_type: "Commitment",
          item_id: participant.commitment_id, is_participating: true, participated_at: participant.created_at },
        unique_by: [:tenant_id, :user_id, :item_type, :item_id]
      )
    end
  end
end
```

---

## Success Metrics

| Metric | Target | How to Measure |
|--------|--------|----------------|
| Search latency (p50) | < 50ms | `search_queries.duration_ms` |
| Search latency (p99) | < 200ms | `search_queries.duration_ms` |
| Zero-result rate | < 5% | `search_queries WHERE result_count = 0` |
| Click-through rate | > 30% | `search_queries WHERE clicked_item_id IS NOT NULL` |
| Index freshness | < 1 second | Trigger-based, monitor via logs |
| User filter queries | < 100ms | Benchmark with 10k items, 100 users |

---

## Security Considerations

1. **SQL Injection**: All user input parameterized via ActiveRecord
2. **Filter validation**: Only whitelisted fields accepted for numeric/date filters
3. **Handle lookup**: Uses tenant-scoped TenantUser to prevent cross-tenant access
4. **Pagination limits**: `per_page` clamped to 1-100 to prevent DoS
5. **Cycle validation**: Invalid cycle names fall back to "today"
6. **User ID in JOIN**: Sanitized via ActiveRecord quoting

---

## Testing Strategy

### Unit Tests

```ruby
# test/services/search_query_test.rb

class SearchQueryTest < ActiveSupport::TestCase
  setup do
    @tenant, @superagent, @user = create_tenant_studio_user
    @note = create_note(tenant: @tenant, superagent: @superagent, created_by: @user)
    SearchIndexer.reindex(@note)
  end

  test "full-text search finds matching content" do
    @note.update!(title: "Budget proposal for Q4")
    SearchIndexer.reindex(@note)

    search = SearchQuery.new(
      tenant: @tenant, superagent: @superagent, current_user: @user,
      params: { q: "budget" }
    )

    assert_includes search.results.map(&:item_id), @note.id
  end

  test "type filter restricts to specified types" do
    decision = create_decision(tenant: @tenant, superagent: @superagent)
    SearchIndexer.reindex(decision)

    search = SearchQuery.new(
      tenant: @tenant, superagent: @superagent, current_user: @user,
      params: { type: "note", cycle: "all" }
    )

    assert search.results.all? { |r| r.item_type == "Note" }
  end

  test "unread filter returns notes user hasn't read" do
    read_note = create_note(tenant: @tenant, superagent: @superagent)
    SearchIndexer.reindex(read_note)
    # Trigger confirmed_read event...

    search = SearchQuery.new(
      tenant: @tenant, superagent: @superagent, current_user: @user,
      params: { filters: "unread", cycle: "all" }
    )

    assert_includes search.results.map(&:item_id), @note.id
    refute_includes search.results.map(&:item_id), read_note.id
  end

  test "cursor pagination returns next page without overlap" do
    10.times { |i| SearchIndexer.reindex(create_note(tenant: @tenant, superagent: @superagent, title: "Note #{i}")) }

    search1 = SearchQuery.new(
      tenant: @tenant, superagent: @superagent, current_user: @user,
      params: { per_page: 5, cycle: "all" }
    )

    search2 = SearchQuery.new(
      tenant: @tenant, superagent: @superagent, current_user: @user,
      params: { per_page: 5, cursor: search1.next_cursor, cycle: "all" }
    )

    page1_ids = search1.paginated_results.map(&:item_id)
    page2_ids = search2.paginated_results.map(&:item_id)
    assert_empty(page1_ids & page2_ids)
  end
end
```
