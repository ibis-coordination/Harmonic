# Isolated Studio Pulse Page Implementation Plan

## Goal
Create a new "Studio Pulse" page that implements the mockup design (found at `mockups/01-studio-pulse.html`) at an isolated route, without modifying any existing views, controllers, or CSS.

## Approach: New Controller with Isolated Views & CSS

Create a dedicated `PulseController` with its own layout, views, and stylesheet. This provides complete isolation while reusing existing data-loading patterns via inheritance from `ApplicationController`.

---

## Files to Create

```
app/
  controllers/
    pulse_controller.rb                    # New controller
  views/
    layouts/
      pulse.html.erb                       # Custom two-column layout
    pulse/
      show.html.erb                        # Main pulse page view
      _sidebar.html.erb                    # Sidebar partial
      _sidebar_studio_info.html.erb        # Studio info section
      _sidebar_cycle.html.erb              # Cycle indicator section
      _sidebar_heartbeats.html.erb         # Heartbeat status section
      _sidebar_nav.html.erb                # Navigation section
      _feed.html.erb                       # Main activity feed
      _feed_item.html.erb                  # Single feed item card
      _feed_item_note.html.erb             # Note-specific content
      _feed_item_decision.html.erb         # Decision-specific content
      _feed_item_commitment.html.erb       # Commitment-specific content
  assets/
    stylesheets/
      studio_pulse.css                     # Isolated stylesheet (~300 lines)
```

## Files to Modify (Minimal)

| File | Change |
|------|--------|
| `config/routes.rb` | Add 1 route inside existing loop (~2 lines) |

---

## Route Definition

Add inside the `['studios','scenes'].each` loop (around line 191):

```ruby
get "#{studios_or_scenes}/:superagent_handle/pulse" => 'pulse#show'
```

This creates: `/studios/:superagent_handle/pulse`

---

## Controller: `app/controllers/pulse_controller.rb`

```ruby
class PulseController < ApplicationController
  layout 'pulse'

  def show
    return render 'shared/404' unless @current_superagent.superagent_type == 'studio'

    @page_title = "Pulse | #{@current_superagent.name}"

    # Cycle data
    @cycle = current_cycle

    # Content scoped to current cycle
    @unread_notes = @cycle.unread_notes(@current_user)
    @read_notes = @cycle.read_notes(@current_user)
    @open_decisions = @cycle.open_decisions
    @closed_decisions = @cycle.closed_decisions
    @open_commitments = @cycle.open_commitments
    @closed_commitments = @cycle.closed_commitments

    # Studio data
    @team = @current_superagent.team
    @heartbeats = Heartbeat.where_in_cycle(@cycle) - [current_heartbeat]
    @pinned_items = @current_superagent.pinned_items

    # Build unified feed (sorted by created_at desc)
    build_unified_feed
  end

  private

  def build_unified_feed
    all_items = []

    @cycle.notes.includes(:created_by).each do |note|
      all_items << { type: 'Note', item: note, created_at: note.created_at, created_by: note.created_by }
    end

    @cycle.decisions.includes(:created_by).each do |decision|
      all_items << { type: 'Decision', item: decision, created_at: decision.created_at, created_by: decision.created_by }
    end

    @cycle.commitments.includes(:created_by).each do |commitment|
      all_items << { type: 'Commitment', item: commitment, created_at: commitment.created_at, created_by: commitment.created_by }
    end

    @feed_items = all_items.sort_by { |item| -item[:created_at].to_i }
  end
end
```

---

## Layout: `app/views/layouts/pulse.html.erb`

Custom two-column layout that:
- Loads the isolated `studio_pulse.css` via `asset_path`
- Uses flexbox container with sidebar + main content
- Includes standard meta tags, CSRF, and JS from existing layout

---

## View Structure

### `pulse/show.html.erb`
- Renders sidebar via `content_for :sidebar`
- Page header with "Activity" title + "+ New" button
- Feed loop rendering `_feed_item` partials

### `pulse/_sidebar.html.erb`
Assembles sidebar sections:
- Logo/branding header
- Studio info (name, member count, privacy)
- Cycle indicator with progress bar
- Heartbeat status with avatar stack
- Navigation (Activity, Notes, Decisions, Commitments, Members)

### `pulse/_feed_item.html.erb`
Universal card component with:
- Header: type icon + label, author + timestamp
- Body: title + content + type-specific rendering
- Footer: contextual actions

---

## CSS: `app/assets/stylesheets/studio_pulse.css`

Self-contained stylesheet with `.pulse-*` prefixed classes:

```css
/* Layout */
.pulse-container { display: flex; min-height: 100vh; }
.pulse-sidebar { width: 280px; border-right: 1px solid #000; }
.pulse-main { flex: 1; }

/* Sidebar sections */
.pulse-sidebar-header { ... }
.pulse-studio-info { ... }
.pulse-cycle-box { ... }
.pulse-heartbeat-box { ... }
.pulse-nav { ... }

/* Feed */
.pulse-feed { ... }
.pulse-feed-item { border: 1px solid #000; margin-bottom: 16px; }
.pulse-feed-item-header { ... }
.pulse-feed-item-body { ... }
.pulse-feed-item-footer { ... }

/* Type-specific */
.pulse-decision-options { ... }
.pulse-commitment-progress { ... }

/* Responsive */
@media (max-width: 768px) { ... }
```

---

## Implementation Order

1. **Route** - Add route to `config/routes.rb`
2. **Controller** - Create `pulse_controller.rb`
3. **Layout** - Create `layouts/pulse.html.erb`
4. **CSS** - Create `studio_pulse.css` (from mockup styles)
5. **Main view** - Create `pulse/show.html.erb`
6. **Sidebar partials** - Create sidebar components
7. **Feed partials** - Create feed item components

---

## Verification

1. Start the app: `./scripts/start.sh`
2. Navigate to: `https://<tenant>.harmonic.local/studios/<handle>/pulse`
3. Verify two-column layout renders
4. Verify activity feed shows notes, decisions, commitments
5. Verify sidebar shows cycle info, heartbeats, navigation
6. Test responsive behavior at mobile widths

---

## Considerations

- **Heartbeat requirement**: Implement blur-without-heartbeat pattern like existing studio page
- **Navigation integration**: Add "Back to classic view" link
- **Empty states**: Handle cycles with no activity gracefully
- **Performance**: Add `.limit(100)` to feed queries for large cycles
