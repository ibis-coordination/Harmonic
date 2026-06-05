# User List Feeds — activity feeds for lists

## ✅ Phase 1 — Homepage = primary list feed — SHIPPED

The viewer's home page (`/`) now renders content authored by the people
they tune in to (their primary list members) plus their own content,
instead of the full main-collective firehose.

This is the smallest possible v1 of "list feeds" — it answers the
load-bearing product question (lists become subscribed-to, not just
addressable) without yet introducing per-list feed URLs.

Shipped:
- [home_controller.rb](app/controllers/home_controller.rb) — `index`
  scopes Notes/Decisions/Commitments to `created_by_id IN (primary list
  members + self - blocked users)`. ReminderEvents join with the note's
  author for the same filter. Chronological order (proximity ranking
  removed — it normalized against tenant-wide scores that don't fit the
  now-filtered author set; revisit when proximity is refactored).
- [home/index.html.erb](app/views/home/index.html.erb) — empty state
  distinguishes "no tune-ins yet" (instructional) from "no recent
  activity from the N people you tune in to" (informational).
- [home/index.md.erb](app/views/home/index.md.erb) — markdown parity
  for the empty states.
- [user.rb](app/models/user.rb#L44) — `primary_user_list_in!` now
  rescues `RecordInvalid` / `RecordNotUnique` to handle the
  concurrent-create race window that the home view exposes (called on
  every logged-in `/` view now, not just first tune_in).
- Tests in [home_controller_test.rb](test/controllers/home_controller_test.rb):
  shows tuned-in content, hides non-tuned-in content, shows own content
  with no tune-ins, shows the explainer when feed is empty, hides
  blocked users' content even when a stale primary-list membership
  survives (both HTML and markdown paths).
- Test in [user_list_test.rb](test/models/user_list_test.rb): primary-
  list lookup recovers from a concurrent-create race.

Defense in depth:
- The HTML view's `FeedItemComponent` already filters by `block_related_user_ids`
  at render time. The markdown view has no such filter — so the controller-
  level filter is load-bearing for markdown correctness.

Design decision: include the viewer themselves in the filter. Strict
reading of "primary list feed" would exclude self (you can't tune in to
yourself), but excluding the author from their own home view is hostile
UX. The home feed = "the people you tune in to + you".

Out of scope (intentionally):
- Per-list feeds at `/lists/:id/feed`. The primary list IS the home
  feed; custom lists don't yet have a feed view. Add when needed.
- Proximity refactor (engagement → primary-list-based). User
  explicitly flagged this as a separate project.
- Reining in the AjaxToggleButton title ("adds their activity to your
  timeline view") — now technically accurate, but a sweep through the
  product copy for consistency is its own pass.

## Open follow-ups

1. **Per-list feed view.** Once we want custom lists to be
   subscribed-to (not just addressable), wire `/lists/:id/feed` using
   the same FeedBuilder pattern. Defer until a concrete use case
   surfaces.
2. **Proximity refactor.** The home feed shipped here is chronological
   only — the previous engagement-based proximity ranking was removed
   because `max_proximity` normalized against tenant-wide scores not
   matching the filtered author set (would have compressed the boost
   for feed authors when a high-proximity non-tune-in dominated the
   max). Refactoring proximity to be primary-list-based (and demoting
   engagement to secondary or removed) is a separate project per the
   user.
3. **Tenant scoping.** Membership is per-tenant via the primary list's
   tenant scope; content is filtered by `main_collective_id` of the
   current tenant. No cross-tenant leak. Verified by inspection.
4. **Empty-state suggestions.** Could suggest users to tune in to,
   based on proximity or shared collectives. Right now the empty state
   just instructs. Suggestions are a natural next iteration.
5. **Discoverability.** Removing the firehose from `/` means the only
   way to discover new authors is via collectives, search, or social
   proximity. If that's too narrow, a `/discover` route showing the
   old main-collective firehose may be needed. Wait for feedback.

## Existing infrastructure leveraged

- [FeedBuilder](app/services/feed_builder.rb) — unchanged; took the
  new scopes without modification.
- `User#primary_user_list_in!` — idempotent primary-list lookup, used
  by the controller.
