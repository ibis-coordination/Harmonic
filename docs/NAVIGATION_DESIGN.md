# Navigation Design: Visibility Zones and the Collective Rail

**Status: draft, iterating.** Written alongside issue #337 / PR #339 (the
collective rail). This doc records the mental model the navigation chrome is
built on, so each iteration strengthens the model instead of accreting
features. Update it as decisions land.

The feeds-are-queries half of this doc (issue #352) **shipped in PR #358**:
the query engine, page scopes, frontmatter, the feed bar, and the route swap
that made the feed each collective's default page. Those sections below are
updated to describe reality; the rail sections are still design-ahead.

## The core idea: visibility zones

Everything a user touches in Harmonic lives in one of three visibility zones:

| Zone | What lives there | Spatial home in the UI |
|---|---|---|
| **Public** | The tenant's main collective — content visible to the whole tenant (and, with anonymous read access, the web) | The globe at the top of the rail |
| **Shared** | Collectives the user belongs to — visible to fellow members | The squares in the rail |
| **Private** | The user's private workspace — visible to the user (and their AI agents) only | *Not the rail.* See "Private zone" below |

The navigation should make the zone boundary **legible at a glance**: a user
should always know which zone they're standing in, because the zone is the
answer to "who can see this?" — the single most important question when
writing anything.

The left rail is the **public + shared zone selector**. It deliberately
excludes the private zone: the left edge of the page is social space. Putting
private and shared entries in the same strip would make the most
consequential boundary in the app invisible.

## Layered chrome

The UI has four layers, each with its own chrome and its own question:

| Layer | Chrome | Question it answers |
|---|---|---|
| **You** (tenant-global) | Top header: search, create (+), notifications, avatar menu | "What concerns me, everywhere?" |
| **Place** | The rail | "Where am I?" |
| **Here** | Sidebar (second column) | "What's in this place?" |
| **Thing** | Main content | "What am I looking at?" |

Rules that follow from the layering:

- The header sits **above** the rail (full width). The header is you/tenant
  scoped; switching places doesn't change it, and the layout should say so.
  (Practical reinforcement: the auto-hide header would leave a dead notch in
  a full-height rail, and the logo would fight the rail for the corner.)
- You-level pages are reached from the **header**, never from the rail.
  No gear icon in the rail: profile/settings/sign-out live in the avatar
  menu, and duplicating them in a second chrome location dilutes the rail's
  "places" semantics.
- Tenant switching (`/subdomains`) is **not** a rail concern. The rail is
  within-tenant. Do not evolve it into a tenant switcher.

## Routes are the model

Content routes exist under three prefixes (`config/routes.rb`):

| URL prefix | Place | Zone |
|---|---|---|
| `''` (e.g. `/n/:id`) | Main collective | Public |
| `/collectives/:handle` | That collective | Shared |
| `/workspace/:handle` | Private workspace | Private |

**The URL prefix is the place.** The rail is a visual projection of the URL
prefix, which is why active states are matched on path prefix (implemented in
`CollectiveRailComponent`): the globe is active at `/`, a square is active on
that collective's pages, and nothing is active anywhere else.

### Pages with no place

`/notifications`, `/search`, `/billing`, `/u/:handle`, `/lists`,
`/ai-agents`, admin pages: these are you-level aggregators, not places. The
notifications page already models this correctly — it groups by collective
with an explicit nil bucket ("Other") rather than forcing everything into a
fake place. The rail follows the same discipline: **no rail entry is active
on these pages**, and no "everything else" rail entry should be invented for
them. They belong to the you-layer and are reached from the header.

## Feeds are queries (issue #352)

Every content feed in the app is conceptually **search results with a fixed
page-level filter** (the page's *scope*), which the user can refine with
additional filters using the same syntax as `/search`. This is the GitHub
Issues / Linear pattern: pages are named queries.

| Page | Fixed scope | Also a place? |
|---|---|---|
| `/` (home / public space) | `visibility:public` | Yes (the globe) |
| `/collectives/:handle` | `collective:x` | Yes (a square) |
| `/workspace/:handle` | `visibility:private` | Yes (not in the left rail) |
| Profile `/u/:handle` | `visibility:public creator:@handle` | No — you-level, no rail state |
| List activity `/lists/:id` | `visibility:public list:id` | No — you-level |
| `/search` | *(none)* | No — the only unscoped feed |

The `visibility:` operator's values — public, shared, private — are exactly
the visibility zones: the zone model and the search DSL already share
vocabulary. Note the asymmetry: **every place has a fixed scope, but not
every fixed-scope page is a place.** Profiles have a scope and no chrome
claim.

This completes the model's account of the main content column, and it means
the same fact is projected three ways for three audiences:

- **The rail** is the spatial projection of the scope lattice (clicking a
  square applies a fixed filter).
- **The search syntax** is the linguistic projection (typing
  `collective:x` applies the same filter).
- **Markdown frontmatter** gets a scope attribute — the agent projection.
  Agents learn one navigation calculus: `search(scope + refinements)`.

This shipped in PR #358. All feed pages (home, collective root, workspace,
profile tabs, list activity) route through `SearchQuery` with structural
`fixed_params`; markdown frontmatter emits `scope:` and `query:`; the feed
bar renders on every feed page. `FeedBuilder` still renders the cycle
dashboard and retires when the dashboard converts. The canonical
scope/default-query table lives in `app/views/help/markdown_ui.md.erb`
(the Page Scope section).

### Guardrails

1. **Places must not dissolve into search results.** Zulip is built on this
   model ("narrows") and disorients newcomers because refining a filter
   feels like leaving. GitHub avoids it because the repo remains an
   unmistakable place — only the list within it is a query. Therefore:
   **chrome binds to the URL prefix, never to the query.** The rail,
   sidebar, and header are fixed by where you are; the query only shapes
   the feed. The fixed scope is not removable in-page — on
   `/collectives/x` you cannot delete `collective:x` from the filter bar;
   broadening means going to `/search`, a deliberate act of leaving.
2. **Visibility is enforcement, not a filter term.** Queries are the
   *rendering* model, never the *access* model. Zone boundaries stay
   structural (default scopes, thread tenancy, membership checks); the
   filter string is a presentation of the boundary, not its implementation.
   The feed is not "one giant tenant feed" — it is one
   accessible-universe-per-viewer, and queries only ever carve *down* from
   it. If removing a filter could ever widen access, the design is wrong.
3. **Notifications stay out.** `/notifications` is recipient-state
   (deliveries, read/dismissed), not a content query. Forcing it into the
   feed model would corrupt both models; the nil-bucket discipline above
   is unchanged.
4. **Naming.** "Scope" means exactly one thing: a page's fixed filters.
   The search DSL's old `scope:` alias for `visibility:` has been removed
   (clean break — `scope:x` now falls through to plain search text). Do not
   reintroduce a `scope:` operator.
5. **Performance.** Fixed scopes are indexable; user-composed refinements
   make every feed page search-shaped. Feed pages inherit search's
   pagination/cursor machinery rather than bespoke cheaper queries — accept
   this deliberately, page by page.

### The feed bar (shipped in #358)

Every feed page gets a filter bar at the top of the feed column
(`FeedSearchBarComponent`):

```
┌──────────────────────────────────────────────────────────────┐
│ collective:my-team  cycle:this-week type:decision…    [Filter]│
└──────────────────────────────────────────────────────────────┘
   └── fixed, muted ──┘ └── editable text ──┘
```

Filters come in three tiers, and the UI must make the tier visible:

| Tier | Example | Rendering | Editable? |
|---|---|---|---|
| **Fixed** (the page scope) | `collective:my-team` on `/collectives/my-team` | Muted token inside the field, not editable | No — it *is* the page |
| **Default** | `cycle:this-week -subtype:comment` on a collective home | Ordinary query text | Yes — remove or replace freely |
| **User** | anything typed | Query text | Yes |

Decisions and rationale:

- **Everything renders inside one field; tier is shown by style, not
  position.** Fixed scope tokens sit at the front of the field as muted,
  non-editable text, followed by the editable query text — the whole thing
  reads as one query. (An earlier draft put fixed chips outside the input
  with a lock glyph; both were rejected in review — a lock reads as
  *privacy*, and splitting the filters across two containers breaks the
  one-query reading.) The fixed tokens are still not deletable: broadening
  means leaving for `/search`.
- **"Filter", not "search".** Feed pages say Filter (placeholder and
  button); the word "search" is reserved for `/search`. Two affordances,
  two verbs.
- **Defaults are real query text, owned by the user.** A page may ship
  defaults (`cycle:this-week` keeps a collective home focused on the
  current cycle); once the page loads, defaults are indistinguishable from
  user filters. This requires distinguishing *no query param* (apply
  defaults) from *empty query param* (user cleared everything): `?q=`
  present-but-empty means "browse everything in scope", absent means
  "defaults". GitHub Issues has exactly this distinction. A blank query
  with a fixed scope *browses* — the fixed scope is what makes a page a
  feed; only `/search` keeps blank-means-empty behavior.
- **No hidden filters — the comment exclusion is default query text.**
  Feed defaults read `… -subtype:comment` in the input, visible and
  removable, instead of a structural `exclude_subtypes` param silently
  ANDed onto whatever the viewer types. A viewer-supplied `?q` therefore
  gets raw search semantics, comments included — the same universe as
  `/search`. Fixed internal feeds that want no comments say so in their
  own query (list activity; the profile Posts/Activity tabs already
  did). An earlier draft special-cased `my:notified` to lift a hidden
  exclusion; rejected — defaults carry the curation, queries carry
  nothing invisible. **Private workspaces have no default query at
  all**: `visibility:private` is the only filter — there is no curation
  layer over your own space.
- **Refinements live in the URL** (`/collectives/x?q=type:decision`), so
  filtered views are shareable and the back button works. The canonical
  page URL (no `q`) always shows the default view. Markdown frontmatter
  carries `scope:` (fixed) and `query:` (current refinements) separately,
  so agents see the same three-tier structure humans do.
- **Conflicts resolve structurally, loudly.** If a user types
  `collective:other` on a page fixed to `collective:x`, the fixed scope
  wins because it is enforced as a server-side condition, never by string
  concatenation — and the UI says so ("`collective:other` ignored: this
  page is fixed to collective:x") rather than silently returning
  confusing results. Same for `visibility:` terms that exceed the page's
  zone.
- **Two search affordances, two jobs.** The header search field is global:
  it *leaves* (goes to `/search`). The feed bar *stays*: it refines the
  current page. This is the GitHub pattern (global search vs. the issues
  filter bar). Style them differently; never merge them.
- **Empty results state** offers one-click "clear filters" (restore
  defaults), since dead-end refinements are the most common failure mode.
- Later, not now: operator autocomplete in the bar; saved refinements
  (do not call them "lists" — that word is taken by people-lists);
  `sort:`/`group:` controls rendered as UI affordances that read/write
  the same query.

## Private zone (out of scope here, but load-bearing)

The private workspace needs to be *more* accessible than it is today, but not
via the left rail. Direction worth exploring: the **right side of the page**
as the private edge — a mirror of the spatial metaphor (left edge = outward /
social, right edge = inward / personal). That could take the form of a
persistent right-side affordance, a slide-over panel, or a right rail.

Private workspace UX needs its own design strategy and doc; this doc only
reserves the spatial claim: **the left rail is public + shared; private
enters from somewhere else.** Nothing in the rail's design should assume it
will one day hold workspace entries.

## Form factors: one model, two projections

The four layers and the zone metaphor are the invariants; the *surfaces*
they project onto differ by form factor. Desktop answers with columns
because it has horizontal space. Mobile should answer with thumb
ergonomics: the bottom edge is the prime real estate (always visible,
thumb-reachable), the top bar is informational (far from thumbs — labels,
not controls), and large dynamic lists belong in sheets or screens, not
strips.

### The mobile-first target

**Bottom tab bar** — the persistent destinations, ordered left→right as
outward→inward so the bar preserves the spatial metaphor:

```
[ Home(globe) ] [ Places ] [ Search ] [ Inbox ] [ You ]
   public       shared               you-layer   → private
```

- **Home** is the globe: the `/` public feed.
- **Places** is the rail reshaped: tapping opens the collective switcher
  as a full sheet — icon + **name** + badge per row, "+" at the bottom.
  Richer than icon squares, and it fixes what the rail can never fix on
  touch: `title` tooltips don't exist, so square-only icons are unlabeled
  on phones. The tab itself carries an aggregate unread dot so the badges'
  ambient value survives while the sheet is closed.
- **Inbox** is notifications, with the count badge.
- **You** is the avatar menu — and eventually the doorway to the private
  workspace. The doc reserves "private enters from the right"; on mobile,
  **the rightmost tab is the right edge**. The zone model survives the
  translation: globe on the far left, workspace behind the far right.
- **Create** takes no slot — a FAB or top-bar `+`; creation is contextual
  (create-in-this-place).

**Top bar** — "where am I", not "where can I go": the place name (+
heartbeat status), tappable to open the here-layer. On mobile the top bar
stops being a control cluster and becomes a label.

**The sidebar dissolves into the place.** Feeds-are-queries already
started this: cycle nav and type filters became query refinements, so the
sidebar is shrinking toward place identity + team + heartbeats + pinned.
Mobile-first, that residue is not chrome — it is a collapsible **place
header** on the place's own screen (or a sheet behind the top-bar title).

**The feed bar is already form-factor-agnostic** — it belongs to the
content column and stays there everywhere.

### Desktop is the unfolding, not the original

At desktop widths the same destinations unfold: **Places unfolds into the
rail** (a permanently-open switcher — same data, same badges), You/Search/
Inbox relocate to the header, the place header re-columnizes into the
sidebar. The rail and the bottom bar never coexist; they are one
destination at two widths. "Hiding the rail" on desktop is just re-folding
the Places destination — one mechanism at every width.

None of this touches the agent surface: chrome is HTML-only, and agents
navigate by `scope:`/`query:` frontmatter, which is what frees the human
chrome to reshape per form factor without forking the model.

### Increments (each independently shippable, none undone by the next)

1. **Sidebar → place header**, paced by how much of the sidebar
   feeds-are-queries continues to absorb. This also owes the top bar its
   place label — with the control cluster gone on mobile, the slimmed
   bar still shows the logo, not "where am I".

Shipped from this list:

- **Bottom tab bar** (built): `[Home(globe)][Places][Search][Inbox][You]`
  under 768px, the rail's mirror — CSS shows exactly one of the two per
  width (`--pulse-tab-bar-height` is the layout hook, 0 on desktop).
  Places carries the aggregate dot and toggles the sheet (the header
  toggle is gone); Inbox carries the total count (`[data-total-badge]`,
  fed by the same `notifications:counts` broadcast); You opens the
  avatar menu upward (shared `layouts/_user_menu` partial, rendered in
  both the header dropdown and the bar — the You-menu positioning is
  pure CSS because measuring a `display:none` menu's offsetParent
  resolves to `<body>` and breaks on scrolled pages). On mobile the
  header hides search/inbox/avatar (they stay in the DOM — the
  notification poller lives in the header cluster) and keeps the
  contextual `+`; creation takes no tab.

- **Badge click-through + clearing affordance** (open question 3, built):
  reminder-notification attribution, the `my:` filter namespace
  (`my:notified`, `my:unread`, `my:read`), badged rail/sheet entries
  linking to the place's feed at `?q=my:notified`, and a mark-all-read
  affordance on that view. Deliberately sequenced before the bar so
  badges drain in place. The click target is the **whole entry**, not the
  badge: a nested anchor is invalid HTML and the badge is too small a tap
  target, so a badged entry's href swaps to the filtered view and swaps
  back when the count drains (`UnreadBadgeDisplay#place_entry_href`
  server-side, mirrored by the rail-badges controller via
  `data-place-path`). Chat never swaps — it is not a feed; `/chat` is
  already its queue.

- **Rail desktop-only** (#339): hidden under 768px by redefining
  `--pulse-rail-width` (the motto footer's border-continuation offset
  derives from it — keep that constraint for any future hide/fold).
- **Places sheet on mobile**: the rail's destinations as labeled rows
  (`PlacesSheetComponent` — globe, chat, collectives with names, "+"),
  slid over from a mobile-only header toggle that carries an aggregate
  unread dot. Badges reuse the rail's classes so a second rail-badges
  controller instance keeps them fresh from the same
  `notifications:counts` broadcast; first paint is server-rendered. Built
  as the future Places tab's content, not a throwaway drawer.

## Decided (current iteration)

- **Active states are path-based**, not `current_collective`-based —
  `current_collective` falls back to the main collective on every route
  without a handle, so it cannot distinguish "in the public space" from
  "on /billing".
- **Rail shows standard collectives only**, alphabetical, main collective
  excluded (it is the globe).
- **Rail is logged-in only** for now. Under the zone model, anonymous
  visitors have no shared zone; whether they get a public-zone-only rail is
  tied to the globe question below.
- **Rail styling follows app tokens** (6px avatar radius matching
  `.pulse-collective-avatar`, monochrome active treatment, canvas-default
  background). The rail is chrome, not a themed island.
- **`/` unifies home and the public space.** Fixed scope
  `visibility:public` with `list:tuned_in` as a default *removable* chip:
  the default view is the personal tuned-in feed, and "see everything" is
  removing one chip. The globe points at `/` and is honest. (This resolves
  the former globe/home open question via the feeds-are-queries model.)
- **The feed is the collective's default page** (shipped in #358). The
  query-backed feed lives at `/collectives/:handle`; the cycle dashboard
  (`pulse#show`) moved to `/collectives/:handle/dashboard` and keeps its
  structure for now. The feed's sidebar shares the dashboard's place-level
  sections (team, heartbeats, pinned) but drops the cycle-navigation
  sections, which are dashboard concerns.
- **The heartbeat gate is page-level ritual, not an access rule.** The
  ritual lives on the collective's root (the feed) and the dashboard;
  viewing past cycles on the dashboard additionally requires a heartbeat,
  while queries (including `cycle:` refinements on feed pages and
  `/search`) cross cycles freely.
- **Comment notifications surface as the comment.** `my:notified`
  resolves a comment notification to the comment itself (an earlier
  build climbed to the thread root because feeds hid comment rows — the
  root then appeared with no sign it was about a comment). Feed cards
  for notes navigate via `display_path`, so a comment card opens its
  thread at `?comment_id=` — the same URL the notification carries —
  where the comment scrolls into view highlighted. Action endpoints
  keep building from `path`, the canonical bare resource URL.
- **Chat is one aggregated rail entry beneath the globe.** A bare icon
  (like the globe, not a square) linking to `/chat`, active on all chat
  pages. Its badge is type-based — unread `chat_message` notifications —
  because chat notifications carry no event and therefore no collective;
  they never appear in the per-collective counts, so the chat badge and
  the square badges partition the event-space cleanly. A click lands on
  the chat index, which lists conversations.

## Open questions

1. **Chat placement — resolved.** Chat is a single pinned rail entry
   beneath the globe (the Discord "DMs" slot), not one square per chat
   collective: a bare comment icon linking to `/chat` (the chat index is
   the landing place for an aggregate count), active across all of
   `/chat`. Its badge counts unread `chat_message` notifications by *type*
   — chat notifications carry no event, so they were never in the
   per-collective counts and the two can't double-count. See Decided.
2. **Sidebar contents per place** (issue #337's "cycles as channels").
   The route swap landed (feed is the default page, dashboard at
   `/dashboard`), but the dashboard itself hasn't converted to a query —
   decide the sidebar question together with that conversion.
3. **Badge click-through — resolved, shipped.** A square's unread badge
   implies clicking will show what you're being notified about, but the
   collective feed rendered with no notification context. The fix is a
   `my:` filter namespace: the DSL is already viewer-relative
   (`list:tuned_in` resolves against the current user), but `list:*`
   resolves to *authors* and filters on content facts, while `my:*`
   filters on the viewer's own state per item — a different data layer
   the prefix makes explicit.

   Harmonic has two such layers, and they get **two names** (the earlier
   draft's "choose one meaning" fork is resolved by not blending):

   - **`my:notified`** — the delivery layer: items in scope with an
     **undismissed** notification addressed to the viewer. This is the
     inbox projected onto the feed. Undismissed-not-unread is deliberate
     and matches existing precedent: the header badge counts *unread*
     while the notifications page shows *undismissed* — the count is the
     urgent subset, the view is the full queue. Badge click lands on the
     place's feed at `?q=my:notified`.
   - **`my:unread`** — the social layer: notes in scope the viewer has
     not confirmed read. Anchored to read-confirmation (reader counts,
     confirm-read), which is what "read" already means everywhere else
     in the product. Fully separable from the badge system, and a
     different query shape (a negative join against read-confirmations
     vs. `my:notified`'s id-set resolution) — shipped alongside it as
     part of the same filter engine.

   What makes the click-through actually drain the badge:

   - Confirm-read already clears the pointing notification (shipped in
     1.38.0), covering notes and reminders.
   - Non-confirmable items (votes, tune-ins) drain via the mark-all-read
     affordance on the `my:notified` view, wired to the inbox's existing
     per-collective action (`mark_read_for_collective`, which reaches
     reminders through read-time attribution). Marked-read items stay in
     the view — `my:notified` shows the undismissed queue; the badge
     counts its unread subset. Dismissal stays on `/notifications`.

   Prerequisite: **reminder-notification attribution.** Reminder *notes*
   have a collective; only their notification rows are placeless
   (`event_id: nil` — an implementation artifact, not a semantic truth).
   Attribution is derived at read time through the existing
   `notes.reminder_notification_id` link (no schema change — a
   `collective_id`-family column on notifications would collide with
   ApplicationRecord's collective auto-scoping, and notifications must
   span collectives). With it, reminders flow into per-collective badges
   and `my:notified` like everything else. The genuinely placeless residue —
   tenant-level notifications (trustee authorizations, account security)
   plus chat (which has its own entry) — is what keeps the header inbox:
   it stays, as the cross-place queue and the mobile Inbox tab, but it
   stops being the *only* place a badge can drain, which was the actual
   problem. **Do not hide the inbox** to dedupe against the badges; they
   are two projections of one state with different jobs.

   Guardrail 3 is intact: `my:notified` filters *content* by
   recipient-state; `/notifications` itself (deliveries, lifecycle) stays
   out of the feed model.

   Anonymous viewers: `my:*` with no signed-in user warns and matches
   nothing, same pattern as other unresolvable filters.

   Sequencing: everything through the clearing affordance has shipped.
   Next is the bottom tab bar — its Places/Inbox split only feels right
   now that badges drain in place. Dedicated `my:unread` UX (beyond the
   filter itself) waits until it earns its slot.

(The former "what is the globe?" question is resolved — see Decided: `/`
unifies home and the public space via the default `list:tuned_in` chip.
Today's `/` was already expressible as `visibility:public list:tuned_in`;
the unification makes the default view a *default*, not a separate page.)

## Planned next steps (rough order)

1. **Ordering/overflow**: alphabetical until it hurts; then recency or
   pinning. The "+"/browse entry is the overflow escape hatch.

Shipped from this list:

- **"+" at the rail bottom** — create/join collective, linking to
  `/collectives` (also the escape hatch when the rail overflows). A
  dashed hollow square: a utility, not a place; no active state.

- **Sticky rail** (`position: sticky; top: 0; height: 100dvh`): pinned to
  the viewport while the document scrolls; the rail scrolls independently
  only when it overflows, the motto footer stays a document-level element,
  and it coexists with the auto-hide header. The full "app shell owns
  scrolling" containment model (100vh shell, per-column scrolling) remains
  deferred — it would break the auto-hide header's window-scroll listener
  and change the footer's meaning; reconsider both together.
- **Per-square unread badges** (every entry, the globe included), keyed by
  collective id. One poll feeds both the header badge and the rail: the
  header poller broadcasts a `notifications:counts` event that the
  rail-badges controller projects onto the squares. Initial state is
  server-rendered so Turbo navigations never flash the badges out.
  Reminders (no event → no collective) count toward the header total only.

## Non-goals

- The rail does not switch tenants.
- The rail does not hold user settings, notifications, or any you-level
  destination.
- The rail does not hold private workspaces (see "Private zone").
