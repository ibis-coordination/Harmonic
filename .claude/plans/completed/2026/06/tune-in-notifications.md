# Tune-in notifications

**Status:** Draft. Picks up the "Notifications on add" item that was
explicitly deferred in [user-lists.md](user-lists.md).

## Why

Tuning in to someone is a social act. Today the target has no signal
that it happened — they only find out by stumbling across their own
mutuals count going up, or noticing the new entry on the (closed,
unlabeled) Lists accordion of their own profile. This is also the
gesture most likely to spark reciprocity — without a notification, the
mutuals graph grows slower than it should.

Custom-list adds are also socially significant in the public case:
being added to "people I'm reading" or "designers I follow" is the
kind of thing the target wants to know about. Private and owner-self
adds are organizational tools and shouldn't notify.

## Scope decisions

Decided in conversation; pinning here:

1. **Who gets notified** — the *added* user (the target), not the list
   owner. Owners watching their list grow already see it on the
   members tab; they don't need an inbox ping for it.

2. **Which adds fire a notification:**
   - Tune-in list adds (primary): **always**.
   - Custom-list adds: **only when (a) list visibility is `public`
     AND (b) actor ≠ target.** Self-joins via `join_list` are silent
     — the actor is choosing to be on the list, they don't need to
     ping themselves. Private lists are owner-only organizational
     tools.

3. **New notification type `tune_in`** — not folded into
   `participation`. Users should be able to mute tune-in noise
   without losing decision/commitment activity. Two distinct copy
   shapes (tune-in vs. list-add) share one type since the
   preference-toggle reason is the same.

4. **Block-awareness** — already handled in
   `NotificationDispatcher.notify_user` via `UserBlock.between?`
   (symmetric, covers both directions). The new dispatcher case
   inherits the guard.

5. **No notification on remove/tune-out** — undoing a positive signal
   isn't notification-worthy. The `user_list_member.deleted` event
   still fires (Tracked emits it automatically) but the dispatcher
   ignores it. That also makes block-cleanup deletions harmless
   from a notification standpoint.

## Architecture

Three small pieces, all leaning on existing infrastructure:

### 1. `UserListMember` joins the `Tracked` concern

```ruby
class UserListMember < ApplicationRecord
  include Tracked

  # Tracked's actor resolution uses created_by; we have added_by.
  alias_method :created_by, :added_by
  ...
end
```

This gets us `user_list_member.created` and `user_list_member.deleted`
events automatically via `after_create_commit` / `after_destroy_commit`
callbacks. Actor is resolved from `added_by`. Importing/seed paths
already opt out via `Current.importing_data` in the Tracked concern.

### 2. `NotificationDispatcher` case

```ruby
when "user_list_member.created"
  handle_member_added_event(event)
```

Implementation:

```ruby
def self.handle_member_added_event(event)
  membership = event.subject
  return unless membership.is_a?(UserListMember)

  list = membership.user_list
  target = membership.user
  return if target.id == event.actor_id  # self-join: silent

  # Eligibility: primary always, custom only if public.
  return unless list.is_primary || list.public?

  actor_name = event.actor&.display_name || "Someone"
  if list.is_primary
    title = "#{actor_name} tuned in to you"
    actor_handle = event.actor&.tenant_users&.find_by(tenant_id: event.tenant_id)&.handle
    url = actor_handle ? "/u/#{actor_handle}" : nil
  else
    title = "#{actor_name} added you to their list \"#{list.display_name}\""
    url = list.path
  end

  notify_user(
    event: event,
    recipient: target,
    notification_type: "tune_in",
    title: title,
    url: url,
  )
end
```

The `user_list_member.deleted` event has no handler — fall-through in
the `case` is a no-op.

### 3. Preferences

Add `"tune_in" => { "in_app" => true, "email" => false }` to
`TenantUser::DEFAULT_NOTIFICATION_PREFERENCES`. Email defaults off:
tune-ins can be high-volume in active tenants and we don't want this
to be the type that pushes users to disable email entirely.

Add `"tune_in"` to `Notification::NOTIFICATION_TYPES`.

No preference-UI change needed unless the UI explicitly hardcodes the
list of types (rather than iterating
`DEFAULT_NOTIFICATION_PREFERENCES`). Verify during implementation.

## Copy

| Trigger | Title | URL |
|---------|-------|-----|
| Tune-in list add | `{actor} tuned in to you` | `/u/{actor_handle}` |
| Public custom-list add | `{actor} added you to their list "{list_display_name}"` | `/lists/{list_id}` |

URL choice rationale:
- Tune-ins → actor's profile. Lets the recipient one-click reciprocate.
- Custom-list adds → the list. The interesting thing is the context
  ("what list am I on?"), not the actor.

No body text — title carries the whole message.

## Tests

Model:
- `UserListMember.create!` emits a `user_list_member.created` event
  with actor=added_by, subject=membership.
- `UserListMember.destroy!` emits a `user_list_member.deleted` event.
- `created_by` returns `added_by` (concern contract).

Dispatcher:
- Primary-list add → in-app notification for target with
  "{actor} tuned in to you" + actor-profile URL.
- Public custom-list add by owner → notification with list-add copy
  + list URL.
- Private custom-list add → no notification.
- `join_list` self-add to a public list → no notification (actor ==
  target short-circuit).
- Tune-in across a block boundary → no notification (existing
  `notify_user` guard).
- `user_list_member.deleted` event → no notification created.

Integration:
- After tuning in to a user, that user's `/notifications` reflects
  the new in-app notification with the right title and URL.
- Notification dismiss flow works (reuses existing infrastructure).
- Email channel respects preference (default off; flip on and assert
  the delivery job is enqueued).
- Block-cleanup wiping primary-list memberships (existing UserBlock
  after_create callback) doesn't create "tune-out" notifications.

## Sizing

~Half a day total:
- ~1 hour: Tracked inclusion + alias + dispatcher case + types
  registration
- ~1 hour: dispatcher copy + URL resolution edge cases
- ~2 hours: tests (model emission, dispatcher branches, integration)
- ~30 min: help-doc updates (notifications + lists)
- ~30 min: browser manual verification of both surfaces

The simplification from leaning on Tracked is most of the win versus
the original "manual callback + custom event emission" sketch.

## Help doc updates

- `app/views/help/notifications.md.erb` — add `tune_in` row to the
  "What Triggers a Notification" table and the "Delivery Channels"
  table.
- `app/views/help/lists.md.erb` — short note in the tuning-in section
  that the target gets notified; ditto for the custom-lists section.

## Non-goals

- List-creation, list-rename, list-deletion notifications. Owner-side
  events, no clear target.
- Built-in automation rules for tune-in events. The events get emitted
  via the standard pipeline so users can write automations against
  `user_list_member.created` if they want, but no built-in.
- Counter-cache for "people who tuned in to me".
- Notification when a tune-in is removed. Quiet by design.
- Backfill historical notifications. Notifications start fresh from
  deploy.
- Dedupe rapid tune-out / tune-in re-pings (the chat-message dispatcher
  has this; defer unless users complain).

## Caveats / future cleanup

- The dispatcher's existing `when "commitment.joined"` case has no
  emission site anywhere in the codebase. It's aspirational dead code,
  not a precedent. This plan deliberately does not model after it.
- Webhook subject_url for `user_list_member.created` events is nil
  (UserListMember has no URL). Webhook consumers expecting a URL on
  every event subject would have to check for nil. Acceptable for v1.
- The Tracked-emitted `user_list_member.updated` event fires on any
  membership row save — but UserListMember has no updatable user-set
  fields in practice (only timestamps). If we ever add `last_seen_at`
  / similar, revisit whether `.updated` events become noisy.
