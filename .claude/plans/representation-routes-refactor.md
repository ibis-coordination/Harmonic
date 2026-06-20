# Representation as a first-class resource

## Problem

A representation session is one concept, but today its URL surface is fragmented:

| What | Today |
|---|---|
| Your active reps | `/representing` (top-level magic verb) |
| User-rep session | `/u/{handle}/settings/trustee-authorizations/{grant_id}` |
| Collective-rep session | `/collectives/{handle}/r/{id}` |
| Start a user rep | `POST /u/{handle}/settings/trustee-authorizations/{grant_id}/actions/start_representation` |
| Start a collective rep | `POST /collectives/{handle}/represent` |
| End a session | `DELETE /representing`, `DELETE /collectives/{handle}/r/{id}`, or the `end_representation` action |

And the URL split flows into the human and agent UX:

1. **No canonical session URL.** An agent or human handed a session id has to know which lineage produced it before they can read it.
2. **Two start paths for one operation.** The `start_representation` action lives at a deep grant-relative path for user reps, and at a totally different surface for collective reps.
3. **Vocabulary thrash.** `represent`, `representing`, `representation`, `start_representation`, `stop_representing`, `stop_representing_user` — six verb forms for two conceptual operations.
4. **No "current reps" view.** A granting user can see grants they've created (and per-grant session history), but there's no consolidated "who is currently representing me?" page. The trustee likewise has no single "what reps am I holding right now?" page.
5. **Sessions can't be inspected from the grant page.** The session-history table on the grant page lists each session as a row, but the session-id link points back at the grant page itself. The activity log lives on `RepresentationSession` (via `representation_session_events`) but isn't reachable from human-facing nav.
6. **No notification when a session occurs.** The represented user has no inbox-style trail of "your agent did X on your behalf" — they have to navigate to the grant page and notice a new row in the session-history table.

## End state

**Principle:** the representation session is the first-class resource. It has one canonical URL regardless of origin, an inspectable activity log, and an end-of-session signal to the represented user. Trustee authorizations and collective roles are authorization sources — they enable representation but don't own the URL space.

Concretely:

- **`/representations`** — index page with two views on the same URL: "your sessions" (current user is the representative) and "sessions representing you" (current user is the granting user, or the identity user for collective reps). Replaces `/representing`.
- **`/representations/{id}`** — canonical show URL for any session. Renders session metadata + the full activity log from `representation_session_events`. Reachable from the grant page's session-history table.
- **`POST /representations/actions/start_representation`** — single start path. Body discriminates the target: `{grant_id: ...}` for user rep, `{collective_handle: ...}` for collective rep. Existing collective-rep start becomes a thin alias that calls into the same code.
- **`POST /representations/{id}/actions/end_representation`** — single end path. Replaces the three end variants.
- **End-of-session notification.** When a session ends, the represented user gets one notification summarizing what happened and linking to the show page. One per session, not per action.
- **Vocabulary settles on `represent` / `representation`.** `representing` / `stop_representing` go away; controller methods follow.

Trustee authorizations stay where they are (open question below).

## What the agent and human see after

Agent (MCP):

| Operation | Before | After |
|---|---|---|
| Find your reps | `fetch_page /representing` | `fetch_page /representations` |
| Read a session | path varied by lineage | `fetch_page /representations/{id}` |
| Start a user rep | `execute_action(/u/{me}/settings/trustee-authorizations/{g}/.../start_representation)` | `execute_action(/representations, start_representation, {grant_id})` |
| Start a collective rep | `execute_action(/collectives/{c}/...)` | `execute_action(/representations, start_representation, {collective_handle})` |
| End a session | varied | `execute_action(/representations/{id}, end_representation)` |

Granting user (human, browser):

- Visits `/representations` and sees both "your sessions" and "sessions representing you" — the latter is the missing "current reps" dashboard.
- Receives a notification when an agent's session ends, with a one-line summary and a link to the session show page.
- Clicks the link in the grant page's session-history table and lands on the session detail (activity log), not back on the grant page.

## Tasks

1. **Add the `/representations` resource.** New `RepresentationsController` (or extend the existing `RepresentationSessionsController`) for `index` and `show` at top-level paths.
2. **Unify the start path.** New `POST /representations/actions/start_representation` endpoint. Accepts `{grant_id}` for user rep and `{collective_handle}` for collective rep. Existing endpoints become aliases — same controller method, different routes.
3. **Unify the end path.** `POST /representations/{id}/actions/end_representation`. Existing end paths alias to it. Drop `stop_representing_user` / `stop_representing` from the public route surface.
4. **Index page content.** Two views on the same URL:
   - "Your sessions" — where `representative_user == current_user`. Active + recent.
   - "Sessions representing you" — where `granting_user == current_user` (user reps) or `identity_user == current_user` (collective reps). Active + recent.
   - Probably tabs or filters; design choice deferred to implementation.
5. **Show page content.** Renders session metadata (representative, represented, grant or collective, began/ended/expires) and the activity log from `representation_session_events` — every action with timestamp, actor, resource. The grant page's session-history table links here.
6. **Session-occurred notification.** When a session ends (`after_commit` on `RepresentationSession` when `ended_at` transitions from nil), enqueue a notification to the represented user. Body: one-line summary (count of actions, duration) + link to `/representations/{id}`. One per session. Add `representation_session` to the notification type whitelist in `notification.rb`.
7. **Update `ActionsHelper` action-route mappings.** The `start_representation` / `end_representation` action definitions point at the new canonical routes. Action names themselves stay stable.
8. **Back-compat redirects.** Old paths return 308 to the new canonical paths (308 preserves the method, matching the redirect pattern from the trustee-authorization rename). Drop after a long sunset window — out of scope.
9. **Drop the duplicate end variants from controllers + routes.** `stop_representing_user`, `stop_representing` — keep model-level logic, kill the controller methods and route entries.
10. **Update help docs.** `/help/representation` and `/help/agents/representation` reference the new canonical paths and the notification behavior. URL examples in code blocks update.
11. **Update the lifecycle test.** The MCP rep lifecycle test (`test_full_representation_lifecycle_via_MCP`) switches to the new canonical paths — same flow, fewer hops.

## Tests

- All existing rep tests (user-rep, collective-rep, end-of-session, expiry) continue to pass after the controller methods consolidate. Failures here mean the alias is wrong.
- `test/integration/representations_routes_test.rb` (new) — pins the new canonical URLs: `/representations` index renders both views, `/representations/{id}` show renders the activity log, unified start, unified end. Pins that an old path returns 308 to the new equivalent.
- The MCP lifecycle test exercises the canonical start path with both `{grant_id}` and `{collective_handle}` targets — one test class, two cases.
- New: notification fires once on session end, with the expected body and recipient.
- New: granting user's `/representations` view lists sessions where they're the granting user.
- Existing `api_representation_test.rb` flows continue green against the new paths (use the redirects).

## Open questions

- **Trustee authorizations in or out of `/settings/`.** Today they're at `/u/{handle}/settings/trustee-authorizations`. Moving them to `/u/{handle}/trustee-authorizations` (or `/u/{handle}/authorizations`) frames them as a first-class authorization, parallel to representation. Lean: keep under `/settings/` for this refactor; revisit later.
- **`POST /representations` vs. `POST /representations/actions/start_representation`.** First is REST-idiomatic; second matches Harmonic's action-route convention. Lean: action-route, for consistency.
- **Notification timing.** End-of-session (clear summary, deferred) vs. per-action (real-time, noisier) vs. per-summary-point (chunked). Lean: end-of-session, with the message including count + duration + link. Per-action would compete with the existing feed surfaces that already show each action.
- **Notify on session start too?** Probably no — start without any actions has no concrete consequence to record. The end-of-session notification with the action count captures both "a session happened" and "here's what was done."
- **Notification body shape for zero-action sessions.** If an agent starts and immediately ends with no actions, should the represented user still be notified? Lean: skip — nothing happened.
- **`/r` shortcut.** Harmonic uses single-letter shortcuts (`/u`, `/n`, `/c`, `/d`). `/r/{id}` would match, but `/collectives/{handle}/r/{id}` already exists. Lean: full `/representations` is fine; the resource is rarer than notes/decisions and clarity wins over brevity.

## Not in scope

- Changes to the `RepresentationSession` or `TrusteeGrant` models, schema, or authorization rules (other than the new `after_commit` for the notification).
- Changes to what triggers `RepresentationSessionEvent` creation (audit log behavior stays identical).
- Changes to the existing API header chain (`X-Representation-Session-ID`, `X-Representing-User`, `X-Representing-Collective`) — those continue to work as today.
- Auto-acceptance of principal → agent grants, or any other change to the grant-acceptance flow.
- Removing the redirects from old paths. Sunset is a separate decision after telemetry shows nothing's hitting them.

## Done when

- A representation session has exactly one canonical URL: `/representations/{id}`.
- The `/representations` index page surfaces both the actor's own sessions and sessions representing the viewer.
- The show page renders the session activity log; the grant page's session-history table links to it.
- The represented user gets one notification per session, summarizing the work done and linking to the show page.
- `start_representation` is one action at one path, with target discriminated by params.
- `end_representation` is one action at one path.
- The agent-facing MCP surface shows one shape for representation operations across all targets.
- Old URLs 308 to the new canonical equivalents; nothing breaks.
- The vocabulary in routes, controllers, and help docs settles on `represent` / `representation` consistently.
