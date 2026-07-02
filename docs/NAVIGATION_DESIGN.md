# Navigation Design: Visibility Zones and the Collective Rail

**Status: draft, iterating.** Written alongside issue #337 / PR #339 (the
collective rail). This doc records the mental model the navigation chrome is
built on, so each iteration strengthens the model instead of accreting
features. Update it as decisions land.

## The core idea: visibility zones

Everything a user touches in Harmonic lives in one of three visibility zones:

| Zone | What lives there | Spatial home in the UI |
|---|---|---|
| **Public** | The tenant's main collective — content visible to the whole tenant (and, with anonymous read access, the web) | The eye at the top of the rail |
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
`CollectiveRailComponent`): the eye is active at `/`, a square is active on
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
| Public space | `visibility:public` | Yes (the eye) |
| Collective page | `collective:x` | Yes (a square) |
| Workspace | `visibility:private` | Yes (not in the left rail) |
| Profile `/u/:handle` | `creator:handle` | No — you-level, no rail state |
| List activity `/u/:h/lists/:id` | `list:id` | No — you-level |
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

The pieces largely exist: `SearchQueryParser` already supports
`collective:`, `list:` (including `list:tuned_in` / `list:mutuals`),
`visibility:`, `creator:`, `type:`/`subtype:`, `status:`, `cycle:`, date and
count filters, and `group:collective` (the notifications grouping as query
vocabulary); `FeedBuilder` already renders home, pulse, profile, and list
feeds. The gaps are routing collective-page feeds through the same engine,
the frontmatter scope attribute, and the feed search bar UI below.

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

### The feed search bar (UI direction)

Every feed page gets a search bar at the top of the feed column:

```
┌──────────────────────────────────────────────────────────────┐
│ [🔒 collective:my-team]  [cycle:this-week ×]  filter or search…│
└──────────────────────────────────────────────────────────────┘
```

Filters come in three tiers, and the UI must make the tier visible:

| Tier | Example | Rendering | Editable? |
|---|---|---|---|
| **Fixed** (the page scope) | `collective:my-team` on `/collectives/my-team` | Locked chip: muted, lock glyph, no × | No — it *is* the page |
| **Default** | `cycle:this-week` on a collective home | Ordinary chip with × | Yes — remove or replace freely |
| **User** | anything typed | Text/chips in the input | Yes |

Decisions and rationale:

- **Fixed chips are outside the input.** The scope is not text the user
  owns; it is a statement of where they are. Rendering it inside an
  editable input (GitHub's approach) invites deleting it, and deleting it
  is undefined here — broadening means leaving for `/search`.
- **Defaults are real query text, owned by the user.** A page may ship
  defaults (`cycle:this-week` keeps a collective home focused on the
  current cycle, echoing the sidebar's Current Cycle emphasis); once the
  page loads, defaults are indistinguishable from user filters. This
  requires distinguishing *no query param* (apply defaults) from *empty
  query param* (user cleared everything): `?q=` present-but-empty means
  "no refinements", absent means "defaults". GitHub Issues has exactly
  this distinction; copy it.
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

## Decided (current iteration)

- **Active states are path-based**, not `current_collective`-based —
  `current_collective` falls back to the main collective on every route
  without a handle, so it cannot distinguish "in the public space" from
  "on /billing".
- **Rail shows standard collectives only**, alphabetical, main collective
  excluded (it is the eye).
- **Rail is logged-in only** for now. Under the zone model, anonymous
  visitors have no shared zone; whether they get a public-zone-only rail is
  tied to the eye question below.
- **Rail styling follows app tokens** (6px avatar radius matching
  `.pulse-collective-avatar`, monochrome active treatment, canvas-default
  background). The rail is chrome, not a themed island.

## Open questions

1. **What is the eye, really?** It is labeled "Public space" but points at
   `/`, and `home#index` is the *personalized* feed (tuned-in authors,
   no sidebar). So the eye claims to be a place but delivers a you-page —
   the one genuine incoherence in the current model. Two resolutions:
   - *Home is home*: rename/re-icon the eye as Home and accept the hybrid.
   - *Public space is a real place*: the eye goes to a true main-collective
     page (all public activity, with a sidebar like any collective), and the
     personal feed becomes a you-level page reached from the header.

   The second keeps the rail 100% places and matches the zone model, but it
   changes what `/` means. Decide before investing in the cycles-as-channels
   sidebar work, which assumes every rail destination has a sidebar.

   The feeds-are-queries model sharpens this: today's `/` is literally
   expressible in the existing DSL as `visibility:public list:tuned_in` — a
   **personal saved query**, which is you-layer by definition — while the
   true public space is `visibility:public` unfiltered. Written in query
   vocabulary, the two pages are plainly different things, which weighs
   toward the second resolution.
2. **Chat placement.** Chat collectives are excluded from the rail but chat
   is a place by the route model. Discord precedent: a pinned entry in the
   rail (the "DMs" slot). Alternatively chat stays header/you-level. Unresolved.
3. **Sidebar contents per place** (issue #337's "cycles as channels").
   Depends on question 1.
4. **Mobile.** A permanent 60px column on a 375px screen spends ~16% of the
   viewport on place-switching. Likely end state: rail collapses into a
   drawer or merges with the sidebar. Accepted gap for now.

## Planned next steps (rough order)

1. **Sticky rail** (`position: sticky; top: 0; height: 100dvh;
   overflow-y: auto`): today the document scrolls the rail away, undermining
   "persistent". Sticky gives independent rail scrolling only when the rail
   itself overflows, keeps the motto footer as a document-level element, and
   coexists with the auto-hide header. The full "app shell owns scrolling"
   containment model (100vh shell, per-column scrolling) is deferred — it
   would break the auto-hide header's window-scroll listener and change the
   footer's meaning; reconsider both together.
2. **Per-square unread badges.** Notifications already group by collective,
   so per-collective counts exist server-side, and the header badge poller
   already runs. This makes the rail the ambient "where is activity"
   surface — the actual payoff of a persistent rail.
3. **"+" at the rail bottom** — create/join collective (and the escape hatch
   to browse `/collectives` when the rail overflows). Place-related, so it
   belongs in the place layer.
4. **Ordering/overflow**: alphabetical until it hurts; then recency or
   pinning. The "+"/browse entry is the overflow escape hatch.

## Non-goals

- The rail does not switch tenants.
- The rail does not hold user settings, notifications, or any you-level
  destination.
- The rail does not hold private workspaces (see "Private zone").
