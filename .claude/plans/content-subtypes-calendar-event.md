# Content Subtypes — Calendar Event

## Context

A "calendar_event" commitment is an event with a date/time and optional location. Members RSVP instead of "joining." The core calendar event functionality should follow familiar patterns from existing calendar apps (Google Calendar, Apple Calendar, etc.) — the commitment/RSVP layer is what's unique to Harmonic.

**Depends on:** [Foundation](content-subtypes-foundation.md)

## Design Principles

- `starts_at` is the primary time point for cycle membership and sorting (not `created_at`)
- Timezone handling follows the collective's timezone (already used for cycles)
- Familiar UI patterns: datetime picker, location field, attendee list, RSVP actions
- `deadline` repurposed as RSVP deadline (optional) — "RSVP by" date, distinct from event start time

## Database Migration

```ruby
add_column :commitments, :starts_at, :timestamp, null: true
add_column :commitments, :ends_at, :timestamp, null: true
add_column :commitments, :location, :text, null: true
```

All stored in UTC, displayed in the collective's timezone (consistent with how cycles and deadlines already work).

## Cycle Membership

Calendar events appear in the cycle that contains their `starts_at`, not their `created_at`. This requires a change to how the feed query works for commitments:

- The feed query in PulseController currently filters by `created_at >= cycle.start_date`
- For calendar_event commitments: filter by `starts_at >= cycle.start_date AND starts_at < cycle.end_date`
- For all other commitments: existing `created_at` logic unchanged
- This means an event created today for next week appears in next week's cycle, which matches user expectations

Implementation: extend `@cycle.resources(Commitment)` to handle the subtype branching, or use a UNION/OR in the query.

## Model Changes (`app/models/commitment.rb`)

### Validations
- `validates :starts_at, presence: true, if: -> { calendar_event? }`
- `validates :ends_at, presence: true, if: -> { calendar_event? }`
- Validate `ends_at > starts_at`

### Methods
- Override `metric_name` to "attendees"
- `duration` — returns `ends_at - starts_at`
- `all_day?` — true if starts at midnight and ends at midnight (conventional all-day event pattern)
- `upcoming?` — true if `starts_at` is in the future
- `in_progress?` — true if now is between `starts_at` and `ends_at`
- `past?` — true if `ends_at` is in the past
- `formatted_time_range` — human-readable time range respecting collective timezone (e.g., "Apr 28, 2:00 PM – 3:30 PM" or "Apr 28 – Apr 30" for multi-day)

### RSVP semantics
The existing `join_commitment!`/participant system maps directly to RSVP:
- "Join" → "RSVP Yes" (creates a participant record, same as today)
- Leave → "Cancel RSVP" (removes participant record)
- `deadline` → RSVP deadline (optional, can be null — no RSVP cutoff)
- `critical_mass` → minimum attendees needed (optional, can be null/0 for events without a minimum)
- `limit` → max attendees / capacity (existing field, works as-is)

No new RSVP-specific logic needed — the commitment participant system is already the right abstraction.

## Controller Changes

### CommitmentsController (`app/controllers/commitments_controller.rb`)
- Permit `starts_at`, `ends_at`, `location` params
- `new`: accept `?subtype=calendar_event`
- `show`: set up time display variables using collective timezone

## View Changes

### Creation form (`app/views/commitments/new.html.erb`)
- When "Calendar Event" selected:
  - Show `starts_at` datetime-local input
  - Show `ends_at` datetime-local input
  - Show `location` text field
  - Relabel `deadline` as "RSVP by" (optional)
  - Relabel `critical_mass` as "Minimum attendees" (optional)
  - Relabel `limit` as "Capacity" (optional)
- Stimulus controller to show/hide these fields based on subtype selection
- datetime-local inputs parsed in collective timezone (same pattern as existing deadline handling)

### Show page (`app/views/commitments/show.html.erb`)
- Display date/time range prominently at top (formatted_time_range)
- Display location if present
- Show event status: "Upcoming", "Happening now", "Past"
- "RSVP" button instead of "Join"
- Participant list labeled "Attendees"
- If RSVP deadline set, show "RSVP by [date]"
- Keep progress bar if critical_mass is set (shows attendees vs minimum)

### Feed (`app/components/feed_item_component.rb` + template)
- Type label: "Event"
- Show date/time inline (formatted_time_range)
- Show location if present
- "RSVP" button instead of "Join"
- Show attendee count

### ResourceHeaderComponent
- Type label: "Event"

## API Changes

- `api_json` includes `starts_at`, `ends_at`, `location` for calendar events
- `starts_at`/`ends_at` returned as ISO 8601 strings
- Accept timezone-aware input or UTC

## Testing

- Model: calendar_event requires starts_at/ends_at, validates ends_at > starts_at, duration/all_day?/upcoming?/in_progress?/past? methods, formatted_time_range
- Cycle membership: event appears in cycle containing starts_at, not created_at
- Controller: create calendar event with dates, show page renders time/location
- RSVP: joining/leaving works as usual, labels changed
- Feed: event renders with date/time, location, RSVP button

## Verification

```bash
docker compose exec web bundle exec rails test test/models/commitment_test.rb test/controllers/commitments_controller_test.rb
docker compose exec web bundle exec rubocop
```
Manual: create a calendar event for next week, verify it appears in next week's cycle (not this week's), RSVP, verify show page and feed rendering, test with/without location, test all-day events.
