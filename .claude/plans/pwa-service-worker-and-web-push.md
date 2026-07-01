# PWA service worker and Web Push

Service worker first, then Web Push (push delivery and notification clicks run inside the SW). The prerequisite — silent re-auth via refresh tokens — shipped in June 2026 (`completed/2026/06/silent-reauth-refresh-tokens.md`). Note its actual shape: silent refresh is a `before_action` that runs on ordinary navigations, not a dedicated endpoint. A network-first navigation through the SW triggers it naturally; the SW needs no special auth handling beyond passing navigations to the network.

---

## Service worker

Instant cold opens, offline fallback page, and the runtime substrate for Web Push.

### Layout

- Author in TypeScript: `app/javascript/pwa/service_worker.ts`, with cache-strategy decisions (which bucket a request falls in, cache-name math) as pure functions so vitest can test them directly. Add a second esbuild entrypoint building to `app/assets/builds/service_worker.js` (the existing build script bundles only `application.ts`).
- Serve via `app/views/pwa/service-worker.js.erb`: injects `const CACHE_VERSION = "<sha>"` from `ENV["GIT_SHA"]` (the same source Sentry uses for its release tag) and inlines the compiled bundle below it. Must be served from the root path so the SW gets `scope: /`.
- Route: `get 'service-worker' => 'rails/pwa#service_worker', as: :pwa_service_worker, defaults: { format: 'js' }` — alongside the existing `rails/pwa#manifest` route.
- `app/javascript/pwa/register.ts` — imported from `application.ts`; registers `/service-worker.js` only when the layout marks the feature enabled (meta tag or conditional render).

Per-origin means per-tenant-subdomain: registration, caches, and (later) push subscriptions are all scoped to the tenant subdomain, the same way `manifest.json.erb` already documents per-subdomain install. Tenant cache isolation comes free.

On `activate`, the SW deletes any cache whose name doesn't match the current `CACHE_VERSION`. Clients pick up the new SW on the next navigation after deploy.

### Caching strategy

| Asset type | Strategy |
|------------|----------|
| CSS / JS / fonts / fingerprinted images | cache-first |
| HTML navigations | network-first, fallback to cached `/offline` |
| `/manifest.json`, `/service-worker.js` | network-only |
| API JSON, Turbo Streams, all non-GET, `/login`, `/auth/`, `/logout` | network-only (passthrough) |

HTML is deliberately not stale-while-revalidate — Harmonic content is real-time and user-scoped; brief loading state beats stale-feed surprise. Network-first navigations also mean silent re-auth fires exactly as it does without a SW.

`/offline` is a tiny self-contained route, pre-cached on SW install, shown when navigation fails.

Turbo's in-memory page cache is per-page-load and doesn't collide with the SW cache; Turbo Streams fall under network-only by content type.

### Feature flag and kill switch

Feature flags are per-tenant (`config/feature_flags.yml`, app → tenant cascade). Add a `service_worker` entry. Two behaviors hang off it:

- **Registration**: the layout only renders/enables `register.ts` when the flag is on for the tenant.
- **Kill switch**: the SW route always responds. Flag off → it serves an unregister stub (`self.skipWaiting()` + `registration.unregister()` + delete all caches) instead of the real SW. Turning the flag off *is* the kill switch for field installs — no separate mechanism.

### Tests

JS unit (`app/javascript/pwa/*.test.ts`, against the pure strategy functions):
- Static asset requests classify as cache-first.
- Failed HTML navigation falls back to `/offline`.
- Stale cache names are selected for deletion on activate.
- Auth paths, Turbo Streams, and non-GET requests classify as network-only.

Controller test: SW route serves the full SW when the flag is on, the unregister stub when off, `Content-Type: text/javascript` either way.

Manual: install desktop PWA, go offline, reload → offline page; deploy with new `CACHE_VERSION`, reload → old caches gone; flip flag off, reload twice → SW unregistered.

---

## Web Push

Notifications, reminders, and mentions appear on the lock screen the same way native app notifications do.

### Data model

```
WebPushSubscription
  user_id        bigint    (fk, indexed)
  endpoint       string
  p256dh_key     string
  auth_key       string
  user_agent     string
  device_label   string
  created_at     timestamp
  last_seen_at   timestamp
  revoked_at     timestamp (nullable)
  revoked_reason string    (nullable — "gone", "user", "admin")
  last_error_at  timestamp (nullable)
  last_error     string    (nullable — e.g. "Forbidden", "PayloadTooLarge")
```

- Unique on `(user_id, endpoint)` — the same browser endpoint can appear for multiple users (sequential logins on a shared device); each user gets their own row.
- **No `tenant_id` column, deliberately**: `ApplicationRecord`'s default scope keys off column presence, so omitting it makes the model user-global, like `User` and `OauthIdentity`. Add it to the models-without-tenant-scoping list in CLAUDE.md when implementing.
- Revocation mirrors `RefreshToken` (`revoked_at` + reason) instead of deleting rows — keeps delivery-failure forensics. Re-subscribing on the same endpoint un-revokes.

Subscriptions are issued to humans only (`user.human?`), defensively gated the way `issue_refresh_token_for!` is. AI agents already receive `notifications.delivered` / `reminders.delivered` webhooks; collective identities don't have personal devices.

### VAPID

- Generate a key pair; keys in env vars (`VAPID_PUBLIC_KEY`, `VAPID_PRIVATE_KEY`, added to `.env.example`) — the app manages secrets via env, not Rails credentials.
- Public key exposed in the layout head as `<meta name="vapid-public-key" content="...">` for the JS subscribe flow.
- `web-push` gem on the server.

### Subscription flow

`app/javascript/pwa/subscribe.ts` reads the meta tag, calls `pushManager.subscribe({applicationServerKey, userVisibleOnly: true})`, POSTs the result to a new user-relative endpoint (outside collective routing) that upserts `WebPushSubscription` by `(current_user.id, endpoint)`, touching `last_seen_at` and clearing revocation. Browsers occasionally rotate endpoints — re-subscription just creates the new row; the old one dies via `410 Gone` on next delivery.

### Delivery — a new channel, not a new hook

The integration point is the existing per-recipient **channel machinery** — the layer that already respects notification preferences:

1. Add `"web_push"` to `TenantUser#notification_channels_for` — per-type preference, gated on `user.human?` (like email) and on the tenant's `web_push` feature flag.
2. Add a `when "web_push"` branch to `NotificationDeliveryJob`, fanning out `WebPushDeliveryJob.perform_later(notification_recipient_id, subscription_id)` per active (non-revoked) subscription.

That covers, with zero extra wiring:
- **Dispatcher notifications** (mentions, replies, votes, participation) — `NotificationDispatcher.notify_user` already builds channels via `notification_channels_for`.
- **Reminders** — `ReminderDeliveryJob` delivers each recipient row through `NotificationDeliveryJob`.
- **Trustee authorizations** — `deliver_trustee_notification!` honors `notification_channels_for`.

Not covered: **chat messages** — `notify_chat_message!` hardcodes `["in_app"]` and dedups per sender. Include them: send a push per message when the pref is on (per-message push is the point of push; dedup remains an in-app inbox concern). This is the most push-worthy notification type.

Do **not** hook the `notifications.delivered` event — that's the webhook layer for agents, and reminders skip it entirely (they fire a batched `reminders.delivered` instead).

`WebPushDeliveryJob`:
1. Build payload: title, body (dispatcher already truncates to 200 chars), icon, badge, deep-link URL, `actions` array.
2. **Absolutize the URL**: `Notification#url` is a relative path; expand it against the notification's tenant subdomain + `HOSTNAME`. Subscriptions are per-user across tenants, so a subscription created on tenant A's origin can carry tenant B's notification — delivery is origin-agnostic; only the SW's focus-existing-window optimization is same-origin, and cross-tenant clicks fall back to `clients.openWindow`.
3. Encrypt and send via `web-push`.
4. `404`/`410` → revoke the subscription (`revoked_reason: "gone"`); `429`/`503` → retry with backoff; otherwise log and stamp the `last_error` fields.

### Notification clicks

SW `notificationclick` handler:
- Default click → focus an existing same-origin window at the deep-link URL, else `clients.openWindow`. Silent re-auth handles stale sessions on the resulting navigation.
- "Confirm read" action → the existing confirm-read endpoints (`POST /actions/confirm_read`, HTML confirm icon) are session + CSRF protected, and the SW has neither. Add a parallel signed-URL variant (single-use token in query string, scoped to the one note) the payload can carry.
- "Reply" action → open a focused window at the comment URL with the compose field active.

Action button support is uneven across platforms: iOS shows at most two and ignores text input; Android shows more. Don't design flows that depend on action buttons existing — they're a shortcut, not the primary interaction.

### iOS specifics

- iOS 16.4+ delivers Web Push only to home-screen-installed PWAs.
- Permission prompt requires a user gesture.
- Title + body are aggressively truncated — keep short.
- Badging: call `navigator.setAppBadge(unreadCount)` from the SW after push delivery.

### Settings UI

- "This device" card: subscribe / unsubscribe button. Lives on the user settings page next to the existing device list from the refresh-token work — push devices and trusted devices are the same mental object to users.
- Push device list: last-seen, device label; revoke individually.
- Channel preference: `web_push` column in the existing per-type notification preference matrix (alongside in-app and email).

### Tests

Model + job:
- Upsert on duplicate `(user_id, endpoint)`; re-subscribe clears revocation.
- Non-human user can't create a subscription.
- `notification_channels_for` includes `web_push` only when pref on + tenant flag on + human.
- `NotificationDeliveryJob` web_push branch fans out per active subscription, skips revoked.
- `WebPushDeliveryJob` happy path; URL absolutized to the notification's tenant host; `410` revokes; `429` retries.
- Reminder delivered through the push channel end-to-end (`ReminderDeliveryJob` → `NotificationDeliveryJob` → fan-out).
- Chat message pushes per message while the in-app row still dedups.

JS:
- Subscribe flow handles "permission denied" gracefully.
- Subscribe calls `getSubscription()` first; replaces stale subscriptions.

Manual: subscribe on phone, trigger a comment, see notification; tap action button; revoke from settings.

### Rollout

`web_push` entry in `config/feature_flags.yml` (`app_enabled: true`, `default_tenant: false`), tenant-level only. Monitor delivery rate, error rate by status code, time-to-delivery.

---

## Decisions

- **Opt-in moment**: settings page, plus a dismissible banner on the notifications page (highest-intent surface; the button click satisfies the user-gesture requirement). No auto-prompt on install. Banner shows only with the tenant flag on, a human user, no active subscription anywhere, and no prior dismissal (`HasDismissibleNotices` on TenantUser).
- **Subscription scope**: subscriptions are per-user (device registrations, cross-tenant); *whether* a tenant's notifications push is the per-tenant channel preference on `TenantUser` — the same split email already uses.
- **Audience**: human users only. AI agents stay on webhooks.
- **Chat messages**: included, pushed per-message; in-app dedup unchanged.

## Out of scope

- Lock-screen content privacy preference (show generic vs. full content) — surface later as a user setting if requested.
- Periodic Background Sync.
- Trusted Web Activity / Play Store distribution.
