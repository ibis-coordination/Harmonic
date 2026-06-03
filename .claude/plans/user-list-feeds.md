# User List Feeds — activity feeds for lists

**Status:** Draft / not started. Picked up after `user-lists` ships.

## Goal

Give each `UserList` a consumable activity feed of recent Notes,
Decisions, and Commitments authored by its members. Make the
"tune in" gesture do something the viewer can actually feel —
they can read content from the people they've tuned in to.

## The product question this plan has to answer

The `user-lists` plan was explicit (line 23, line 507) that lists are
**addressable**, not **subscribed to** — you reference a list, you don't
follow it. Adding a feed shifts that framing: tune-in starts to behave
like a follow.

That's a real direction change, not just an implementation. Before this
plan goes deep, we need a clear answer to:

- Is the primary list's feed actually "my timeline" (everyone I've tuned in to)?
- Are custom lists meant to be subscribed-to by their owner only,
  or readable by anyone who can see the list?
- Does "tune in" become a verb-of-following, or does the feed stay
  list-scoped and tune-in keeps its addressing semantics?

The wording in the current tune-in button title ("adds their activity to
your timeline view") has already drifted in the follow direction.
Either the copy needs to be reined in or the feature needs to catch up.

## Existing infrastructure to lean on

- [FeedBuilder](app/services/feed_builder.rb) already accepts per-resource
  scopes and handles optional proximity-based ranking — a list feed is
  primarily a scope-shape change (`created_by_id IN list.members`).
- Profile feed at [users_controller.rb:94-101](app/controllers/users_controller.rb#L94-L101)
  shows the exact pattern: scoped by author within `main_collective`.
- `feed_item` partial under [app/views/pulse/](app/views/pulse/) is the
  rendering primitive — already used by `/pulse`, profile, and home.

## Rough shape (not final)

- New action `UserListsController#feed` (or fold into `show`).
- Reuse `FeedBuilder` with `created_by_id IN list.members.pluck(:id)`.
- Honor the existing `visible_to?` gate — private list = owner only.
- Markdown parity: same feed rendered at `Accept: text/markdown`.

## Open questions to resolve before implementation

1. **Primary list vs custom list semantics.** Are these the same kind of
   feed, or should the primary list's feed live at a different
   URL (e.g. `/timeline`) since it represents the owner's social filter
   rather than an addressable group?
2. **Member churn.** Feed shows content from current members? Or content
   posted while each member was on the list? Simplest is the former
   (no historical membership intersection); likely also what users expect.
3. **Visibility for non-owners.** A public list's feed — viewable by
   anyone who can see the list? Or owner-only regardless of list privacy?
4. **Reminders & ReminderEvents.** Include? They're already in
   FeedBuilder but currently flow only on personalized feeds.
5. **Proximity ranking.** Apply when the viewer is the list owner?
   Skip entirely for list feeds (chronological only)?
6. **Pool size at scale.** A list with hundreds of members will
   produce a large candidate pool. FeedBuilder's `POOL_SIZE = 100`
   may need to grow or be configurable.
7. **Cross-tenant.** Members can be on the list under one tenant but
   posting in another. Feed should respect tenant scoping (only show
   content in the tenant the list lives in).
8. **Empty-state UX.** New list, no member content yet — what does
   the empty state say, and does it teach the user what tune-in means?
9. **HTML vs markdown.** Both, eventually. HTML first since
   user-lists ships markdown-first and the parity gap there is
   already on Phase 6's polish list.
10. **Sub-feeds.** Does each resource type get its own filter
    (notes-only, decisions-only)? Or is one mixed feed the only view?

## Explicit non-goals (subject to revisit when this plan is fleshed out)

- Push notifications when list members post (separate plan, much later)
- Email digests of list activity
- Aggregate engagement metrics on list feeds
- Cross-list deduplication when the viewer is on multiple lists that
  share members
- Real-time updates (Turbo Streams) — start polled/static

## Dependencies

- `user-lists` v1 must ship first (Phase 6 polish in progress).
- No new schema expected — `UserList` + `UserListMember` already
  give us the membership graph this feature needs.

## Initial sizing estimate

Roughly half a day to a day for a thin first cut (one feed endpoint,
HTML + markdown, owner-only on private lists, no ranking). The open
questions above are likely to expand that — particularly any
direction change to the tune-in semantic, which would ripple back
into the `user-lists` plan's copy and product framing.
