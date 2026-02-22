# Plan: Add ViewComponent and Refactor Views

## Context

The app has 62+ shared ERB partials in `app/views/shared/` with varying complexity. Some have significant inline Ruby logic, complex conditionals, and many local variables. There are no existing component abstractions — just partials and helper methods. Adding `view_component` will provide better encapsulation, explicit interfaces, and unit-testable view logic.

**Key constraint**: ~~Rails 7.0.8 requires `view_component ~> 3.24` (v4.x needs Rails 7.1+).~~ Resolved — now on Rails 7.2 with ViewComponent 4.x.

## Design Decisions

- **Flat naming** (`AvatarComponent`, not `Pulse::AvatarComponent`) — matches existing flat partial structure
- **Sidecar `.html.erb` files** — partials range 15-109 lines, too large for inline templates
- **CSS stays in existing Pulse stylesheets** — no co-located component CSS
- **Minitest** via `ViewComponent::TestCase`
- **Gradual migration**: replace partial body with component render call, keeping the partial file as a thin wrapper so all existing `render "shared/avatar"` call sites keep working

## What We'll Do in This PR (Foundation)

### 1. Install the gem

**`Gemfile`** — add:
```ruby
# ViewComponent - component-based view architecture
# Pinned to 3.x because 4.x requires Rails 7.1+
gem "view_component", "~> 3.24"
```

Then: `docker compose exec web bundle install`

### 2. Create AvatarComponent

**Source**: `app/views/shared/_avatar.html.erb` (37 lines, 20+ usages)

Create `app/components/avatar_component.rb`:
- `initialize(user:, size: nil, show_link: false, title: nil, css_class: "pulse-author-avatar")`
- Extract `avatar_initials` logic from `ApplicationHelper` into the component
- `render?` returns false when user is nil
- Private methods: `initials`, `has_image?`, `avatar_class`

Create `app/components/avatar_component.html.erb` — same markup as current partial.

Update `app/views/shared/_avatar.html.erb` to become a thin wrapper:
```erb
<%= render AvatarComponent.new(
  user: user,
  size: local_assigns.fetch(:size, nil),
  show_link: local_assigns.fetch(:show_link, false),
  title: local_assigns.fetch(:title, nil),
  css_class: local_assigns.fetch(:css_class, "pulse-author-avatar"),
) %>
```

Create `test/components/avatar_component_test.rb` — test initials, size class, link wrapping, nil user, image rendering.

### 3. Create AccordionComponent

**Source**: `app/views/shared/_pulse_accordion.html.erb` (29 lines, 38+ usages)

Create `app/components/accordion_component.rb`:
- `initialize(title:, open: false, count: nil, icon: nil, tooltip: nil, title_data: {})`
- No Stimulus dependency — pure HTML `<details>/<summary>`
- Uses `content` (ViewComponent block) instead of `yield`

Create `app/components/accordion_component.html.erb` — same markup.

Update `app/views/shared/_pulse_accordion.html.erb` to wrapper:
```erb
<%= render AccordionComponent.new(
  title: title,
  open: local_assigns.fetch(:open, false),
  count: local_assigns.fetch(:count, nil),
  icon: local_assigns.fetch(:icon, nil),
  tooltip: local_assigns.fetch(:tooltip, nil),
  title_data: local_assigns.fetch(:title_data, {}),
) do %>
  <%= yield %>
<% end %>
```

Create `test/components/accordion_component_test.rb`.

### 4. Update test infrastructure

- Add `Components` group to SimpleCov in `test/test_helper.rb`

## Future Phases (not this PR)

**Phase 2 — Simple components**: `BreadcrumbComponent`, `CopyButtonComponent`, `TooltipComponent`

**Phase 3 — Stimulus-dependent**: `CollapsibleSectionComponent`, `PinButtonComponent`, `ResourceLinkComponent`

**Phase 4 — Composition**: `AuthorComponent` (composes AvatarComponent), `MoreButtonComponent` (109 lines, complex case statement for option types)

**Phase 5 — Comments**: `CommentComponent`, `CommentsListComponent` (threading logic, mention autocomplete)

**Phase 6 — Helper extractions**: `profile_pic`, `backlinks` from `ApplicationHelper`

**Ongoing**: Migrate callers from `render "shared/..."` to `render ComponentName.new(...)` and delete wrapper partials once fully migrated.

## Files Modified

| File | Change |
|------|--------|
| `Gemfile` | Add `view_component ~> 3.24` |
| `Gemfile.lock` | Auto-updated by bundle install |
| `test/test_helper.rb` | Add SimpleCov Components group |
| `app/views/shared/_avatar.html.erb` | Replace body with component wrapper |
| `app/views/shared/_pulse_accordion.html.erb` | Replace body with component wrapper |

## Files Created

| File | Purpose |
|------|---------|
| `app/components/avatar_component.rb` | Component class |
| `app/components/avatar_component.html.erb` | Component template |
| `app/components/accordion_component.rb` | Component class |
| `app/components/accordion_component.html.erb` | Component template |
| `test/components/avatar_component_test.rb` | Unit tests |
| `test/components/accordion_component_test.rb` | Unit tests |

## Verification

1. `docker compose exec web bundle exec rails test test/components/` — component tests pass
2. `docker compose exec web bundle exec rails test` — full suite passes
3. `docker compose exec web bundle exec rubocop app/components/ test/components/` — linting passes
4. `docker compose exec web bundle exec srb tc` — type checking passes
5. Manually verify avatar and accordion render identically via browser (note show page, studio show page)
6. Markdown views (`.md.erb`) unaffected — they don't reference these shared partials
