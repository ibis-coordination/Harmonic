# Notifications: Read State + System Improvements

## Context

Notifications currently have two effective states: **active** (shown in the inbox, counted in the badge) and **dismissed** (gone). There is no intermediate "read" state — no way to acknowledge a notification while keeping it in the inbox, and no way to revisit anything after dismissing it.

### Current architecture survey

**Data model** (two tables):
- `notifications` — shared content: `notification_type`, `title`, `body`, `url`, optional `event_id`, `tenant_id` ([app/models/notification.rb](app/models/notification.rb))
- `notification_recipients` — per-user, per-channel state: `channel` (in_app/email), `status` (pending/delivered/dismissed/rate_limited), `read_at`, `dismissed_at`, `delivered_at`, `scheduled_for` ([app/models/notification_recipient.rb](app/models/notification_recipient.rb))

**Key fact: `read_at` already exists in the schema and is entirely unused.** No code reads or writes it. No migration needed for the column itself.

**Misleading naming:** the `unread` scope (`notification_recipient.rb:14`) actually means "not dismissed" (`where(dismissed_at: nil)`). Everything called "unread" today — badge count, page title count, `NotificationService.unread_count_for` — is really an "undismissed" count.

**Conflated `status` field:** `status` mixes delivery lifecycle (pending → delivered, or rate_limited) with user interaction (dismissed). `dismiss!` writes both `status: "dismissed"` and `dismissed_at`. Queries filter on both inconsistently (controller uses `where.not(status: "dismissed")`, scopes use `dismissed_at: nil`).

**Flow:** `NotificationDispatcher.dispatch(event)` → type-specific handlers → `NotificationService.create_and_deliver!` → one `NotificationRecipient` per channel (per `TenantUser` preferences) → `NotificationDeliveryJob` (email send / mark delivered) → fires `notifications.delivered` event for user webhooks.

**Surfaces:**
- HTML inbox at `/notifications`, grouped by collective ([app/views/notifications/index.html.erb](app/views/notifications/index.html.erb))
- Markdown UI for agents with `dismiss` / `dismiss_all` / `dismiss_for_collective` actions ([app/views/notifications/index.md.erb](app/views/notifications/index.md.erb))
- Badge in top-right menu, polled every 30s via `/notifications/unread_count` ([notification_badge_controller.ts](app/javascript/controllers/notification_badge_controller.ts))
- Email channel, per-type preferences in `TenantUser` settings
- No `/api/v1` JSON endpoints for notifications

**Dedup/suppression:** chat_message notifications dedup against undismissed ones from the same sender (`NotificationService.notify_chat_message!`); tune_in suppresses repeats from the same actor while one is undismissed (`NotificationDispatcher.recent_tune_in_notification_exists?`).

**No retention:** dismissed rows accumulate forever; nothing purges them.

## Goals

1. Add a **read** state: unread → read → dismissed
2. Make "unread" mean unread (badge, counts, scopes)
3. Keep the dual interface (HTML + Markdown actions) in parity
4. Fix adjacent debt and gaps discovered in the survey (see "Other improvements")

## Design

### State model

Three user-facing states per in-app recipient row, derived from timestamps:

| State | Definition | In inbox? | In badge count? |
|-------|-----------|-----------|-----------------|
| Unread | `read_at IS NULL AND dismissed_at IS NULL` | Yes (highlighted) | Yes |
| Read | `read_at IS NOT NULL AND dismissed_at IS NULL` | Yes (muted) | No |
| Dismissed | `dismissed_at IS NOT NULL` | No | No |

- `status` stays a **delivery** field. We keep writing `status: "dismissed"` on dismiss for now (back-compat with existing queries); untangling it fully is a follow-up (see improvement 7).
- Dismissing implies reading: `dismiss!` also sets `read_at` if nil.
- Read state applies to `in_app` rows only; email rows are unaffected.
- Scheduled future reminders are neither unread nor read until due (existing `not_scheduled` logic carries over).

### How notifications become read (GitHub-style)

- **Click-through marks read.** Clicking a notification's link fires a mark_read POST before navigation (Stimulus, same pattern as dismiss).
- **Explicit "Mark all as read" buttons** alongside each dismiss button: global ("Mark all read" next to "Dismiss all") and per-collective (in each accordion header).
- **Visiting the inbox does NOT auto-mark everything read.** The badge clears when you've actually engaged, not merely glanced.

### Dismissed inbox behavior

Read notifications **stay in the inbox** until dismissed. This changes inbox semantics: today the list shows only undismissed items and every row renders with the unread highlight (`pulse-notification-unread` is hardcoded). After this change the inbox shows unread (highlighted, with indicator dot) and read (muted, no dot) together, newest first. Dismiss continues to remove rows.

### Dedup/suppression interaction

Chat and tune_in suppression currently key on `dismissed_at: nil`. With a read state, a notification you've *read* but not dismissed would still suppress new ones — meaning after you read "New message from X" and X messages again, no new unread notification appears and the badge stays at 0.

**Decision: suppression keys on unread, not undismissed.** A new chat message after you've read the prior notification creates a fresh unread row (the notification reappears at the top of the inbox). Same logic for tune_in: keep suppressing while an *unread* one exists; allow a new one once read or dismissed. Write tests for both paths.

### Chat: dismiss on view

Today the only automatic dismissal of a chat notification is *replying* (`dismiss_chat_notifications_from!` fires when you send a message). Merely viewing the conversation leaves the notification alive, which is why an active back-and-forth makes the badge flicker 1 → 0 → 1 every turn, and why a read-without-reply leaves a stale row.

**Decision: viewing the chat dismisses notifications from that partner.** The notification's job is to get you to the conversation; once you're looking at it, it's done. Replying-dismisses becomes a subset of viewing-dismisses.

- Server-side: `ChatsController#show` (the `/chat/:handle` page load) calls `dismiss_chat_notifications_from!` for the partner.
- Client-side: when a broadcast message arrives while the chat window is open and the tab is visible, the client POSTs a partner-scoped dismiss (new `dismiss_for_chat` action taking the partner handle — the client doesn't know recipient row ids) so no notification outlives a conversation you're watching live.

This makes the new-row-on-re-notify decision low-stakes: rows only accumulate when you genuinely haven't looked at the chat.

### Counts and badge

- `NotificationService.unread_count_for` switches to `read_at IS NULL` (plus existing in_app/not-scheduled/undismissed filters). Badge, page title, and md "Unread:" line follow automatically.
- No backfill needed for active rows: every undismissed row has `read_at = nil`, so badge counts are unchanged at rollout.
- Backfill dismissed rows with `read_at = dismissed_at` (data migration) so "dismissed implies read" holds historically.

### Index

Add a partial index supporting the hot badge query:
`(user_id, tenant_id) WHERE read_at IS NULL AND dismissed_at IS NULL AND channel = 'in_app'`
(Verify exact predicate against the final query shape; existing `(user_id, status)` index stays.)

## Implementation phases

Red-green TDD throughout: each step starts with failing model/controller/service tests.

### Phase 1 — Read state core (model + service)

1. `NotificationRecipient`: rename existing `unread` scope to `undismissed` (update the ~6 call sites); add real `unread` (`read_at: nil, dismissed_at: nil`), `read`, `mark_read!`, `read?`; `dismiss!` also sets `read_at` if nil.
2. Data migration: backfill `read_at = dismissed_at` where dismissed; add partial index.
3. `NotificationService`: `unread_count_for` → unread semantics; add `mark_all_read_for(user, tenant:)` and `mark_all_read_for_collective`; update chat dedup + `NotificationDispatcher.recent_tune_in_notification_exists?` to key on unread.
4. Tests: `notification_recipient_test.rb`, `notification_service_test.rb`, `notification_dispatcher_test.rb` (suppression behavior both ways).

### Phase 2 — Controller, routes, actions (both interfaces)

1. Routes + controller actions: `mark_read` (single), `mark_all_read`, `mark_read_for_collective` — mirror the dismiss trio, including describe/execute pairs and `ActionsHelper` registrations for the Markdown UI.
2. Inbox query: keep `where.not(status: "dismissed")` → switch to `dismissed_at: nil` for consistency; include read rows; expose per-row state to the views.
3. Markdown view: add state column (unread/read) and `mark_read` / `mark_all_read` action links; keep dismiss actions.
4. Chat dismiss-on-view: `ChatsController#show` dismisses notifications from the partner; add `dismiss_for_chat` action (POST, partner handle param) for the client-side path in Phase 3.
5. Tests: `notifications_controller_test.rb` for HTML, JSON, and md formats; `chats_controller_test.rb` for dismiss-on-view and `dismiss_for_chat`.

### Phase 3 — Frontend

1. `notification_actions_controller.ts`: `markRead` (fires on notification-link click + on explicit button), `markAllRead`; on success, swap row styling unread → read and decrement count (don't remove the row — that's dismiss).
2. `index.html.erb`: conditional `pulse-notification-unread` / read styling, indicator dot only when unread, "Mark all read" buttons (global + per-collective accordion header).
3. Chat dismiss-on-receipt: when the chat client receives a broadcast message while the tab is visible, POST `dismiss_for_chat` for the partner and emit `notifications:changed` so the badge refreshes.
4. Style guide check (`check-style-guide.sh`) for any new Pulse CSS.
5. Tests: extend `notification_badge_controller.test.ts` patterns with a `notification_actions_controller.test.ts` (or extend existing frontend tests) for the new actions.

### Phase 4 — Docs and polish

1. Update `/help/notifications` (see also improvement 1 below — fix the type-coverage gaps in the same pass).
2. Manual test checklist update: `test/manual/notifications/notifications_ui.manual_test.md`.
3. Playwright e2e: unread → click → read → dismiss happy path.

## Other improvements explored

Surveyed while reviewing; each is independent. Recommended disposition in brackets.

1. **Help doc gaps** [bundle into Phase 4]. `/help/notifications` documents 5 of 8 notification types — `participation` (votes, decision resolved, commitment joined, critical mass), `system`, and `trio_unavailable` are missing from both the trigger table and the channel-defaults table.

2. **Retention/purge** [small follow-up PR]. Dismissed recipient rows and their notifications accumulate forever. Add a scheduled system job (inherit per `check-job-inheritance.sh` rules) purging dismissed rows older than ~90 days, and orphaned `notifications` with no remaining recipients. Cheap, prevents unbounded growth.

3. **Real-time badge via Turbo Streams** [worthwhile, separate plan]. The badge polls every 30s per open tab — latency and constant background traffic. Broadcasting a Turbo Stream on recipient create/read/dismiss (Hotwire is already in the stack, Redis present) would make the badge instant and remove polling. Touches layout + delivery path; deserves its own doc.

4. **Aggregation/coalescing** [defer until it hurts]. Beyond chat/tune_in dedup, nothing coalesces — 5 comments on your note are 5 rows. "X and 2 others commented" style grouping is a real UX win for active tenants but a significant data-model change (group key, roll-up rendering). Not now.

5. **`/api/v1` notification endpoints** [do when an API consumer needs it]. The JSON API has no notifications resource; token-authenticated clients can't list or act on notifications. The md-action interface covers agents, so no current consumer is blocked.

6. **Email digest option** [defer]. Per-event emails only; a daily/weekly digest channel is a preferences + scheduled-job feature. No signal yet that anyone wants it.

7. **Untangle `status` from interaction state** [follow-up after read state settles]. End state: `status` ∈ pending/delivered/rate_limited (delivery only); interaction derived solely from `read_at`/`dismissed_at`. Requires migrating existing `status: "dismissed"` rows to `delivered` and sweeping all `status`-based filters. Mechanical but wide; doing it simultaneously with the read-state change would muddy both diffs.

8. **Web push / browser notifications** [out of scope]. Noted for completeness; service-worker infrastructure doesn't exist yet.

## Resolved decisions

- **Read-on-click** (not clear-badge-on-visit), with "Mark all read" buttons paired with each dismiss button.
- **Chat re-notify creates a new row** once the prior notification is read or dismissed; combined with dismiss-on-view, rows only accumulate for conversations you haven't looked at.
- **"Dismiss all" dismisses read items too** — it clears the inbox; "Mark all read" is the gentler sibling.
- **Purge window: 90 days** for the retention follow-up.
