# Recent Cycles Sidebar Summary

## Context

The homepage (pulse page) currently only shows the current cycle's feed. Past cycles are navigable one-at-a-time via sidebar arrows, but there's no overview showing which past cycles had activity. If the current cycle is empty, the collective looks dead — even if last week was busy.

**Goal:** Add a compact "recent cycles" section to the homepage sidebar that shows which recent cycles had content, using the existing `cycle_data` database view and `CycleDataRow` model. No new tables needed.

## Approach

Add a new sidebar partial between the cycle nav and heartbeats sections that lists recent cycles with their item counts. Uses a single grouped SQL query against the existing `cycle_data` view.

## Changes

### 1. Query: `Cycle.recent_summaries` class method

**File:** `app/models/cycle.rb`

Add a class method that queries `CycleDataRow` grouped by time bucket:

```ruby
def self.recent_summaries(collective:, tenant:, limit: 6)
  unit = collective.tempo_unit  # "day", "week", "month"
  tz = collective.timezone.name
  
  CycleDataRow
    .where(tenant_id: tenant.id, collective_id: collective.id)
    .where("created_at >= ?", limit.send(unit.pluralize).ago)
    .group("date_trunc('#{unit}', created_at AT TIME ZONE '#{tz}')")
    .select(
      "date_trunc('#{unit}', created_at AT TIME ZONE '#{tz}') AS cycle_start",
      "count(*) AS total_count",
      "count(*) FILTER (WHERE item_type = 'Note') AS notes_count",
      "count(*) FILTER (WHERE item_type = 'Decision') AS decisions_count",
      "count(*) FILTER (WHERE item_type = 'Commitment') AS commitments_count",
    )
    .order("cycle_start DESC")
end
```

This returns one row per cycle period with counts. Only cycles with content appear (implicit from the view — no rows = no group). The `AT TIME ZONE` clause ensures buckets align with the collective's timezone, matching how `Cycle#start_date` works.

Note: sanitize the timezone and unit values to prevent SQL injection since they come from model data, not user input, but still worth being safe.

### 2. Controller: load data in `PulseController#show`

**File:** `app/controllers/pulse_controller.rb`

Add after the existing content loading (around line 45):

```ruby
@recent_cycle_summaries = Cycle.recent_summaries(
  collective: @current_collective,
  tenant: current_tenant,
)
```

### 3. View: new sidebar partial

**File:** `app/views/pulse/_sidebar_recent_cycles.html.erb` (new)

A compact list of recent cycles with counts, linking to the pulse page with `?cycle=` param. Each row shows the cycle label and total count. Visually follows the pattern of `_sidebar_nav.html.erb` (section label + list of items with counts).

Rough structure:
```erb
<div class="pulse-recent-cycles-section">
  <div class="pulse-section-label">Recent Cycles</div>
  <ul class="pulse-recent-cycles-list">
    <% @recent_cycle_summaries.each do |summary| %>
      <li>
        <a href="<%= @current_collective.path %>?cycle=<%= cycle_name_for(summary.cycle_start) %>"
           class="pulse-recent-cycle-item">
          <span><%= cycle_label_for(summary.cycle_start) %></span>
          <span class="pulse-nav-count"><%= summary.total_count %></span>
        </a>
      </li>
    <% end %>
  </ul>
</div>
```

Needs helper methods to convert the `cycle_start` timestamp back to a cycle name (e.g., "this-week", "last-week", "2-weeks-ago") and a display label (e.g., "This Week", "Last Week", "Apr 13 - Apr 19"). These can live on the `Cycle` class or as view helpers.

### 4. Wire into sidebar

**File:** `app/views/pulse/_sidebar.html.erb`

Insert after `_sidebar_cycle` (line 4), before the heartbeats conditional:

```erb
<%= render 'pulse/sidebar_recent_cycles' %>
```

### 5. CSS

**File:** `app/assets/stylesheets/pulse/_sidebar.css`

Follow the existing patterns (`.pulse-pinned-section`, `.pulse-links-section`). Key styles:
- Section: 16px padding, border-bottom
- List items: flex row, 13px font, muted count on right
- Hover: accent color
- Current cycle row: subtle highlight or bold

### 6. Helper: cycle name/label from timestamp

**File:** `app/models/cycle.rb` (or a helper)

Given a `cycle_start` timestamp and the collective's tempo_unit, compute:
- **cycle name** for URL: compare to current cycle's start_date to determine offset, then generate name like "this-week", "last-week", "2-weeks-ago"
- **display label**: use the same `display_window` logic already in `Cycle` — could instantiate a Cycle object from the offset and call `display_name` / `display_window`

## Files to modify

| File | Change |
|------|--------|
| `app/models/cycle.rb` | Add `Cycle.recent_summaries` class method + offset-to-name helper |
| `app/controllers/pulse_controller.rb` | Load `@recent_cycle_summaries` in `show` |
| `app/views/pulse/_sidebar_recent_cycles.html.erb` | New partial |
| `app/views/pulse/_sidebar.html.erb` | Render new partial |
| `app/assets/stylesheets/pulse/_sidebar.css` | Styles for new section |

## Existing code to reuse

- `CycleDataRow` model (`app/models/cycle_data_row.rb`) — the `cycle_data` view
- `Collective#tempo_unit` (`app/models/collective.rb:247`) — maps tempo to unit string
- `Collective#timezone` — for timezone-aware date bucketing
- `Cycle#display_name`, `Cycle#display_window` — for formatting labels
- `Cycle#offset`, `Cycle#previous_cycle` — for computing cycle names from offsets
- Sidebar CSS patterns from `_sidebar.css` (`.pulse-section-label`, `.pulse-links-list`)

## Verification

1. Write tests for `Cycle.recent_summaries` in `test/models/cycle_test.rb` — create notes/decisions in different time windows, verify counts
2. Run: `docker compose exec web bundle exec rails test test/models/cycle_test.rb`
3. Start the app, visit a collective homepage, confirm the recent cycles section appears with accurate counts
4. Click a past cycle link, verify it navigates to `?cycle=<name>` and shows the right content
5. Test with an empty collective — section should be empty or hidden
6. Run rubocop + sorbet: `docker compose exec web bundle exec rubocop` / `docker compose exec web bundle exec srb tc`
