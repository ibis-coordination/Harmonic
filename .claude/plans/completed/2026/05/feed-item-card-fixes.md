# Feed item card fixes

Branch: `feed-item-card-fixes`

Fix four reported bugs in [FeedItemComponent](../../app/components/feed_item_component.rb) /
[feed_item_component.html.erb](../../app/components/feed_item_component.html.erb), the card
rendered for Notes / Decisions / Commitments in:

- [home/index.html.erb](../../app/views/home/index.html.erb#L8-L13) — homepage feed
- [pulse/show.html.erb](../../app/views/pulse/show.html.erb#L49-L51) — collective pulse
- [users/show.html.erb](../../app/views/users/show.html.erb#L119-L126) — user activity feed

Reminder events route through [ReminderFeedItemComponent](../../app/components/reminder_feed_item_component.rb)
via [pulse/_feed_item.html.erb](../../app/views/pulse/_feed_item.html.erb#L1-L6) and are
out of scope here unless a fix has an obvious analogue.

## Bugs

### Bug 1 — Titleless notes render the first line of text twice

[Note#title](../../app/models/note.rb#L126-L131) falls back to `text.split("\n").first.truncate(256)` when the
persisted title is blank. So for any titleless note with more than one line, `item_title`
returns the first line, `item_content` returns the full text, and
[show_title?](../../app/components/feed_item_component.rb#L117-L123) compares the strings,
finds them different, and renders BOTH:

```erb
<div class="pulse-feed-item-title">first line</div>
<div class="pulse-feed-item-content">first line\n\nrest of text</div>
```

**Fix:** Change `show_title?` for Notes to gate on `persisted_title.present?` (the model
already exposes [Note#persisted_title](../../app/models/note.rb#L133-L136) for exactly this
kind of "did the user type a title" check). Single-line titleless notes were a happy
accident of the string-equality check; the persisted_title check is more honest.

### Bug 2 — Markdown HTML appears as escaped text in the card body

[Line 42](../../app/components/feed_item_component.html.erb#L42):

```erb
helpers.truncate(helpers.sanitize(helpers.markdown(item_content), tags: %w[a strong em]), length: 200)
```

`markdown()` returns `html_safe`; `sanitize(..., tags: [...])` preserves the safe buffer;
but Rails' `truncate` helper, since Rails 5, escapes its input by default — `html_safe`
on the input does NOT carry through. The user sees `&lt;p&gt;Hello&lt;/p&gt;` in the card.

**Fix (HTML feed):** Render the full markdown HTML — same markup as the show page,
including paragraphs/lists/headings/links — and visually truncate with CSS line-clamp.
When the content is taller than the clamp height, show a "Show more" button that
expands the card in-place to reveal the full rendered markdown (toggle back to
"Show less" once expanded). No mid-tag truncation, no escaped-HTML strings, the
preview is a faithful sample of the show page.

Mechanism:

- Template: `<div class="pulse-feed-item-content" data-controller="card-expand">
  <div data-card-expand-target="body" class="pulse-feed-item-content-clamped">
    <%= helpers.markdown(item_content) %>
  </div>
  <button data-action="click->card-expand#toggle" data-no-navigate
          data-card-expand-target="toggle" hidden>Show more</button>
  </div>`
- CSS: `.pulse-feed-item-content-clamped` uses `display: -webkit-box;
  -webkit-line-clamp: 6; -webkit-box-orient: vertical; overflow: hidden;`
  (or a fixed `max-height` + line-clamp fallback — match what the codebase already
  uses elsewhere; check `app/assets/stylesheets/pulse/` for existing clamp utility).
- Stimulus `card-expand` controller, in `connect()`: if `body.scrollHeight >
  body.clientHeight` (overflows the clamp), unhide the toggle button. `toggle()`
  removes/adds the `-clamped` class and swaps button text. The `data-no-navigate`
  attribute prevents the bug-4 navigation controller from also firing.
- `MarkdownRenderer.render` already sanitizes — content is XSS-safe.

**Fix (markdown feed):** No change. The markdown feeds in
[home/index.md.erb](../../app/views/home/index.md.erb#L6-L7),
[pulse/show.md.erb](../../app/views/pulse/show.md.erb#L27-L30),
[users/show.md.erb](../../app/views/users/show.md.erb#L42-L45) already render only
title + author + View link, no body content — full text already requires navigation
to the show page. (For titleless notes, `Note#title` returns the truncated first
line, so they get a sensible bullet too.)

### Bug 3 — Open decisions show current vote tallies to users who haven't voted

[Lines 64-75](../../app/components/feed_item_component.html.erb#L64-L75): non-executive,
non-lottery decisions render `results.first(5)` with `accepted_yes` / `preferred` counts
to everyone. The decision show page treats vote tallies as blind-taste-test data
(hidden until you vote); the feed card must match.

**Fix:** Gate the tally display on `@item.closed? || user_has_voted?` (new helper —
mirror [user_has_joined?](../../app/components/feed_item_component.rb#L165-L170) /
[user_has_read?](../../app/components/feed_item_component.rb#L144-L149)). When the user
hasn't voted on an open decision, render the option titles WITHOUT counts (same as the
existing executive/lottery branch on lines 52-63 — the markup is already there to reuse).

Need to confirm the right `user_has_voted?` API on Decision — likely
`@item.options.joins(:votes).where(votes: { user: @current_user }).exists?` or a
canonical helper. Use what `decisions/show.html.erb` already uses.

### Bug 4 — Clicking the card body doesn't navigate to the item show page

[Line 41](../../app/components/feed_item_component.html.erb#L41) has an inline `onclick`
on the content div ONLY when `show_title?` is false (which after bug 1's fix will be all
titleless notes — but currently nearly no cards). For every other card, the only
clickable surfaces are the title link and the "View →" / action buttons. Clicking
anywhere else in the card does nothing.

**Fix:** Stimulus controller on the whole `<article>` element that navigates to
`@item.path` on click UNLESS the click target is inside an interactive element
(`<a>`, `<button>`, `<form>`, `<input>`, `<textarea>`, `<select>`, or any element with
`data-no-navigate`). Cursor becomes pointer on the card; existing inline links/buttons
keep working because the controller short-circuits on them.

Drop the inline `onclick` hack. The controller covers it.

New file: [card_navigate_controller.js](../../app/javascript/controllers/card_navigate_controller.js).
Wire on the `<article>` via `data-controller="card-navigate" data-card-navigate-url-value="<%= @item.path %>"`.

Add a Vitest test for the controller's "ignore clicks on interactive children" logic.

## Tests

[FeedItemComponentTest](../../test/components/feed_item_component_test.rb) is the primary
test surface (`render_inline` covers all rendering paths). Add tests under TDD — write
failing tests first, run them red, then implement.

- **Bug 1:** test that a titleless Note (`title: nil, text: "Line 1\n\nLine 2"`) renders
  the text exactly once and does NOT render the `.pulse-feed-item-title` div. Inverse
  test: a Note WITH a persisted title renders both the title row and the content.
- **Bug 2:**
  - Test that a Note with `text: "**bold** _italic_"` renders `<strong>bold</strong>`
    (real tag, not escaped) inside `.pulse-feed-item-content`.
  - Test that `data-controller="card-expand"` is present on the content wrapper.
  - Vitest test for the `card-expand` Stimulus controller: button stays hidden when
    body doesn't overflow; toggle adds/removes the clamp class and swaps button
    text; `data-no-navigate` is on the button.
- **Bug 3:** test that an open non-executive Decision rendered for a user who hasn't
  voted does NOT render `.pulse-option-votes` spans. Inverse: same decision for a user
  who HAS voted renders the counts. Closed decision: counts always shown.
- **Bug 4:** Vitest test for the Stimulus controller covering: click on the article
  navigates; click on a child `<a>` does not; click on a child `<button>` does not;
  click on an element with `data-no-navigate` does not. A component-test assertion
  pins the `data-controller="card-navigate"` attribute and the URL value.

## Out of scope

- Other reported bugs the user mentioned (will be tracked separately when listed).
- `ReminderFeedItemComponent` rewrite — out unless one of the four fixes has an obvious
  parallel there.
- Refactoring the FeedItemComponent template (the file is ~175 lines and would benefit
  from breaking up, but that's its own PR).

## Files touched (expected)

- [app/components/feed_item_component.rb](../../app/components/feed_item_component.rb)
  — `show_title?` rewrite, new `user_has_voted?` helper.
- [app/components/feed_item_component.html.erb](../../app/components/feed_item_component.html.erb)
  — `<article>` gets `card-navigate` stimulus attrs; line 41 onclick removed; line 42
  becomes full `helpers.markdown(item_content)` wrapped in a `card-expand` controller
  div; decision results section gated on closed-or-voted.
- [app/javascript/controllers/card_navigate_controller.js](../../app/javascript/controllers/card_navigate_controller.js)
  — new Stimulus controller (bug 4).
- [app/javascript/controllers/card_expand_controller.js](../../app/javascript/controllers/card_expand_controller.js)
  — new Stimulus controller (bug 2 expand/collapse).
- [test/components/feed_item_component_test.rb](../../test/components/feed_item_component_test.rb)
  — new tests for the four bugs.
- New Vitest tests for both controllers.
- Pulse CSS: `.pulse-feed-item-content-clamped` (line-clamp + overflow hidden),
  `.pulse-feed-item` cursor + hover style for clickable card. Check existing pulse
  stylesheets for a clamp utility before adding a new class.
