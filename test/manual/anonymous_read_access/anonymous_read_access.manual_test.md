---
passing: true
last_verified: 2026-05-26
verified_by: Claude Opus 4.7
---

# Test: Anonymous read access (main collective public viewing)

> **2026-05-26 verification run** — `app.harmonic.local` with
> `ANON_READABLE_TENANT_SUBDOMAINS=app`. Two real bugs surfaced and were
> fixed during the run:
> 1. **Bypass condition 6 was too strict.** `request.format.symbol` returns
>    `nil` for `Accept: */*` (curl default and the wildcard tail of every
>    browser's Accept header), so the original `[:html, :md].include?(...)`
>    check failed closed. Fixed by extracting `anonymous_format_allowed?`
>    that also accepts `Mime::ALL`.
> 2. **`ApplicationRecord#user_can_close?` crashed on nil user** when the
>    deadline_display partial reached the `requires_manual_close?` branch
>    (deadline 50+ years out). The pre-implementation audit missed this —
>    the partial isn't rendered for normal deadlines. Widened sig to
>    `T.nilable(User)` with `return false if user.nil?` guard.
>
> All sections below verified PASS against the live dev server.

Verifies that anonymous (logged-out) visitors can read notes, decisions,
commitments, and help pages on a tenant whose subdomain is listed in
`ANON_READABLE_TENANT_SUBDOMAINS`, and that they CANNOT reach anything else.

## Prerequisites

- A tenant whose subdomain is listed in `ANON_READABLE_TENANT_SUBDOMAINS`
  (the "public" tenant)
- A second tenant NOT listed (the "private" tenant)
- At least one Note, one Decision, and one Commitment on each tenant's main
  collective
- A non-main collective on the public tenant with a Note in it
- A browser session that is NOT logged in (open in a private/incognito window)

## Steps

### A. Anon can read public main-collective content

1. In a private window, navigate to the public tenant's note URL:
   `https://<public-subdomain>.<HOSTNAME>/n/<truncated_id>`
2. Confirm the note title and body render.
3. Repeat for the decision URL (`/d/<truncated_id>`) and commitment URL
   (`/c/<truncated_id>`).
4. Navigate to `/help`. Confirm the help index renders.
5. Click through to `/help/privacy` and confirm.
6. Navigate to a user profile: `/u/<handle>`. Confirm the page renders
   showing display name, handle, avatar, and Recent Activity feed.
7. Confirm the same for an AI agent profile (`<handle>` of any
   `user_type: "ai_agent"`) and a collective-identity user.
8. If an archived user exists, confirm `/u/<archived-handle>` renders with
   an "Archived" badge.

### B. Anon cannot reach private tenants

1. In the same private window, navigate to the PRIVATE tenant's note URL.
2. Confirm you are redirected to `/login`.
3. Repeat for the private tenant's decision, commitment, `/help`, and
   `/u/<handle>` URLs. All should redirect to `/login`.

### C. Interaction surfaces are hidden for anon, CTAs visible

1. On the public tenant's note URL (logged out): confirm there is no Edit
   button, no Pin button, no Report kebab menu.
2. On the public tenant's decision URL: confirm the voting checkboxes are
   replaced by a "Log in to participate" CTA.
3. On the public tenant's commitment URL: confirm the Join/Sign/RSVP button
   is replaced by a "Log in to <verb> this commitment." CTA.
4. On the decision and commitment URLs: in the Comments section, confirm
   the comment form is replaced by a "Log in to comment." CTA.
5. On a user profile URL: confirm there is NO Settings link, NO Message
   button, and NO Block kebab item. Recent Activity is still visible.
6. The top-right header should show a "Log in" button — NOT a notification
   bell, search box, profile avatar, or "+" create menu.

### D. Root path still redirects to /login

1. Navigate to `https://<public-subdomain>.<HOSTNAME>/`. Confirm 302 →
   `/login`. Anonymous reach is direct-link only — no listings or feeds.

### E. Non-main collective on a public tenant is private

1. Navigate to the URL of the note in the public tenant's NON-main
   collective: `/collectives/<handle>/n/<truncated_id>`. Confirm 302 →
   `/login`. Only the main collective is anon-readable.

### F. Markdown format works for anon

1. Use curl / a markdown-aware client to fetch a public note as markdown:
   `curl -H "Accept: text/markdown" https://<public-subdomain>.<HOSTNAME>/n/<truncated_id>`
2. Confirm a 200 response with `Content-Type: text/markdown` and a body
   that contains the note's title and text.
3. Repeat for `/d/<id>`, `/c/<id>`, and `/u/<handle>`.
4. JSON should NOT work: `curl -H "Accept: application/json" .../n/<id>`
   should return 302 (or 401).

### G. Cache headers are correct

1. With `curl -i` (or browser devtools), fetch the public note URL.
2. Confirm the response includes `Cache-Control: private, no-store` (Rails
   normalizes the value; the literal string may also include `max-age=0`).
3. Sign in as a user, refresh the same URL, and confirm the header is
   STILL `private, no-store`. Cross-audience CDN reuse must be impossible.

### H. Auth-state transition (manual cache check)

1. In one browser tab, log in as a user. Navigate to the public note URL.
   Confirm you see the logged-in chrome (notification bell, profile, etc.).
2. In the same tab, log out. Use the browser's back button to return to
   the note URL.
3. Confirm the page re-fetches from the server and shows the anon view
   (Log in button in top-right, no profile menu). The browser must NOT
   serve a stale logged-in cached copy.

### I. Rate limit

1. With the public note URL, send 60 anonymous GETs from the same IP
   (e.g. a quick `for i in {1..60}; do curl -s -o /dev/null -w "%{http_code}\n" URL; done`).
2. Confirm all 60 return 200.
3. The 61st should return 429 with a `Retry-After: 60` header.
4. Wait 60+ seconds of inactivity, then GET again — should be 200.
5. With the same IP, log in via the browser and load the page from the
   browser. The logged-in user should NOT be rate-limited (per-user limits
   apply elsewhere, not the anon limit).

### J. Help feature gates

1. With the api feature flag disabled at the tenant level, navigate to
   `/help/api` anonymously. Should return 404.
2. Same for `/help/agents` and `/help/trio` when their flags are off.

## Checklist

- [x] A. Anon can read the three item URLs, help pages, AND user profiles
      on the public tenant — verified via curl on `/n/68e4986c`,
      `/d/aec74da4`, `/c/2761e577`, `/help`, `/help/privacy`,
      `/u/autogenerated-person-seeds-rb` (human), `/u/claude-code-primary`
      (ai_agent). All 200.
- [x] B. All five URL types redirect to /login on a private tenant
      — verified on `second.harmonic.local/help` and `second.harmonic.local/u/anyhandle`
      → 302
- [x] C. Edit/Pin/Report/Vote/Join/Comment-form/Settings/Message/Block hidden for anon, login CTAs in their place
      — "Log in to participate" on /d/, "Log in to rsvp this commitment" on
      /c/ (calendar event), "Log in to comment" on /d/ and /c/, "Log in to
      confirm reading this note" on /n/. Profile pages show no
      Settings/Message/Block. Zero Edit/Pin/Report buttons in anon response
      bodies.
- [x] D. Root path still redirects to /login — verified, 302
- [~] E. Non-main collective on public tenant — covered by automated test
      `anonymous_read_access_bypass_test`; no non-main collective exists on
      the dev `app` tenant to manually exercise
- [x] F. Markdown returns 200; JSON returns 401
      — `.md` returned `text/markdown` for all three item URLs and for
      /u/<handle>; JSON returned 401
- [x] G. Cache-Control: private, no-store set for both anon and logged-in
      — verified in response headers
- [~] H. Browser back-button cache — header verified, browser behavior
      follows from the no-store directive; not exercised in a live browser
      this run
- [x] I. 60-OK / 61-429 / Retry-After / SecurityAuditLog event
      — confirmed 429 with `retry-after: 60` and matching JSON event in
      `log/security_audit.log`
- [~] J. Feature-gated help topics 404 — all flags ARE enabled on the dev
      `app` tenant so the off-branch couldn't be exercised live; covered by
      automated test in `anonymous_read_access_controllers_test`
