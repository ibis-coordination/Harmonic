# Feeds Are Queries — Implementation Plan

Implements issue #352 per the model in `docs/NAVIGATION_DESIGN.md` ("Feeds
are queries"): every content feed is search results with a fixed page scope,
refinable with `/search` syntax via a feed search bar.

## Decisions (settled)

- **`/` unifies home and public space**: fixed scope `visibility:public`,
  with `list:tuned_in` as a *default removable chip*. The rail's eye points
  at `/` honestly; "see everything" = remove one chip.
- **Collective feed is a new, separate page** (dashboard untouched for now);
  the plan is to *eventually* replace the cycle dashboard with it, decided
  later alongside the cycles-as-channels sidebar question.
- **Heartbeat gate stays page-level ritual** (pulse dashboard only). Queries
  may cross cycles freely — `/search` already works this way.
- **`SearchQuery` is the one feed engine.** `FeedBuilder` retires after
  conversion. Its two unique features: reminder-event interleaving (port)
  and proximity ranking (dead — home is chronological; drop).
- **`scope` means page scope only** — the DSL alias is already removed.

## Architecture

- **Fixed scopes are structural.** `SearchQuery` already takes
  `collective:`; extend with structural params as needed
  (`visibility_floor`, `creator`, `list`). Fixed scope is applied as ANDed
  server-side conditions, never by concatenating strings into the user
  query. A user term that conflicts with the fixed scope is dropped and
  reported.
- **Parser warnings channel.** `SearchQueryParser#parse` result gains
  `warnings: [...]` (unknown-operator fallthrough stays silent; only
  scope conflicts and ignored terms warn). Rendered above the feed and in
  markdown output.
- **URL semantics.** `?q` absent → apply page defaults; `?q=` present but
  empty → user cleared refinements; `?q=...` → user refinements. Canonical
  page URL (no `q`) always shows the default view.
- **Frontmatter.** Feed pages emit `scope:` (fixed, search syntax) and
  `query:` (current refinements) as separate keys in markdown frontmatter.
- **Feed search bar** is one ViewComponent: locked scope chips (outside the
  input), default/user filters as editable text, warning row, clear-filters
  affordance on empty results.

## Phases

Each phase is independently shippable, red-green TDD throughout.

### 1. Frontmatter scope on existing pages
Emit `scope:`/`query:` frontmatter for pages that already have a scope
(search, home, profiles, list activity, collective pages). Update
`/help/search` and `/help/markdown-ui` to document page scope. Pure agent
win, no UI change.

### 2. Feed bar on /search
Build the component where scope is empty: input, applied-filter chips,
warnings row, empty-state clear. Parser warnings channel lands here.
`/search` becomes the reference implementation of the bar.

### 3. Convert `/` (home ⇒ public space feed)
- `SearchQuery` gains reminder-event interleaving (FeedBuilder parity) and
  `list:tuned_in` **includes the viewer** (matches home's deliberate
  "your own writing stays on your home view" behavior; test this).
- `home#index` renders via `SearchQuery` with fixed `visibility:public`,
  default `list:tuned_in`; feed bar shows the locked chip + default chip.
- Default sort for feed pages is `newest` (search page keeps relevance
  when text present).
- Feed item rendering: unify the home feed item partials with search
  result rendering (one item partial, both pages).
- Rail eye active state unchanged (`/`). Anonymous viewers (anon-read
  tenants): no default chip (no tuned-in list), fixed scope only.

### 4. Collective feed page
New page (proposed: `/collectives/:handle/feed`) with fixed
`collective:x`, default `cycle:this-week`. First locked-chip + conflict
warnings exercise ("`collective:other` ignored: this page is fixed to
collective:x"). Dashboard (`pulse#show`) untouched; add a link between
dashboard and feed views.

### 5. Profiles and list activity
`/u/:handle` (fixed `creator:handle`) and `/u/:h/lists/:id` (fixed
`list:id`) render through the same engine + bar. `FeedBuilder` retires.

## Deferred (tracked in NAVIGATION_DESIGN.md)
Dashboard replacement; operator autocomplete; saved refinements (not
"lists" — that word is taken); sort:/group: UI affordances; Turbo-frame
feed updates (full navigation first).

## Open implementation details (proposals, not blockers)
- Collective feed URL: `/collectives/:handle/feed` (alternative: query-only
  mode on the dashboard URL — rejected for clarity).
- Pagination on feed pages: search's cursor with a "load more" affordance.
- `cycle:this-week` vs `cycle:current`: use whichever DSL value matches the
  collective's tempo semantics (verify against `CYCLE_PATTERN` values).
