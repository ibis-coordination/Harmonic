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
