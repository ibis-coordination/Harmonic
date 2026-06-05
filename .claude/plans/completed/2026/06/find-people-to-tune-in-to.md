# Find people to tune in to — discoverability for the primary-list world

**Status:** Draft / not started. Picks up after homepage = primary-list
feed shipped (`7dff9f2`).

## Why this exists

The homepage now shows only content from people the viewer has tuned
in to (plus their own content). That's a discovery cliff for anyone
with an empty or sparse primary list: search doesn't return users,
collective member lists aren't well-surfaced, and there's no graph
traversal — the only way to find someone is to already know their
URL or stumble across their authored content (which won't appear on
the home feed once you stop tuning in to them).

This plan adds two complementary discovery affordances:

1. **Search returns users** — type a handle or name, get profiles.
2. **Graph traversal** — once anyone has a primary list, "who does
   this person tune in to" becomes a navigable surface. Click a
   well-connected user → see their tune-ins → tune in to any of them.

Not in this plan: suggestion algorithms, onboarding flows, dedicated
`/discover` page. Those can come later if the two cheaper interventions
above don't close the gap.

## Existing infrastructure to lean on

- [SearchQuery](app/services/search_query.rb) — the current search
  service is built on a `SearchIndex` table that polymorphically holds
  Note/Decision/Commitment rows. Adding users to the index would
  require a migration + backfill. Cheaper: layer a separate User
  lookup alongside, since the User table is small enough to ILIKE
  directly per query.
- [users_controller.rb](app/controllers/users_controller.rb) profile
  shows a Lists accordion that includes the user's primary list. It
  surfaces the list link but doesn't preview members.
- [/lists/:id show page](app/controllers/user_lists_controller.rb)
  already renders members with their handles. After the parallel
  "per-list feed" plan ships (tabs on `/lists/:id`), members will
  share that page with the feed view.

## ✅ Phase 1 — Search returns users — SHIPPED

Shipped:
- [SearchQuery#people_results](app/services/search_query.rb) — separate
  query layered alongside the existing SearchIndex query. Matches on
  exact handle, handle ILIKE substring, and case-insensitive
  display_name substring. Tenant-scoped via `TenantUser`. Excludes
  self, both directions of `UserBlock`, archived TenantUsers,
  suspended Users, and `collective_identity` users (their `path`
  resolves via a separate Collective lookup that can return nil →
  broken links). Capped at `PEOPLE_RESULT_LIMIT = 10`.
- **Content-filter suppression**: People section disappears entirely
  when the search includes any content-specific operator (`status:`,
  `type:`, `creator:`, `voter:`, `participant:`, `min-*/max-*`,
  date filters, etc.). Status doesn't apply to people; surfacing
  irrelevant people results next to a content-focused query was
  noisy.
- **Collective-filter privacy gate**: `collective:<handle>` narrows
  people to members of that collective ONLY when the viewer can
  access that collective via `accessible_collective_ids`. Non-members
  of a private/non-main collective can't enumerate its membership
  by name-searching with the operator.
- HTML view: new `.pulse-people-results` section above the content
  results — avatar + display name (falls back to handle) + handle.
- Markdown view: `## People (N)` section above the grouped content
  results.
- JSON API: `people:` key in the response.
- Tests in [search_test.rb](test/integration/search_test.rb):
  exact-handle match, partial-name match, block exclusion, no-section
  when no matches, markdown parity, JSON shape.

Deferred (worth doing if usage demands):
- **Inline Tune-in button per result.** Would batch-load membership
  state to avoid N+1. Clicking through to the profile already exposes
  the Tune-in button, so this is convenience-only.
- **Common-collective count per result.** Cheap to compute per row
  but adds clutter; leave for now.
- **Ranking** — currently first-N order from Postgres without explicit
  ordering. Could prioritize exact-handle then prefix then substring.

## Phase 2 — Mutuals (graph traversal)

Mutuals (users who tune in to each other) are the public,
symmetric subset of the tune-in graph. Making mutuals first-class
solves three problems at once:

- A headline social signal on profiles ("N mutuals") that emphasizes
  reciprocity over follower-count vanity. Twitter shows two numbers
  (followers / following) and the asymmetry drives all kinds of
  bad behavior. Harmonic shows one.
- A navigable surface for discovering more people (browse a profile's
  mutuals → click through → tune in to anyone interesting).
- Avoids the reverse-direction privacy question entirely. Mutuals is
  symmetric, so both parties already know about the relationship —
  surfacing it leaks nothing new.

### 2a. Mutuals count on the profile header

Display `@handle · N mutuals`, with the count linking to
`/u/:handle/mutuals`. Always shown, even when 0 (the absence might
nudge the viewer to tune in).

### 2b. `/u/:handle/mutuals` page

Lists the user's mutuals, one card per row (same shape as the
search-people section and the per-list Members tab). HTML + markdown.

Mutuals = intersection of:
- members of the user's primary list (their outbound tune-ins)
- owners whose primary list contains the user (their inbound)

Tenant-scoped. Block-cleanup callback already wipes both directions of
primary-list membership on block, so mutuals auto-decrement.

### 2c. Member rows on /lists/:id link to profiles

Already exist (members tab links handles to profiles). After this
phase, profiles also show the mutuals count — so the audit is just
verifying click-through works. No code change expected.

### 2d. Mutual mutuals (viewer ∩ profile-user)

Beside the global "has N mutuals" count on a profile, show a
viewer-relative count: users who are mutually tuned in to BOTH the
viewer and the profile user. The bridge subset between the two
parties.

**Display.** On the profile header next to the global count, with a
parallel-construction copy that distinguishes whose number is whose:

> @handle · has N mutuals · X in common with you

(Or "X shared mutuals" / "X mutual mutuals" — see open question.)

Click-through behavior open: count-only for v1, or also a
`/u/:handle/mutuals-in-common` page that lists the bridge set?
Lean count-only — the existing /u/:handle/mutuals page already
covers the broader social-graph traversal need; "in common" is more
of a relational signal than a discovery surface.

**Hide when:**
- Viewer is the profile user (self ∩ self = own mutuals, redundant).
- Viewer is anonymous (no concept of viewer mutuals).

**Implementation.** New `User#mutuals_in_common_with(viewer, tenant)`
returning the intersection of `viewer.mutual_user_ids_in(tenant)` and
`self.mutual_user_ids_in(tenant)`, minus viewer-blocked users. Both
inputs are already cheap (two plucks each), so the intersection cost
is bounded by typical primary-list sizes.

**Open questions:**

- **Copy.** Three plausible labels: "X in common", "X shared mutuals",
  "X mutual mutuals". "In common" parallels the existing "common
  collectives" affordance and reads tightest. "Mutual mutuals" is
  precise but reads awkwardly inline. Lean "in common".
- **Page or count-only?** Defer the page; ship the count.
- **Hover or tooltip preview?** A small popup listing the first few
  mutuals-in-common could help users decide whether to click through
  to either profile. Defer; ship without.

### Open follow-ups (deferred)

- **Outbound preview on profile** (a teaser of the primary list's
  members). The primary list is already linked from the Lists
  accordion; the mutuals page covers the symmetric subset. Add only
  if the asymmetric "who do you tune in to" view earns its keep.
- **Inline Tune-in button on the mutuals row** — convenience, not
  load-bearing (clicking through to the profile already exposes it).
- **Counter cache for mutuals_count** — defer until profile-load
  latency demands it; intersection of two pluck arrays is cheap for
  typical primary-list sizes.

## Phase 3 — (optional) Empty-state suggestions

If Phase 1+2 don't close the cold-start gap, add a small suggestion
strip to the home empty state: "People in your collectives" or "Recent
posters in your collectives" — 5–10 profile cards.

Scope this only if feedback indicates the gap persists. Suggestion
quality is a rabbit hole.

## Non-goals

- Algorithmic ranking ("people you might know"). Requires a richer
  signal model than common collectives provides.
- Onboarding flow ("pick 5 people to tune in to during signup").
  Worthwhile but its own design + copy effort.
- Cross-tenant discovery. Stays scoped to the current tenant.
- Indexing users into `SearchIndex`. Layer a separate User query for
  Phase 1; reconsider if perf demands it.
- Email-based search. Privacy-sensitive; admin-only would be a separate
  surface.

## Dependencies

- Per-list feed/tabs plan (`/lists/:id` gets feed + members tabs) lands
  first or in parallel. Phase 2c assumes a members tab exists.
- Block-cleanup callback (`UserBlock` after_create — already shipped)
  is load-bearing for search-result correctness: a stale block-spanning
  tune-in shouldn't show up in graph traversal results.

## Initial sizing

- Phase 1 (search): half a day. Mostly view + tests; the query is a
  trivial ILIKE on `users.name`/`users.handle`.
- Phase 2a (forward graph on profile): half a day. Render-only;
  reuses existing data.
- Phase 2b (reverse graph on profile): half a day if Twitter-style;
  longer if we want a privacy toggle on the primary list.
- Phase 2c (members tab audit): trivial — likely just adding inline
  buttons.
- Phase 3 (empty-state suggestions): defer.

Total: roughly 1.5 days for Phases 1 + 2.
