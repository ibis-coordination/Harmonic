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

## Phase 1 — Search returns users

**Shape.** Augment `/search?q=foo` results with a "People" group at the
top of the results (or in a new tab/section), matching on:
- exact handle (highest rank)
- display name substring (case-insensitive)
- maybe also email if the viewer is an admin (defer — privacy concern)

**Visibility rules:**
- Anyone in the same tenant is searchable (matches existing collective-
  member-list visibility semantics).
- Blocked users are excluded from results in both directions.
- Archived users? Default: exclude. (Confirm during impl.)

**Render:** profile card with avatar, handle, display name, common-
collective count, and an inline **Tune in** button (reuses
`AjaxToggleButtonComponent`). Markdown parity: list with handle, name,
profile link.

**Where:** new section/tab in `/search`. JSON API exposes results under
a `people:` key. Action surface: extend the existing `search` action's
result schema; no new action endpoint needed.

**Open questions:**
- How to integrate with the existing search ranking — separate query
  layered on top vs unified relevance scoring? Lean separate layer.
- Per-page limit for people results (e.g. always top 5, with a
  "see all" link)?
- Should people results respect the `type:` filter? E.g. `type:person`
  or `type:user`? Probably yes for consistency.

## Phase 2 — Graph traversal

**Shape.** The primary list is the social-graph atom. Make it
navigable in two directions.

### 2a. From a profile, see who they tune in to (forward direction)

The profile's Lists accordion currently shows lists with member counts
but not members. For the primary list specifically, embed a small
preview of members (avatars + handles, maybe top 5–10) right on the
profile, with a "see all" link to the list show page.

Once the per-list feed plan ships, `/lists/:id` will have a members
tab. The profile preview is a teaser pointing there.

### 2b. From a profile, see who tunes in to them (reverse direction)

The reverse-direction signal already partly exists:
- Profile shows "Tuned in to you" badge when the relationship is mutual.
- No browsable list of "people who tune in to X."

**Decision needed:** is the reverse-direction list privacy-sensitive?
- Forward (who X tunes in to): X chose this; visible if X's list is
  public.
- Reverse (who tunes in to X): the choosers chose to follow X, but
  exposing the full list is more about *them* than about X.

Two plausible models:
- **Twitter-style** — public unless the tuner-in has a private primary
  list. Surfaces a "tuned in by" section on profiles.
- **Privacy-default** — reverse direction is intentionally not
  enumerable. Only the mutual-state badge appears.

Lean toward Twitter-style for v1 since primary lists default to public.
Revisit if anyone objects.

**Render:** profile-card row, same component as Phase 1's people-search
result. Tune-in button inline.

### 2c. Member rows on list show pages link to profiles

Already exist (`/lists/:id` shows member handles linking to profiles).
Once the members tab lands in the per-list feed plan, audit that each
row has an inline Tune-in button for fast traversal.

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
