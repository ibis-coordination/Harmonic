# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.44.0] - 2026-07-07

### Added

- **Per-cycle check-in hearts in the places sheet** (#418) — the places switcher opened from the header/tab bar now shows a filled/empty heart per collective for whether you've checked in this cycle, matching `/collectives`. The heartbeat lookup is extracted into a `Collective.with_heartbeat_for` scope using an EXISTS subquery (never multiplies rows, since the sheet renders on every page), reused by both the sheet and `/collectives`. The public-space globe row stays heartless.

### Removed

- **Pull-to-refresh PWA feature reverted** (#446, reverts #401) — the controller broke normal scrolling in the installed PWA, so it is removed entirely pending a future re-attempt.

## [1.43.0] - 2026-07-07

### Added

- **Decision audit chain records who acted on whose behalf** (#375, schema v3) — when a trustee or collective representative acts for someone, the chain now records both the principal and the representative, tamper-evidently. Five new columns mirror the actor triple plus a `representation_kind`; the representative token enters the v3 hash and scrubs on export like the actor's. `actor` still means principal, so receipts, tallies, and dedupe are unchanged, and v1/v2 chains verify as before. Receipts and the verify page show "by X on behalf of Y".
- **Pull-to-refresh for the installed PWA** (#401) — a standalone PWA has no browser chrome and no native overscroll refresh, so a Stimulus controller now tracks a downward drag from the top of the page and refreshes on release past the threshold (Turbo Drive when present, full reload otherwise). Active only when running standalone; inert in a normal mobile browser so it never doubles the platform gesture. Pairs with the mobile back button (#322).
- **Free accounts can buy LLM credits without a subscription** (#433) — billing-exempt free accounts have no active Stripe subscription, but LLM credits are a separate one-time purchase; the billing page and top-up action now gate on billing being enabled rather than an active subscription, and find-or-create the Stripe customer so a free account can attach a one-time payment.
- **Relative-time shorthand for decision/commitment datetimes via MCP** (#410) — `create`/`update` for decisions and commitments (and calendar-event `starts_at`/`ends_at`) now accept relative shorthand like `7d`/`3h`/`1w`, matching reminder notes. Already-time-like values pass through unchanged; unparseable strings fall to the model's own validation.

### Changed

- **Collective Explore nav links moved into a kebab menu** (#431) — Dashboard, Cycles, Backlinks, Representation, and Settings move from a standalone sidebar section into a ⋮ menu on the collective-info block, decluttering the sidebar. The Invite Member CTA stays visible. Only renders on the full pulse sidebar.
- **Collective feed default query no longer pins to the current cycle** (#430) — the default drops `cycle:this-week`, so the feed spans all cycles and only hides comments (`-subtype:comment`).
- **Search filter reference has a single source of truth** (#429) — the search-operator reference was hand-duplicated across `/help/search`, the `/search` syntax panel, and the markdown view, and had already drifted. All three now render from `SearchFilterReferenceHelper::SECTIONS`.
- **`@` is optional in the `collective:` search filter** (#356) — `collective:@my-team` and `collective:my-team` now behave the same, matching the user-handle filters.
- **Email styling aligned with the app style guide** (#439) — HTML mailers move from ad-hoc Bootstrap-ish colors and Arial to the app's design tokens (accent `#0969da`, GitHub-derived grays, system font stack). Centralized in the mailer layout, which also fixes latent double-wrapping (`layout "mailer"` around templates that rendered their own full `<html>` document).

### Security

- **`ACTION_DEFINITIONS` authorization is enforced at execute time** (#440) — the `authorization:` field on each action was consulted only when building markdown listings, never on execution, so an action with a tight rule but a thin controller shipped an unguarded endpoint. A new `ActionAuthorizationCheck` before-action now runs the rule on every `/actions/<name>` POST (HTML, REST, and MCP) before the controller executes, denying 403 when it rejects. The gate is additive — controller guards still run. Gate context resolves via order-independent `current_*` loaders rather than subclass-set ivars, closing a fail-open where resource- and user-target rules silently fell through. Reconciled several rules the gate surfaced (`cancel_reminder`'s undefined `:owner`, `close_decision`, trustee grant permissions, collective-identity membership).

### Fixed

- **Calendar event schedule is editable from commitment settings** (#321) — the settings form gained a Schedule section for `starts_at`/`ends_at`/`location` (the markdown/API path already supported these), with per-input timezone handling matching the create form. A bad edit (e.g. end before start) now redirects back with the validation message instead of a 500.

## [1.42.0] - 2026-07-06

### Added

- **Tenant admins choose which gateway models agents may use, with live rates** (#421) — a tenant-admin setting selects the gateway models offered to that tenant's internal agents, and the agent model selector now shows each model's per-token rate. A new `GatewayModelCatalog` looks up rates from the Stripe rate card, and all LLM model names are unified onto the gateway's dotted naming scheme (migration renames existing agent model aliases).
- **Mobile header back button for PWA use** (#322) — installed as a standalone PWA, Harmonic has no browser chrome and no back button; below 768px a back arrow now fills the header's upper-left slot and the logo is centered at every width. The arrow reveals only when `window.history` has an earlier entry, so no dead affordance shows on a fresh launch, on desktop, or without JS.
- **Members are notified when granted a collective role** (#340) — granting a member the admin, representative, or summarizer role now sends a `role_change` notification naming the role and who granted it (e.g. "Dan made you a representative of Team Alpha"), linking to the members page. Email defaults on, like system notifications; self-grants and revocations stay silent.
- **`media:` search filter** (#363) — `media:image` matches items with at least one embedded image and `media:text-only` matches items with none, across feeds and search. Implemented as an EXISTS subquery against `media_items` with no schema change or reindex. Documented in `/help/search`.

### Changed

- **Saved cards are reused across checkouts; billing copy no longer implies collectives cost money** (#414) — returning to checkout reuses a previously saved card instead of re-collecting it, and the free-state billing copy drops the word "free" and the implication that collectives are paid.
- **AI agents page copy** (#406) — "primary agent" becomes "principal" to match current terminology, notes that agents can be internal (Harmonic runners) or external, and mentions the MCP interface alongside the API.

### Fixed

- **Header nav stays usable while representing a collective** (#417, fixes #415) — representation keeps the add + profile controls visible but closes the represented user's private surfaces (chat/settings) and trims the profile menu, so you can navigate without reaching another user's private data.
- **The Stripe setup webhook check reports honestly** (#409) — the production setup script's webhook verification no longer treats a list failure or a near-miss endpoint URL as success; it distinguishes "couldn't list", "no match", and "matched".
- **Decisions and commitments can be created without a deadline via MCP** (#411) — the `create_decision` / `create_commitment` MCP actions now default a blank deadline to the same far-future "close manually" sentinel the HTML forms use (calendar events fall back to their start time), instead of tripping the deadline-presence validation. Deadline is marked optional in the action definitions.

### Tooling

- **`stripe-setup.sh` scripts the production Stripe setup** (#408) — a repeatable script for provisioning the production Stripe configuration.

## [1.41.0] - 2026-07-05

### Added

- **Multi-day calendar events from the create form** (#386, fixes #319) — the event form's Duration select gains a "Custom end time (multi-day)" option that reveals an explicit end datetime input. The model and API already accepted an arbitrary `ends_at`; now the HTML form can reach past its old 1-day duration cap.
- **Billed agents route LLM usage through the Stripe AI Gateway** (#407) — dispatch decides per task: agents on a Stripe-billing tenant with an active customer run through the gateway against prepaid credits, everyone else stays on LiteLLM. Dispatch refuses gateway tasks when the customer lacks credit ("Add funds at /billing") or the LLM-tokens pricing-plan subscription, so usage can never run unbilled, and unmappable models fail fast at dispatch instead of erroring mid-request. New `billing:gateway_health` rake task and request logging for observability.

### Fixed

- **The public space stays navigable while representing** (#405, fixes #383) — the home controller no longer bounces every request to `/representing` during a representation session, so you can view the home feed and reach the public composer to post an announcement as the collective. Landing on `/representing` when a session starts is unchanged.
- **Collective representation resolves across collective contexts** (#404, fixes #402) — acting under a collective representation session on a different collective or the public space no longer fails with "Invalid representation session ID"; the API path now looks the session up bypassing the collective default scope, mirroring the browser path.

## [1.40.0] - 2026-07-04

### Added

- **`my:` aliases in the search DSL** (#396, part of #373) — `my:mentions`, `my:notes`, `my:decisions`, `my:commitments`, `my:posts`, `my:voted`, `my:committed`, `my:rsvps`, and `my:mutuals`: pure sugar that expands to existing operators scoped to your own handle, composing (and being clamped by fixed page scopes) exactly as if you had typed them. Documented in `/help/search`.

### Changed

- **The collective rail is removed; the places sheet switches places at every width** (#398) — the rail's bare icons couldn't be labeled or dismissed, so desktop now opens the same places sheet the tab bar's Places tab opens on mobile, from a toggle at the left of the header. The logo is centered relative to the window on desktop.

### Fixed

- **Push notifications no longer silently die on iOS** (#399, fixes #397) — the service worker suppressed the notification banner while an app window reported itself focused; iOS counts each suppressed push as a silent-push strike and revokes the subscription after three, and suspended iOS PWAs can keep reporting focused from the app switcher. Every push now shows its notification, and a new page-load resync keeps the server's device row honest ("last seen" no longer freezes at subscribe time) and silently re-subscribes when permission is still granted but the platform dropped the subscription. A resync never revives an explicitly disabled device.
- **The bottom tab bar clears the iOS home indicator** (#400, fixes #395) — the safe-area padding was already there, but without `viewport-fit=cover` iOS reports every inset as zero. The elements the meta newly extends under hardware edges (body content, tab bar, places sheet) carry their own insets for the landscape notch.
- **iOS no longer autozooms into the feed bar's query field** (#394, fixes #392) — the mobile 16px minimum on text-entry controls is now an invariant (`!important`): the bare-element guard was losing to any class-based font size, which the feed bar's 13px query field did after 1.39.0.

## [1.39.0] - 2026-07-04

### Added

- **Collective rail** (#339, #370, issue #337) — a persistent Discord/Slack-style vertical rail on desktop: the globe (public space) on top, an aggregated chat entry beneath it, a square per collective with live unread badges, and a + entry at the bottom for browsing/joining/creating collectives. Sticky while the page scrolls; hidden under 768px.
- **Bottom tab bar on mobile** (#390) — the rail's mobile mirror under 768px: Home / Places / Search / Inbox / You. Places opens the places sheet and carries an aggregate unread dot, Inbox carries the total unread count, You opens the user menu upward. Auto-hides in lockstep with the top header.
- **Mobile places sheet** (#371) — the rail's destinations as labeled rows in a slide-over sheet, with the same live badges and current-place indicator.
- **`my:` viewer-state search filters** (#374) — `my:notified` (items behind your undismissed notifications — the inbox projected onto the feed), plus `my:unread` / `my:read` (read-confirmation state). Documented in `/help/search`. Reminder notifications now attribute to their note's collective, so they count in per-collective badges and bulk mark-read.
- **Badge click-through** (#381) — clicking a badged place opens its feed at `?q=my:notified` with a mark-all-read button, and reverts to the plain feed once the badge drains.

### Changed

- **Comment notifications surface as the comment** (#381) — `my:notified` shows the comment itself, and clicking opens the thread scrolled to the highlighted comment. The feed's comment exclusion is now visible, removable default-query text (`-subtype:comment`) instead of a hidden structural filter.
- **User menu slimmed; workspace entry added** (#390) — Chat and Collectives moved out (they live in the rail / tab bar / places sheet), lists are labeled "Lists", and the menu links to your private workspace. Workspace feeds drop the default query — the private zone is the only filter.
- **AI agent attribution reads "agent of"** (#367, fixes #364) — replaces "managed by" in author displays and agent profiles.

### Fixed

- **Collective representation works over markdown/MCP** (#366, fixes #365) — agents with the representative role can now discover and execute `start_representation`/`end_representation` on a collective's represent page. Hardened per security review (DB-backed concurrent-session guard, step-up-auth parity, end-capability checked up front), and agent-facing copy rewritten for the MCP context-block flow instead of HTTP headers.
- **Multi-paragraph comments no longer collapse onto one line** (#369, fixes #359) — comment bodies render as block markdown; inline rendering preserves newlines.
- **Mobile autozoom on focus** (#368, fixes #362) — all text-entry controls are 16px on mobile, so iOS Safari no longer zooms into small inputs like header search.
- **Feed bar handles long queries** (#390) — the query field wraps and grows instead of hiding the default behind horizontal scroll, and the heartbeat gate blurs the whole content column, filter bar included.

## [1.38.0] - 2026-07-02

### Added

- **Feeds are queries** (#358, implements #352) — every feed is a search with a fixed page scope, refinable with `/search` syntax. Feed pages declare fixed filters (rendered as non-editable tokens in the filter bar) plus editable refinements; terms that conflict with the fixed scope are overridden with a visible warning, never widened, and the parser now warns on invalid operator values instead of silently degrading to text. The home feed defaults to `list:tuned_in`, profile tabs and list feeds render through the search engine, and new notes/decisions/commitments index synchronously at commit so they appear in search-backed feeds immediately. The `scope:` operator alias for `visibility:` is removed.

### Changed

- **The feed is now a collective's default page** (#358) — the cycle dashboard moved to `/dashboard`. Workspace feeds are fixed to `visibility:private`; the heartbeat ritual carries over to the feed page.
- **Handles are case-insensitive and case-preserving** (#289) — `@Linus` and `@linus` resolve to the same identity and can't coexist, while display keeps the case the user chose (Postgres `citext`; no Ruby lookup changes needed).
- **Collectives and their identity users share one handle** (#290) — a collective's identity user now takes the collective's handle (previously a random hex string) and stays in sync on rename; the handle-availability check covers the unified namespace. Existing hex identity handles are backfilled.
- **Confirming read clears the associated notification** (#360, fixes #351) — confirm-read on a note also marks the mention/comment/participation notification that pointed there as read, so the badge clears without a separate dismiss step.

### Fixed

- **Device list shows real activity** (#350, fixes #346) — `last_used_at` only updated on token rotation, so the current device could show "Last used 7 hours ago" while in use. Authenticated requests now bump it (throttled), and the current device shows "Active now".
- **Unconfirmed comment read-confirm renders as a button** (#348, fixes #335) — the clickable read-confirm count on comments was styled like static metadata; it now gets the filled primary treatment matching the note-level Confirm Read button.
- **Settings page buttons were unstyled** (#349, fixes #344) — four buttons applied the `pulse-action-btn-primary` modifier without the base `pulse-action-btn` class and fell back to native browser styling.

### Infrastructure

- **Fast local Docker test loop** (#357) — new `docker-compose.dev.yml` bind-mounts the working tree so targeted tests re-run with no image rebuild; `docker-compose.test.yml` (CI-faithful runner) fixed to actually run tests.

## [1.37.0] - 2026-07-02

### Added

- **Service worker with offline support** (#347) — cached asset loads, an offline fallback page for failed navigations, and per-deploy cache busting. Per-tenant `service_worker` feature flag doubles as the kill switch: flag off serves a self-unregistering stub that cleans up field installs.
- **Web Push notifications** (#347) — mentions, replies, reminders, and chat messages on the lock screen. Opt-in via a dismissible banner on the notifications page or "Enable on this device" in settings; per-device list with revocation; `Push` column in the notification-preference matrix. Subscriptions survive session timeouts and end on explicit logout or admin account-security reset; no banners while the app is open and focused. Off by default behind the `web_push` tenant flag; requires `VAPID_PUBLIC_KEY`/`VAPID_PRIVATE_KEY`. iOS needs a home-screen install (16.4+).
- **Auto-hiding header** (#342, fixes #338) — the top header is sticky, slides away on scroll-down, and returns on scroll-up.

### Changed

- **Note Edit action moved into the kebab menu** (#332, fixes #325) — Edit (and table Settings) no longer clutter the primary action row.

### Fixed

- **New collectives default to API enabled** (#333, fixes #323) — the collective-local `api` flag started false, so API access was off per collective even under an API-enabled tenant. The tenant flag still gates access.
- **Emails send from "Harmonic \<address\>"** (#331, fixes #329) — inboxes showed a bare "noreply" as the sender name; display name overridable via `MAILER_FROM_NAME`.
- **Feed timestamps update live** (#330, fixes #301) — "X ago" on feed items froze at render time; now kept current client-side.

### Infrastructure

- **Production images bake in the commit SHA** (#347) — `GIT_SHA` is now a build arg, fixing the empty Sentry release tag and making the service worker's per-deploy cache invalidation actually fire (it previously resolved to `"dev"` in production).

## [1.36.0] - 2026-07-01

### Added

- **Collective member management UI** (#317) — per-member kebab menu on the members page for role changes (member/admin) and removal, routed through the action pattern so agents with admin can manage members too. Owner's admin role is protected.
- **MCP tool-call log** (#270, #308) — agent principals get a page listing their recent MCP tool calls with path, action, and intention.

### Fixed

- **Rotated refresh tokens inflated the device list** (#326, PR #327) — each silent refresh appeared as a new device. Rotation churn killed at the source and revocation now walks the token family; session-timeout regression from the cookie-persistence change also fixed.

## [1.35.0] - 2026-06-30

### Added

- **Silent re-authentication via refresh tokens** (#312) — expired sessions no longer bounce users to the login page. Login (with 2FA) issues a rotated, HttpOnly refresh cookie per device; a missing session cookie is silently exchanged for a fresh one. New **Devices** accordion on settings lists active devices ("Mac · Chrome", "iPhone · Safari") with per-device "Sign out" and "Sign out other devices"; revoked devices are kicked out on their next request. Refresh tokens are also revoked on logout, password change, 2FA disable, and the admin account-security panic button.
- **PWA manifest and mobile-friendly meta** (#309, #310) — `/manifest.json` served per-subdomain (each tenant installs as its own home-screen entry), 192/512 icons, apple-touch-icon, theme-color, mobile-web-app meta. Inputs bumped to 16px on mobile to block iOS focus zoom, plus tap-highlight / overscroll / `img max-width` cleanups.

### Fixed

- **@-mentions inside indented code blocks still notified** (#306, fixes #299) — the regex-based stripper missed 4-space/tab-indented blocks. Replaced with a `Redcarpet::Render::StripDown` subclass so the notification path uses the same tokenizer as the HTML renderer.

### Infrastructure

- **Local docker-compose test environment** (#311) — new `docker-compose.test.yml` runs the suite against an isolated Postgres/Redis pair; `docs/TESTING.md` documents it.
- **Bump yard 0.9.43 → 0.9.44** (#314).

## [1.34.1] - 2026-06-30

### Fixed

- **Markdown renderer SIGABRTed Puma under concurrent requests** (#307) — a shared `Redcarpet::Markdown` class variable raced across Puma threads whenever `MentionRenderer#normal_text` released the GVL during the DB lookup for `@`-mentions; the C extension's internal work buffer corrupted and the process aborted, taking every in-flight request to 502 until restart. Build a fresh `Markdown` instance per render call; allocation cost is unmeasurable next to the render work.
- **Confirm-read on summary notes never recorded** (#303, fixes #287) — summary notes overrode `Note#path` to `<parent>/summary`, so every action endpoint derived from `@note.path` (confirm-read, acknowledge, report, history) posted to a route that did not exist. Split into canonical `Note#path` (used to build action endpoints) and `Note#display_path` (used for friendly links).
- **Email notifications attempted SMTP to AI-agent placeholder addresses** (#302, fixes #294) — AI agents are created with `<uuid>@not-a-real-email.com` to satisfy User validations, but the notification path did not check `user.human?`. Guards added at three layers: delivery-time skip, channel selection drops `email` for non-humans, and preference writes coerce `email: true` to `false` for non-human users.

## [1.34.0] - 2026-06-29

### Added

- **Notification preferences UI** (#265) — per-type, per-channel checkbox matrix on the settings pages for both human users and AI agents, plus an `update_notification_preferences` markdown action with partial-merge semantics so an agent can flip a single channel without restating the whole matrix. The backend (`TenantUser#settings.notification_preferences`) already existed; this adds the surface to change it.
- **`@mention` profile links** (#291) — `@handle` in rendered markdown now links to the user's profile (`/u/<handle>`) when the handle resolves to a user in the current tenant; unknown handles stay plain text. Implemented as a final-pass walk over rendered HTML text nodes that skips `<a>`/`<code>`/`<pre>`, so mentions inside existing links or code are untouched.

### Fixed

- **Comment-reply notifications highlighted the wrong comment** (#292) — `?comment_id=` was built from the comment being replied to, so the highlight landed on the parent. Reply notifications now link to the reply itself. Also: the `comment-thread` controller now drops `?comment_id=` after the initial highlight via `history.replaceState`, so submitting a reply (which reconnects the controller) no longer re-runs the highlight animation on the original comment.

## [1.33.0] - 2026-06-28

### Added

- **`query_rows` surfaces row ids** (#283) — markdown output now includes each row's `_harmonic_row_id` as the first column so agents can obtain the `row_id` needed by `update_row` / `delete_row` for rows they didn't just add. The rendered note body and HTML table still omit it.

### Changed

- **Internal table-row keys renamed to `_harmonic_` prefix** (#283) — `_id` / `_created_by` / `_created_at` → `_harmonic_row_id` / `_harmonic_created_by` / `_harmonic_created_at`, freeing the single-underscore namespace for user data (CSV imports with column names like `_id` or `_source` are now allowed). Only the `_harmonic_` prefix is reserved. Data migration backfills existing table notes; rendered note bodies are unaffected.

## [1.32.0] - 2026-06-28

### Added

- **GitHub-style markdown Write/Preview toggle** (#258) — markdown text fields now have a Preview tab that renders server-side via `MarkdownRenderer` (same sanitization, reference linking, and header shifting as the posted result). New `POST /markdown/preview` endpoint (auth-required, length-capped, inline mode for comments), `markdown-preview` Stimulus controller, and a reusable `shared/_markdown_editor` partial wired into the new-note form and the Pulse comment form.

### Changed

- **Search `scope:` filter renamed to `visibility:`** (#272) — standardizes on the same term used by markdown/MCP actions. Renames the DSL operator, internal params, and `SearchQuery` methods. `scope:` stays as a backward-compatible operator alias so existing links and saved queries keep working; help docs document `visibility:` only.
- **Table-note cells render through the markdown renderer** (#279) — HTML view previously emitted raw text, so links inside a cell showed as literal `[text](url)` even though the markdown view already rendered them. Cells now run through the existing `markdown_inline` helper so the HTML view matches the markdown view; all calculation/aggregation stays server-side in `NoteTableService`.
- **Cleanup stray "studio" references** (#278) — the e2e setup task's console output and a few test-fixture handles still said "studio" after collectives were renamed. Switched to "collective". The `default_studio_settings` backward-compat fallback on `Tenant` is deliberately kept (data-migration decision, out of scope).

### Fixed

- **Intra-word underscores no longer rendered as italics** (#269) — terms like `a_b c_d` were being parsed by Redcarpet as emphasis, producing `a<em>b c</em>d`. Enabled the `no_intra_emphasis` extension (already supported by Redcarpet 3.6.0) so intra-word underscores stay literal; single underscores delimiting a word still render as italics.
- **Search-box font regression** (#276) — the search bar referenced `--fontStack-monospace` before that variable was defined, so it rendered in the inherited proportional UI font. When the variable was defined (4f9e0adc, Jun 11) the input silently switched to the wider monospace font, overflowing the fixed-width box. Dropped the `font-family` declaration to restore the prior proportional rendering.
- **Incomplete capabilities list on the trustee-authorization form** (#260) — the new-grant form listed a stale, hand-maintained subset of 17 actions. It now renders the full grouped capability list, mirroring the agent capability form, from a shared source of truth (`CapabilityCheck::TRUSTEE_GRANTABLE_GROUPS`), so the form and `TrusteeGrant::GRANTABLE_ACTIONS` can no longer drift. Excludes the rep-lifecycle / trustee-admin groups (which gate the representation relationship, not in-session behavior) and keeps collective presence (`send_heartbeat`).

## [1.31.0] - 2026-06-27

### Added

- **Summaries on notes/decisions/commitments** (#263) — per-resource summary as a Note with subtype "summary", served at `<parent>/summary`. New `summarizer` role on `CollectiveMember` gates authorship, with a collective-level `any_member_can_summarize` toggle (off by default, locked off for private workspaces and chat collectives); `add_summary` upserts (mirroring `add_statement`). Markdown surface shows a section header plus a link to the summary's own page — the parent no longer inlines summary content. `subtype:summary` / `subtype:statement` documented as search filters across `/help`, search markdown, and search HTML.
- **Public-write guardrail on AI agents** (#257) — per-agent `allow_public_writes` toggle (off by default for restricted agents). Writes whose resolved audience is `public` (the tenant main collective, plus tenant-scoped actions like `tune_in`) return 403 `public_writes_disabled` unless the owner enables the toggle. Discovery on the same routes hides those actions in the `actions:` frontmatter to match enforcement. Gate runs on every restricted-agent write regardless of dispatch path; declared-visibility validation in MCP remains MCP-only. Closes #256.
- **Trustee-authorization notifications** (#255) — `offered` notifies the trustee, `accepted` notifies the granting user. Inbox + (preference-gated) email + `notifications.delivered` webhook scoped to the recipient's private workspace, so bridge agents receive them. `declined`/`revoked` deliberately do not notify — the actor already knows and the counterparty sees state on the grant page. `TrusteeGrant.offer!` joins `accept!`/`decline!`/`revoke!` so all four lifecycle verbs live on the model.

### Changed

- **Decision verification UI polish** (#254) — the audit-chain icon is always the chainlink octicon (no longer swaps to a `verified` badge after the beacon is drawn); the winner-row highlight in `_results` is now gated on `beacon_drawn?` in addition to `closed?`, so random tiebreakers don't visually crown a winner before the beacon resolves.

### Fixed

- **N+1 vote query in decision options partial** (#262) — `_options_list_items` called `@votes.where(option: ...).first` per option (Sentry 7565374452: 19 queries, 29% of the transaction). Load the participant's votes once and index by `option_id`.

### Infrastructure

- **harmonic-bridge npm publish uses Trusted Publishing** — the publish workflow exchanges a short-lived OIDC token for npm credentials via the `id-token: write` permission; no more shared `NPM_TOKEN` to rotate.

## [1.30.0] - 2026-06-24

### Added

- **harmonic-bridge** (#251, #252) — a self-hosted daemon that wakes external agents on Harmonic notifications. Operators install it on their own host, click "Connect this agent" on the agent's settings page, paste one command on the host, and the bridge runs whatever `wake_command` they've configured (Claude Code, Codex, a Python script — their call) for every event.

## [1.29.1] - 2026-06-21

### Fixed

- **Chat-message notification webhooks fire on every message** (#250) — in-app dedup was also suppressing the `notifications.delivered` event when an unread notification already existed from the same sender, so external receivers (notification webhooks driving agents/integrations) only woke on the first message in an unread streak. Event firing decoupled from in-app dedup: every chat message now fires its own event; the in-app inbox still consolidates to one row per unread sender.

## [1.29.0] - 2026-06-21

### Added

- **MCP Connect flow** (#243) — one-click "Connect a client" on the agent settings page mints an MCP-only token and renders a paste-ready install action for 10 harnesses (Claude Code, Claude Desktop, Cline, Codex, Codex Cloud, Continue, Cursor, Goose, Hermes Agent, OpenClaw). Per-harness setup guides under `/help/mcp/connect/`. MCP server name scoped by agent handle so multiple agents coexist in one config. Tokens carry a `client_name` label in the agent settings tokens table. `harmonic://context` is now per-agent (identity, principal, identity prompt, listable collectives), and `/help/agents/getting-started` covers orientation.
- **Required action-context block on agent `execute_action`** (#244) — MCP calls must declare `context: { identity, visibility, intention }`. The server validates each field against ground truth before dispatch and returns direction-aware corrective hints on mismatch. Each action carries an `:visibility` tier (`:public | :private | :shared | :by_collective`); `EXPECTED_VISIBILITY` lock-in pins all 85 action tiers against drift. MCP-only; humans on REST/markdown unaffected.
- **Representation via MCP context** (#245) — agents declare `representation_session_id` + `identity.acting_as` (writes) or `identity.viewing_as` (reads) on `execute_action`/`fetch_page`. The endpoint translates to the existing rep header chain; all-or-nothing rule rejects partial declarations. No model changes. New `/help/agents/representation` covers the mechanics.
- **Unattached-session warning** (#246) — when an open rep session isn't attached to the current request, the markdown layout names the session id, represented handle, expiry, the context fields to attach it, and a working end path.
- **Capability-dependency warning on the grant show page** (#249) — when the trustee is an AI agent missing any of `accept_trustee_authorization`/`start_representation`/`end_representation`, the page links to the agent's settings. Closes the silent-fail path where the agent would 403 on its first `accept_trustee_authorization`.

### Changed

- **Step-up reverification on agent creation + Connect-token mint** (#243) — `AiAgents#new`/`#execute_create_ai_agent`/`AiAgentConnect#create` gated under the `ai_agents`/`api_tokens` scopes, matching the existing token mint gate. Connect controller also rejects internal AI agents (was UI-only).
- **Self-acting API calls succeed under an open rep session** (#246) — dropped the request-entry gate that 409'd any unattached request. One-directional and blocked legitimate self-acting reads; the header is now the sole switch to trustee identity. Open sessions surface via the unattached-session warning.
- **Rep session lifetime 24h → 1h** (#246), consolidated as `RepresentationSession::SESSION_LIFETIME`.
- **Singleton-active-session enforced at start** (#246) — `ApiHelper#start_user_representation_session` is the single user-rep funnel; rejecting there covers all start paths. Error names the existing session id and the end recipe.
- **"trustee grant" → "trustee authorization"** (#246) — user-facing copy, URL paths (`/settings/trustee-grants/*` → `/settings/trustee-authorizations/*`), and action names (`accept_trustee_grant` → `accept_trustee_authorization`, same for `decline`/`revoke`/`create`). Old URLs and action paths 308-redirect. Internal symbols unchanged.
- **Grant show-page action listing is state-aware** (#249) — `accept`/`decline`/`revoke`/`start_representation`/`end_representation` only appear when applicable to the grant's state and viewer's role. Lifecycle actions moved from `actions:` to `conditional_actions:`; `actions_index_show` rewired so both surfaces stay in sync.
- **Note history line preserves the representative under rep** (#249) — History reads "Claude on behalf of Dan created this note", matching the metadata block above. Was "Dan created this note".
- **Auto-read-confirmation under rep records the representative** (#249) — via `RepresentationContext` set by `ApplicationController` alongside `@current_representation_session`. The represented user is no longer pre-marked as having read notes the agent created on their behalf.

### Removed

- **Redundant `search` action from `ACTION_DEFINITIONS`** (#244) — the MCP `search` tool is a separate dispatch path.

### Fixed

- **`/representing` markdown crash** (#246) — `UnknownFormat` on MCP fetches; the documented agent discovery path was unreachable.
- **`/whoami` empty parenthetical under rep** (#246) — template referenced `@current_human_user` (browser-only).
- **"Pending Requests" wording inverted the trustee relationship** (#246) — the listing read as if the trustee was asking; the granting user offers authority.
- **`McpToolCallLog#api_token_id` nullified on token destroy** (#244) — was leaving dangling FKs.

### Infrastructure

- **Dependency bumps** — vite 8.0.5 → 8.0.16 (#241), form-data 4.0.5 → 4.0.6 (#242), undici 8.1.0 → 8.5.0 in `/agent-runner` (#247), bundler group (#248).

## [1.28.0] - 2026-06-15

### Added

- **Hosted MCP server** (#238) — `POST /mcp` (spec rev `2025-11-25`) exposes `fetch_page`, `execute_action`, `search`, `get_help`, and a `harmonic://context` resource to AI agents over Bearer auth. Tools dispatch through `MarkdownUiService` so MCP grants no new privileges. New `/help/mcp` page.
- **MCP audit log** (#238) — every call lands in `McpToolCallLog` with schema-allowlist arg redaction.
- **Layered MCP rate limits** (#238) — per-token burst + sustained, per-principal, and per-tenant caps with `Retry-After` and `SecurityAuditLog` trail. 256 KiB request / 1 MiB response body caps.
- **`mcp_only` token mode** (#238) — agent tokens can be locked to `/mcp`; direct REST/markdown returns 403. Default-checked on agent and token creation forms.
- **Per-call resource attribution** (#239) — `McpToolCallResource` records resources touched by `execute_action`, linked to the originating `McpToolCallLog`. Dual-writes legacy `AiAgentTaskRunResource`.
- **Step → tool-call deep link** (#240) — `AgentSessionStep` gains a nullable FK to `McpToolCallLog`; cross-task-run references rejected at the endpoint.
- **Auto-confirm read on creation and commenting** (#235) — creating a note confirms the creator on their own note; commenting confirms the commenter on the parent note. Closes the markdown-UI side of the HTML UI's gating.

### Changed

- **Internal agent-runner routes through `/mcp`** (#240) — `McpClient` replaces direct `navigate`/`executeAction`; internal and external agents share one tool surface and one audit log. Step types renamed `navigate → fetch_page`, `execute → execute_action` (legacy strings preserved). Per-task `Retry-After` budget (60s). Runner-issued tokens are `mcp_only`.
- **All agent capabilities exposed in forms** (#237) — agent forms were hardcoding 23 of 53 grantable actions, silently denying chat, tables, tune-in, reminders, and more. Groupings consolidated in `CapabilityCheck::AI_AGENT_GRANTABLE_GROUPS` with drift tests; sensitive groups default-unchecked.

### Removed

- **Legacy stdio `mcp-server/` package** (#238) — clients connect directly to hosted `/mcp`.

### Security

- **MCP rejects non-`ai_agent` tokens** (#238) — human and collective_identity tokens get a 403 naming the user's `user_type` and handle.

### Fixed

- **Read-confirmation upsert clobbered `is_creator`** (#235) — the upsert hash now sets `is_creator` explicitly; exposed by the new auto-confirm path.
- **Flaky collective-import event-order assertion** (#236) — sort `actor_user_id`s before comparing.

## [1.27.0] - 2026-06-12

### Added

- **Explicit invite acceptance** (#233) — invite links route to a confirmation page that joins the tenant and collective atomically on accept, instead of silently joining during login. Acceptance records an `invite.accepted` event for the upcoming collective-policies feature.
- **Handle selection on signup** (#233) — choose your handle (separate from display name) when accepting an invite, with normalization and graceful handling of taken handles.
- **Independent handle field for AI agents** (#233) — agent creation takes an optional handle distinct from the name; generic names auto-disambiguate and taken handles return a friendly error.
- **Mobile-friendly 2FA setup** (#233) — small screens lead with an `otpauth://` deep link and copyable secret instead of a second-device QR code.

### Changed

- **2FA challenged at login for all OAuth providers** (#233) — previously only email/password prompted, letting a `require_2fa` policy be bypassed by provider choice.

### Fixed

- **Billing exemptions and subscription edges** (#230) — exemption toggles repaired for users and added for collectives; `billing_exempt` honored on humans; cancel-at-zero prorates and finalizes the final invoice; `POST /billing/setup` guarded against duplicate subscriptions; checkout webhook activates pending resources; `BillingReconciliationJob` scheduled daily.

### Infrastructure

- **Dependency bumps** — puma 7.2.1 (#234), npm_and_yarn group (#232), bundler group.

## [1.26.0] - 2026-06-11

### Added

- **Notification read state** (#228) — unread → read → dismissed, with mark-read actions in both interfaces; the badge counts only unread. Chat notifications dismiss on viewing the conversation; rows dismissed >90 days are purged daily.
- **Participation notifications** (#229) — commitment joins and critical mass, decision votes (deduped per voter while unread), and decision resolution now notify. These were documented but never fired: the dispatcher handled five event types that nothing emitted.

### Changed

- **Comments emit `comment.*` events instead of `note.*`** (#229) — automation rules can distinguish comments from top-level notes. Existing `self_or_reply` rules (including Trio's) were migrated to match both; bare `note.created` rules no longer fire for comments.
- **Notification suppression keys on unread, not undismissed** (#228) — a new chat message or re-tune-in after the prior notification was read notifies again.

### Documentation

- **Docs refresh** (#229) — AUTOMATIONS.md rewritten (current event vocabulary, corrected webhook signing scheme, notification-webhooks and billing-gate sections); smaller fixes across ARCHITECTURE.md, USER_TYPES.md, STYLE_GUIDE.md, DEPLOYMENT.md, and several help topics.

## [1.25.0] - 2026-06-10

### Infrastructure

- **Rails 7.2 → 8.1** (#226) — bumped rails, turbo-rails 2.x, view_component, jbuilder, and related Hotwire/Sentry/factory_bot gems. `config.load_defaults 8.1` flipped; opted out of `executor_around_test_case` so CurrentAttributes still reset between requests in integration tests. Qualified an ambiguous `scheduled_for` join column in `NotificationRecipient.not_scheduled`.
- **Bundler bumps** (#227) — faraday 2.14.1 → 2.14.2, jwt patch.

## [1.24.0] - 2026-06-10

### Added

- **Profile page tabs** (#225) — Posts / Activity / Lists / Common Collectives replace the old accordions. Posts is the default; Activity covers non-post notes plus decision/commitment creations.
- **Bio, location, website on `TenantUser`** (#225) — per-tenant profile fields, edited from settings, rendered above the tabs and inline in markdown.
- **Editable profile picture for the owner** (#225) — reuses the existing cropperjs modal. Non-owner viewers get a circular-crop lightbox instead.
- **Tune-in button on list members, mutuals, and tune_in notifications** (#225) — hidden when viewer == target or either side blocks. Backed by a batch state service so each surface renders in O(1) per row.
- **"📅 Joined &lt;Month YYYY&gt;" in the profile header** (#225), from `tenant_user.created_at`.
- **`TabsComponent`** (#225) — reusable ViewComponent; the user-lists page and the Note/Decide/Commit nav both use it now.

### Changed

- **Profile links route to the top-level `/u/:handle`** (#225) on the collective members and team views (were collective-scoped). `CollectiveMember#path` removed.
- **`User` enforces a backing Collective for `collective_identity` users on update** (#225) — orphan state was previously a silent crash far from its root cause.

### Removed

- **Social Proximity section on `/u/:handle`** (#225) — UI-only removal. The calculator, `User#social_proximity_to`, and `FeedBuilder`'s proximity ranking path remain for future use.

## [1.23.1] - 2026-06-07

### Fixed

- **N+1 on note show page** — `CollectiveMember#user` and `TenantUser#user` back-populated the user's cached membership with `||=`, which invoked the getter and fired a SQL query per team member iterated in `Collective#team` / `Tenant#team`. Replaced with a guarded direct setter.
- **Note show loaded the full team just to render "N members"** — `NotesController#show` assigned `@team = @current_collective.team` (up to 100 user rows) solely so the sidebar could call `@team.count`. Added `Collective#member_count` (one COUNT query) and dropped the `@team` load from `notes#show`.

## [1.23.0] - 2026-06-07

### Added

- **Notification webhooks** (#223) — one webhook per recipient (human or external agent) forwards every notification (@-mentions, comment replies, chat messages, reminders) to a user-set HTTPS URL. Managed at `/u/<handle>/webhook` and `/ai-agents/<handle>/webhook`; signing secret revealed once at create/rotate (HMAC-SHA256 over `"<timestamp>.<body>"`); inline test delivery; last-10 delivery history. For humans, this is part of the existing $3/mo personal programmatic-access charge that already covers API tokens — having both still adds +1 to billable quantity, not +2.
- **`automations` tenant feature flag** (#223) — gates the YAML automations authoring UI. Existing rules continue to fire when off; only authoring is gated. Data migration backfills `automations = true` for tenants with existing rules.
- **Split `ai_agents` feature flag into `internal_ai_agents` + `external_ai_agents`** (#222) — tenants can enable external API-token-based agents without standing up the internal Task Runner (and vice versa). Migration copies the existing `ai_agents` value into both new keys so every tenant's capability set is preserved.
- **Canonical AI-agent settings page** at `/ai-agents/<handle>/settings` (#222) — single surface for profile image, name, handle, identity prompt, mode, model, capabilities, collective memberships, API tokens. `/u/<agent>/settings` redirects here (HTML and MD).

### Fixed

- **OAuth signup avatar upload `IOError: closed stream`** (#223) — `image.attach(io:)` on an unpersisted `User.create!(image_url: ...)` deferred the upload to an `after_commit` callback, by which time the IO was closed. Upload the blob synchronously and attach the already-uploaded blob.
- **External agents could submit the "Run task" form** (#222) — the runner would immediately fail the task and the user landed on a failed-run page. `run_task`/`execute_task` now 404 for external agents; the show page hides "Recent Task Runs" for them.
- **New-token plaintext lost on AI-agent create** (#222) — `execute_create_ai_agent` redirected to show, destroying `@token` before the view could display it. Now renders `show` directly when a token was just minted.
- **Admin Stripe subscription cancelled on agent create** (#222) — `sync_subscription_quantity!` interpreted admins' always-zero `billable_quantity` as "all resources removed" and cancelled the admin's subscription. The sync now no-ops for `sys_admin` / `app_admin`.
- **Admin agents marked `pending_billing_setup`** (#222) — admins lack `stripe_customer` by exemption, which previously short-circuited new agents into the pending state. `execute_create_ai_agent` now uses `requires_stripe_billing?` to decide, matching the early-redirect predicate.
- **AI-agent create form forced `confirm_billing` checkbox even for billing-exempt admins** (#223) — `$3/month` notice and confirm checkbox now hidden for `app_admin` / `sys_admin`.
- **AI-agent create form was Turbo-enabled and broke on cross-origin Stripe Checkout redirect** (#223) — `data: { turbo: false }` plus PRG-with-flash for the plaintext token, so the URL bar lands on the agent show page instead of `/actions/create_ai_agent`.
- **500 on AI-agent handle collision** (#222) — `RecordNotUnique` now becomes a friendly `flash[:alert]`.
- **AI-agent index "Collective Memberships"** showed auto-created chat collectives (#223) — filter switched from `!private_workspace?` to `listable?` so only standard collectives appear.
- **Invisible `flash[:error]` on AI-agent redirects** (#222) — application layout renders `:notice` and `:alert` only; switched call sites that were silently dropping their error messages.
- **`api_tokens/new` said "Identity: you" / "associated with your account" regardless of owner** (#222) — identity badge and hint now branch on `@showing_user`, so AI-agent owners see the agent's identity.

### Security

- **`AutomationDispatcher` no longer gates rule matching on the AI-agents flag** (#222) — previously, disabling AI agents disabled webhook delivery too, even though webhook rules don't need a runner. The gate now lives in `AutomationExecutor` where `trigger_agent` actually dispatches.
- **Agent mode is immutable post-create** (#223) — `User` rejects changes to `agent_configuration["mode"]` after the agent exists; closes a path where an internal-only agent could be flipped to external (or vice versa) after billing/quota decisions had been made.

## [1.22.0] - 2026-06-05

### Added

- **Lists** (#220) — first-class user-defined groups of users. Every user has a primary "tuned in" list (the people whose activity appears on their home feed) plus any number of custom lists with configurable `visibility` (public/private) and `add_policy` (owner_only / self_add / members_add / anyone_add).
- **Tune-in gesture** — one-button **Tune in** / **Tuned in** on any profile at `/u/{handle}`; replaces the implicit "follow" concept.
- **Mutuals** — two users who've tuned in to each other. Profiles show `has N mutuals (M in common)`; `/u/{handle}/mutuals` lists them; `?filter=common` narrows to those shared with the viewer.
- **List pages** at `/lists/{id}` with **Activity** (feed scoped to members) and **Members** tabs. Self-join button when policy is `self_add`.
- **Search returns user profiles** — people results above content results, suppressed when content-type filters (`type:`, `status:`, `creator:`, etc.) are active.
- **`list:` search filter** — `list:{id}`, `list:mutuals`, `list:tuned_in`. Auto-prefilled on `/lists/{id}` pages.
- **Tune-in notifications** — new `tune_in` notification type fires when someone tunes in to you or adds you to a public custom list; deduped per actor to prevent toggle-spam.
- **Markdown actions** — `tune_in`, `tune_out`, `create_user_list`, `update_user_list`, `delete_user_list`, `add_member_to_list`, `remove_member_from_list`, `join_list`.
- **`/help/lists` help topic** covering all of the above.

### Changed

- **Home feed driven by your tune-in list** (#220) — `/` shows recent activity from people you've tuned in to (plus your own content), replacing the main-collective firehose.
- **`ApplicationRecord.main_collective_scope(tenant)`** — shared helper extracted for tenant-main-collective queries.

### Fixed

- **Bogus `/actions/actions/` doubling and `.md/actions/` in markdown actions-index frontmatter** (#220).
- **N+1 on the `/lists/:id` Members tab** — TenantUser pre-attached to loaded User instances.
- **Duplicate `@common_collectives` intersection** and four extra primary-list-lookup queries per profile view.

### Security

- **Block ↔ list integration** (#220) — creating a `UserBlock` clears mutual primary-list memberships in both directions; `UserListMember` validation rejects creates that cross a block in either direction (owner↔target or adder↔target).
- **Primary "tuned in" list is immutable** — name, description, and add_policy reject changes; the edit form returns 403; `update_user_list` returns 403 for primary lists.

### Dependencies

- **vitest** in `/agent-runner` and `/mcp-server` bumped to 4.1.0 (#219).
- **hono** in `/mcp-server` bumped to 4.12.23 (#221).

## [1.21.0] - 2026-05-31

### Added

- **Free/paid tier model for collectives** (#216) — explicit `tier` column with upgrade/downgrade endpoints, replacing implicit derivation from feature toggles. $3/mo owner-billed when ≥1 paid feature is active; subscription loss lapses (not archives) paid collectives.
- **Upgrade confirmation page** (#216) — shows prorated amount before charge.
- **Tier badge, reorganized settings UI, and tenant-aware paid-plan copy** (#216).
- **Archive from collective settings with auto-downgrade** (#216) — gated behind a `collective_archive` reverification scope; tracks `archived_by_id` in `SecurityAuditLog`.
- **404 teaching response on unknown action names** (#217) — lists the actions defined at that path so a typo recovers in one round trip.

### Changed

- **MCP server and agent-runner are stateless** (#217) — `navigate` → `fetch_page`; `execute_action` requires `path`. Cursor and cross-turn replay removed.
- **Honest HTTP status codes on md/json action errors** (#217) — 401/403/404/409/422 instead of always 200 across ~125 call sites.
- **`render_action_*` is Turbo-compatible** — HTML redirects with flash; removes per-form `data-turbo="false"` workarounds and fixes silent breakage on 13 action-endpoint controllers.
- **MCP `CONTEXT.md` trimmed 163 → 19 lines** (#217).

### Fixed

- **Customers silently charged after last paid resource removed** (#216) — zero-quantity now cancels the Stripe subscription.
- **Stripe sync failures silently swallowed** (#216) — failures now surface in the user-facing flash.

### Removed

- **`/billing` deactivate/reactivate-collective routes** (#216) — they skipped the reverification gate and audit log; superseded by the settings-page archive flow.

### Security

- **`PaidTransitionGate`** (#216) — blocks free → paid transitions when the owner has no Stripe billing set up.
- `Collective#archive!`/`unarchive!` enforce the owner check in-model; re-entry guards protect the audit trail.

## [1.20.0] - 2026-05-29

### Added

- **Whole-card navigation in feed items** (#215) — clicking a Note / Decision / Commitment card navigates to its show page via a new `card-navigate` Stimulus controller. Matches native anchor behavior (modifier-key new-tab, keyboard Enter/Space, interactive children short-circuit, text selection preserved) with `role="link"` and `:focus-visible`. Redundant "View →" footer links removed.
- **"Voted" status on open decision cards** (#215) — viewers who already voted see a disabled "Voted" branch, mirroring "Confirmed" on Notes. Voted-on decision IDs computed once per request to avoid N+1.
- **"Show more" expansion on long feed cards** (#215) — note bodies render as full markdown inside a CSS line-clamp; a new `card-expand` controller reveals the toggle only when the body actually overflows.
- **Reusable Stimulus utility controllers** for CSP-safe inline-handler replacements: `hide-on-error`, `remove-parent`, `confirm-submit`, `history-back`, `handle-availability`, `radio-toggle`. Inventory in `docs/ARCHITECTURE.md`.

### Changed

- **Turbo Drive now actually runs** (#215) — `@hotwired/turbo-rails` was in `package.json` / `Gemfile` but never imported, so Turbo never ran and `data-turbo-confirm` was a no-op. Importing it required bringing the codebase in line: five create actions return 422 on validation failure instead of 200; forms that can't fit Turbo's 303/422 contract (Stripe redirects, ActiveStorage downloads, render-different-template-after-success) opt out with `data: { turbo: false }`; page-load init JS listens for `turbo:load` instead of `DOMContentLoaded`. Hotwire section of `docs/ARCHITECTURE.md` rewritten.
- **Delete-Token and Cancel-Task confirmation prompts now actually appear** — both carried `data: { confirm: ... }` (Rails-UJS legacy, never wired up here). Renamed to `data: { turbo_confirm: ... }`.
- **Inline "Last sync N min ago" reveal-after-10-minutes removed** on `cycles/show` and `collectives/show` — the revealed text was server-rendered at page load, so it was a stale string by the time it appeared.

### Security

- **CSP `script-src 'self'` swept clean across views** — 16 inline event handlers (`onclick`, `onerror`, `onsubmit`, `href="javascript:..."`) replaced with the Stimulus utility controllers above. Final sweep returns zero matches.
- **Decision vote tallies no longer leaked on the unvoted feed-card branch** (#215) — `FeedItemComponent` now mirrors the show page's blind-taste-test rule via a `show_decision_results?` gate. Also fixed a subtler leak: the unvoted branch sourced options from the `decision_results` DB view (ordered by `accepted_yes DESC`), so the order itself revealed the ranking. Switched to `options.order(:created_at)`.

### Fixed

- **Markdown in feed cards rendered as literal `<p>` etc.** (#215) — Rails' `truncate` escapes its input and doesn't honor `html_safe`, double-escaping the markdown HTML. Replaced with a full render inside the line-clamp wrapper.
- **Titleless notes showed their first line of text twice** (#215) — `Note#title` falls back to the first line of body text when the persisted title is blank, so the previous `show_title?` check rendered both. Now gates on `persisted_title.present?`.

## [1.19.1] - 2026-05-28

### Added

- `/motto` added to the anonymously-readable surface alongside `/n`, `/d`, `/c`, `/u`, and `/help`. Mirrors the `/help` wiring: `allows_anonymous :index`, `set_no_cache_headers`, no per-route rate limit (single-page surface, `Rack::Attack` is the backstop), `Allow: /motto` in the per-tenant robots.txt, and full OG/Twitter meta via the existing `anon_readable_indexable_response?` predicate. Route-sweep allowlist and private-tenant depth check updated.

## [1.19.0] - 2026-05-28

### Added

- **Anonymous read access on public tenants** (#212) — tenants listed in `ANON_READABLE_TENANT_SUBDOMAINS` let logged-out visitors view `/n/:id`, `/d/:id`, `/c/:id`, `/u/:handle`, and `/help/*` on the main collective. Interaction surfaces (pin, report, edit, comment form, vote, join/RSVP/sign) are replaced with "Log in to &lt;verb&gt;" CTAs. Per-IP rate limit of 60 req/min on the three item URLs; `Cache-Control: private, no-store` on all anon-viewable show actions. A route-introspection sweep enforces that no other route silently anon-leaks.
- **Rich link previews** (#213) — anon-readable HTML pages emit Open Graph + Twitter Card metadata (`og:title`, `og:description` excerpt, `og:image`, canonical `og:url` with query string stripped). Slack, iMessage, Twitter/X, Discord, Mastodon, LinkedIn, and Bluesky now unfurl Harmonic links.
- **Per-tenant `/robots.txt`** (#213) — anon-readable tenants allow the four anon URL shapes; private tenants and unknown subdomains return `Disallow: /`.
- **`X-Robots-Tag: noindex, nofollow` by default** (#213) — set on every response except anon-viewer HTML on `allows_anonymous` actions for anon-readable tenants, so crawlers don't index per-user chrome, private content, or the `/login` redirect from a shared private link.

### Changed

- **`/help/privacy` rewritten to be deployment-aware** — switches Public Space copy on `@current_tenant.public_main_collective?` and names the actual FQDN so the same doc describes both anon-readable and members-only deployments.
- **Social Proximity on `/u/:handle` restricted to the profile owner** — previously visible to any logged-in viewer; with the anon-read change it would have leaked to anon viewers on public tenants too.
- **CI integration-test runner split** into `test/controllers` and `test/integration` matrix entries (was consistently the slowest single runner).

### Security

- **`check-tenant-safety` hook now catches bare `unscoped` calls** — the regex required a literal dot prefix and silently allowed `unscoped` inside class methods. Switched to a word-boundary match; cleaned up the two existing offenders.
- Fixed two leaks in `decisions/show.{html,md}.erb` that rendered vote prompts ("Submit your vote to see results.", vote-instructions block) to anon viewers who can't vote. Both gated on `@current_user` now.

### Fixed

- Markdown nav bar notification count rendered as `[](/notifications)` instead of `[N](/notifications)` after a memoization-ivar rename broke two layout readers.
- `ApplicationRecord#user_can_close?` crashed on `nil` user when `_deadline_display.html.erb` reached the `requires_manual_close?` branch (deadlines 50+ years out). Sig widened to `T.nilable(User)` with a nil guard.
- `UsersController#show` returned HTTP 200 with the 404 template body for nonexistent handles — now returns a proper 404.
- **Flaky 429s in anon-read tests** (#214) — the per-test `REMOTE_ADDR` override pattern was a no-op (Rails integration tests route through `integration_session.process`, not a `TestCase#process` override), so every anon GET went out as `127.0.0.1` and parallel workers shared one rate-limit counter in Redis. Switched to `self.remote_addr = fresh_test_ip` with a deterministic per-worker counter.

## [1.18.1] - 2026-05-25

### Fixed

- Active Storage direct-upload PUTs to DigitalOcean Spaces were blocked by the app's Content Security Policy. `img_src` was extended to the Spaces host for image display, but `connect_src` was still `:self` + drand only, so the browser refused the PUT outright before the CORS preflight even fired (no OPTIONS request in the network tab). Extended `connect_src` to the same Spaces origins.

## [1.18.0] - 2026-05-25

### Added

- **Commitment subtypes — calendar events and policies** (#211) — `commitments.subtype` now supports `calendar_event` and `policy` alongside the default `action`. Calendar events carry `starts_at`, `ends_at`, and an optional `location`, surface an "RSVP" verb, and live in the cycle containing their `starts_at` rather than `created_at` (an event created today for next week shows up in next week's cycle). Policies use "Sign" / "Signatories" labels. Both share the existing critical-mass + deadline structure. Subtype-aware labels propagate through the show page, settings page, join/RSVP/sign button, participants list, feed item, breadcrumbs, markdown views (read by AI agents via MCP), and action descriptions. New help topics `/help/calendar-events` and `/help/policies`.
- **Calendar event form polish** (#211) — event time uses `DatetimeInputComponent` (same TZ selector, countdown, and future-only validation as the deadline input). The end-time field is now a Duration select (30 min / 1 hour default / 1.5 / 2 / 3 / 4 / 8 hours / 1 day); the server derives `ends_at = starts_at + duration_minutes`. API/markdown callers can still pass `ends_at` directly. Deadline defaults on new commitments and decisions are computed client-side (now + 7d in the user's local TZ) so the displayed value always matches the input's TZ.
- **First-class images in notes** (#208) — new `MediaItem` model is the canonical way to attach images to a Note, parallel to `Attachment` but image-only with stricter validation (magic-byte sniff, 20 MB cap, 1024×1024 source resize), ActiveStorage variants (thumbnail/medium/large), and an in-editor uploader (drag/drop, paste, file picker, per-file progress, alt text). The `/rails/active_storage/direct_uploads` endpoint now routes through a `DirectUploadsController` that inherits `ApplicationController`, so every auth/tenant/billing/capability gate applies. One-shot rake task `images:migrate_note_attachments` (DRY_RUN + throttling) migrates existing image attachments to MediaItem records.
- **Per-category default avatars** (#206) — humans (#757575), AI agents (#555555), and collectives (#333333) get distinct greyscale defaults so they're visually distinguishable in lists before any upload. All three pass WCAG AA against white text. New `inline_avatar` helper and `shared/_avatar_div` partial consolidate avatar rendering across tenant admin, user pages, AI agent views, collective lists, sidebars, history log, and breadcrumbs.
- **Author, status, and automation attribution in markdown show views** (#211) — markdown show pages for commitments, decisions, and notes now expose the creator (with "X on behalf of Y" for represented actions), an open/closed `status` row on commitments and decisions, and the existing automation-attribution partial so AI agents reading via MCP can see who/what created a resource. New `resource_author_md` helper centralizes the byline.
- **Subtype-aware commitment settings page** (#211) — breadcrumb, header, and h1 now read "Policy Settings" / "Event Settings" / "Commitment Settings" instead of always "Commitment Settings".
- `scripts/resources.sh` for inspecting machine resource usage during development.

### Changed

- **Note subtype `text` renamed to `post`** (#209) — now that text notes carry images and richer content, "text" was misleading. Clean break with no backwards-compatibility alias: a migration updates existing rows and the column default; external callers sending `subtype=text` now 422. Help pages, JS controllers, search-help subtype filters, and create-form labels updated.
- **FeedBuilder output normalized** — every feed item now has a uniform shape (`:item` is always the underlying Note/Decision/Commitment, never a wrapper event). Reminder rows surface the underlying note as `:item` with `type: "Reminder"` and `created_at: e.happened_at`; soft-deleted notes are filtered at the source. Closes a latent crash where markdown views called `feed_item[:item].title` on ReminderEvent rows. The HTML dispatch partial still works; `users/show.html.erb` now goes through it.
- Profile pages and list views ship preprocessed WebP avatar variants (`:icon`, `:thumbnail`, `:display`) instead of the multi-MB original. `image_path` / `image_url` take an optional `variant:` kwarg.

### Security

- **Rate limits across high-cardinality post-auth actions** (#205) — new `RateLimits` controller concern (Redis-backed, fixed-window) caps comments (5/min per user+item), chat messages (20/min per sender+partner), and agent task runs (5/min per user+agent). HTML responses redirect with a flash; JSON returns 429. EXPIRE is now set on every increment to prevent a transient failure between INCR and EXPIRE from leaving a TTL-less counter that permanently locks out a bucket.
- **Rack::Attack throttles on webhook ingress** (#205) — `stripe_webhooks/ip` (50/min) and `incoming_webhooks/path_ip` (100/min on path+IP) as backstops to HMAC and IP allowlist checks.
- **Length caps on user text fields** (#205) — Note title (1000) / text (1M), Decision question (1000) / description (1M), Commitment title (1000) / description (1M). Bounds regex passes on mention/link parsing and DB read cost without affecting realistic content. `Linkable#backlinks` capped at 1000 results so a heavily linked-to record can't return an unbounded set.
- **Avatar / profile image upload hardening** (#206) — source images resized to fit within 1024×1024 before storage; 20 MB cap on raw bytes for both upload paths (base64 prechecked, HTTP body capped via Content-Length + progress proc); magic-byte validation (Marcel sniff, PNG/JPEG/GIF/WebP/BMP whitelist) so Content-Type header is no longer trusted; SSRF guard on `image_url=` rejects loopback, RFC1918, link-local (incl. 169.254.169.254 cloud metadata), 0.0.0.0, and IPv6 unspecified, and uses `uri.hostname` so IPv6 literals resolve correctly. 5s open / 10s read timeout on the external fetch.
- Bump `qs` 6.14.2 → 6.15.2 in `/mcp-server` (#207).

### Fixed

- `ApplicationRecord#closed?` returned `nil` when `deadline` was absent (instead of `false`) — surfaced by a legacy policy record from earlier in development; now returns a proper boolean.
- Flaky `PulseControllerTest` reminder tests for post-midnight CI runs: a `happened_at: 10.minutes.ago` fixture could land in yesterday's cycle when the test ran shortly after midnight UTC, dropping the event from the feed. Switched to `Time.current` so the event always lands inside the current cycle.

## [1.17.1] - 2026-05-22

### Fixed

- Confirmation-email link returned 404 if a second send (re-login auto-send or `/activate` resend) rotated the token while the prior email's `deliver_later` job was still in the queue. `OmniAuthIdentity` now keeps the previous token alongside the current one — both resolve until each one's own 7-day expiry — so the older email's link keeps working.
- Auto-send of the confirmation email now fires only on signup. Subsequent logins no longer trigger another email (each login past the resend cooldown was previously enqueueing a fresh email). To re-request, users click the resend button on `/activate`.

### Changed

- The `/activate` resend-confirmation-email button is now disabled during the 30-second cooldown with a live countdown ("Available in 25s…") instead of accepting the click and showing a "please wait" error. Cooldown shortened from 60 to 30 seconds.

## [1.17.0] - 2026-05-21

### Added

- **Account activation checklist** (#202) — `/activate` gate enforces verified email + 2FA (per-tenant flags) before granting access. Existing sessions without both will be redirected on next request; sys-admins and AI agents are exempt.
- **Signup invite-gate UX** (#202) — replaces the opaque "403 invite required" with a two-step `/invite-required` flow (validate code, confirm + accept) and an email-confirmation flow with a 60-second resend cooldown.
- **API tokens for humans cost $3/mo; humans are otherwise free** (#202) — token creation routes through Stripe Checkout when needed and finalizes on return.
- **Recent Cycles sidebar** on the homepage (#201).
- **Sys-admin ops controls** (#196) — redispatch queued task runs, cancel stuck runs, and a DB/Redis health panel on the sys-admin dashboard.
- `TURNSTILE_SITE_KEY` / `TURNSTILE_SECRET_KEY` env vars (blank by default; populate in production to activate the Turnstile widget).

### Security

- **Bot defenses on existing auth-flow forms** (#203) — `/login`, `/auth/identity/register`, `/password`, and `/password/reset/:token` now require an empty honeypot + min-form-time and optionally a Cloudflare Turnstile token. New `Rack::Attack` throttles add per-IP caps on identity registration (5/hr) and invite-code submission (5/hr/IP + 10/hr/user). Turnstile no-ops when `TURNSTILE_SECRET_KEY` is blank, so dev/test/CI need no setup.

## [1.16.1] - 2026-05-17

### Fixed

- Legacy-Trio backfill migration (`20260513000001`) failed on deploy with `can't write unknown attribute 'trio_user_id'`. The migration delegated to `TrioSeeder.ensure_for`, which has since been rewritten for the per-collective model and now writes `Collective#trio_user_id` — a column not added until `20260514000000`. Inlined the legacy per-tenant create logic in the migration so it matches the schema-of-record at its version; the next-day migrations still adopt these trios into each main collective's `trio_user_id`.

## [1.16.0] - 2026-05-17

### Added

- **System agents — first-class built-in agents per tenant** (#199) — new `system_role` column on `users` identifies built-in system agents (currently Trio) so they can be seeded, billed, and rendered distinctly from user-created AI agents. Security tests pin that `system_role` cannot be set via mass assignment from any user-facing form, controller, or API path.
- **Per-collective Trio (Workspace AI Assistant)** (#199) — rewrote `/trio` from a polling/voting page into a chat with the per-collective Trio system agent. Tenants get a single Trio user; each collective opts in via collective settings, which seeds (or restores) Trio as a member via `TrioActivator`. `Collective#trio_user` FK resolves the right Trio for `@trio` mentions; missing-trio mentions return a helpful hint. Trio's identity prompt is resolved dynamically and displayed on `/whoami`. Trio replies to mentions and to direct replies on its own comments. New "Workspace AI Assistant" section in user settings exposes Trio configuration.
- **Agent-runner observability — tool calls and model reasoning on think steps** (#200) — reasoning models (Arcee trinity-large-thinking, DeepSeek R1, Claude extended thinking, OpenAI o-series) emit chain-of-thought in a separate field that the runner previously discarded; tool-only responses left the think step's preview empty. `LLMClient` now normalizes reasoning across vendor shapes (`message.reasoning_content`, `message.reasoning`, `choice.reasoning`) into one optional field; `AgentLoop` passes it plus a compact per-tool-call summary into the think step. Timeline UI (HTML, owner markdown, sys-admin markdown, live JS streaming) renders inline tool-call summaries and an "View model reasoning" accordion. Tool-call arguments and reasoning are redacted in sys-admin views via the existing flag.
- **Comments link inside their root thread; agents can reply to a specific comment** (#200) — comments are themselves Notes with their own `/n/<id>` URLs. Agents (and humans) following a mention link previously landed on an isolated comment page with little context, and the on-page `add_comment` action was ambiguous between "reply to this comment" and "post a sibling on the parent". `Note#display_path` now returns `{root_commentable.path}?comment_id={truncated_id}` for comments (walking the polymorphic commentable chain); the comments section, mention/reply automation templates, and in-app + email notification URLs all use `display_path` so recipients land in the full thread with the linked comment marked (📌). `Note#path` stays as the bare canonical URL so suffix-concatenating callers keep working. `add_comment` now accepts an optional `replying_to_id` so agents can nest a reply under a specific comment, with validation that the target shares a root commentable with the request's resource.
- **Cross-turn navigation state replay — documented and tested** (#200) — the agent-runner replays each chat session's saved `current_path` after `/whoami` at the start of every turn. Added an explanatory comment at the call site and tests pinning two reasons this is load-bearing: action validity is page-scoped (`executeAction` rejects actions not in `currentActions`), and chat-history rehydration only carries user/assistant text across turns, so the LLM otherwise has no memory of the page. No functional change.
- **System-admin: unredacted task-run details for system agents** (#199) — sys-admins can inspect Trio (and other system-agent) task runs with full step content, since system agents have no PII to protect.
- **Help topics restructured into categories** (#197) — `/help` index is now grouped into categories; `/learn` retired and its content folded into `/help`. New topics: automations, notifications, representation, REST API, markdown UI (split from API), and Trio. API and agents topics gated behind feature flags. Help pages use github-markdown styling. `/api/v1` info endpoint is dynamic.
- `/help/trio` help topic and revised Trio system prompt (#199).
- `TRIO_DEFAULT_MODEL` env var for configuring Trio's default LLM (#200).

### Changed

- **REST API at `/api/v1/` is read-only** (#198) — write endpoints removed. Programmatic mutation should go through the markdown UI's `/actions/<name>` paths (used by the MCP server and agent-runner), which carry the same auth and audit guarantees as the human UI. The v1 API is preserved for read access only.
- **Default agent-runner model switched to Arcee `trinity-large-thinking`** (#199) — a reasoning model better suited to Harmonic's tool-use loop than the prior default.
- `/trio` controller, view, route, and rake task removed in favor of the per-collective Trio chat (#199). Legacy per-tenant trios are adopted into the per-collective scheme automatically.
- Trio identifies and displays as "trio" everywhere (not "Trio" / "@Trio") (#199); user messages are no longer duplicated into `chat_turn` LLM context.
- System AI agents skip billing checks (#199).
- The handle `trio` is now reserved for the Trio system agent (#199).

### Security

- **API token model hardened** (#197) — tokens are immutable after creation except for `name` (closes a quiet expiration-extension vector where a holder could lengthen a deliberately short-lived token); 50-token-per-user cap on active external tokens; new-token scopes must be a subset of the calling token's scopes (standard OAuth downscoping); v1 create is human-only as defense-in-depth alongside the existing capability check; index/show responses drop the obfuscated `token` stub in favor of `token_prefix` (plaintext was and remains only returned on create); validation errors on internal attributes are filtered out of API responses.

### Fixed

- `display_path` column reader on `AiAgentTaskRunResource` and `AutomationRuleRunResource` (#200) — both models have a `display_path` column storing a pre-computed URL, but the new `ApplicationRecord#display_path` fallback was shadowing the column reader and routing callers through `path` (which assumes a `collective` and `path_prefix` neither model has). Override both to return the stored column value.

## [1.15.0] - 2026-05-12

### Added

- **Collective data export and import** for instance portability — export a collective to a JSON archive (notes, decisions, options, votes, commitments, links, attachments, audit chains) and import it on another instance. Tenant-admin-only; UUID-based user matching with an admin-controlled email map; streaming archive extraction; rate-limited; feature-flagged. Email notification when exports are ready, with a settings UI under collective and tenant-admin pages. Stuck-import sweeper, expired-export cleanup, and security audit logging for both directions.
- **Per-user data export** (Phase 1b) — users can request a download of all their personal data: notes, decisions, options, votes/participations (with denormalized labels), commitments, links, attachments, note-history events, decision audit entries (where the user was actor), trustee grants (as grantor or trustee), invites sent, representation sessions and session events, and account-level data. AI agents owned by the user are exported recursively into nested per-user subdirectories with sanitized handles. Cross-collective, AI-agent, and soft-delete invariants are pinned by tests. Credentials and API tokens are explicitly excluded. Rate-limited; feature-flagged; email notification on completion.
- **Audit chain v2 — PII decoupled from hashes** — audit entries now hash an `actor_token` instead of the raw handle, so display fields (handle, metadata) can be scrubbed without breaking the chain. Existing chains migrate automatically. Verify page and the TypeScript/Python verifiers handle both schema versions. Audit chain export/import across instances uses an `:imported` binding so cross-instance receipts remain verifiable. Honest trust-model copy on the verify page explains what each verification step actually proves.
- **Phased deletion with grace period** (Phase 2) — soft-deleted records leave a tombstone with `hard_delete_after`, and content stays masked via accessors during the grace period rather than being scrubbed at delete time. `HardDeleteExpiredRecordsJob` sweeps expired Note tombstones daily. Notes opt in via `participates_in_hard_delete`; decisions and commitments carry the column for future phases. `system_tombstone_note!` for moderation deletions; reminder delivery now guards against soft-deleted targets.
- `minimum-release-age` set in `.npmrc` (root, agent-runner, mcp-server) for supply-chain protection against typosquatting and recently-published malicious packages.
- Brakeman ignore entries and AI agent handle sanitization to keep export subdirectory paths safe.

### Changed

- Renamed `trustee_grants.studio_scope` to `collective_scope` (legacy "studio" terminology removed from this column).
- Data import moved from collective settings to the tenant admin area; tenant admins now own cross-instance restore.
- ActiveStorage URL TTLs tightened; import archives are purged from blob storage after successful processing.
- Import side effects (search indexing, link parsing, tracked events, user-item-status updates) are suppressed via `Current.importing_data` so re-importing a collective doesn't fire spurious notifications or re-tally votes. Vote DB trigger updated to use `updated_at`.
- Collective import respects archived `TenantUser` state — archived users stay archived after restore.

### Fixed

- FK violation when deleting a collective that had tracked events referencing it.
- Flaky comment-order assertions in collective import tests.
- Representation session filter in per-user export now correctly returns only user-to-user sessions.
- Enforce `collective_id` consistency between decision/commitment parents and their children (options, votes, audit entries, participants) via a shared concern, preventing cross-collective drift.

### Security

- Bump `nokogiri`, `sidekiq-cron`, and `view_component` for upstream security advisories.
- Bump `fast-uri` (3.1.0 → 3.1.2) and `hono` (4.12.14 → 4.12.18) in `mcp-server`.
- Per-user and collective data export endpoints reject API-token sessions, are rate-limited via `rack-attack`, and write to a dedicated security audit log.
- User emails dropped from collective export payload; cross-instance user matching now relies on UUID plus an admin-supplied email map at import time.

## [1.14.0] - 2026-05-07

### Added

- Client-side audit chain verification — TypeScript verifier runs automatically in the browser on the verify page, recomputing all hashes via Web Crypto API, replaying vote tallies, and fetching beacon randomness directly from drand. Shows detailed PASS/FAIL/SKIPPED results with trust-building explanations.
- Server-side audit chain verification for AI agents — the markdown verify page now runs Ruby verification and shows results inline, so AI agents see verification status without running anything.
- Vote receipt hashes on voters page — each voter's receipt hash is shown (amber-highlighted) next to their name, linking to a receipt verification page.
- Receipt verification route (`/d/:id/verify/:hash`) — shows a voter's full audit trail with the receipt entry highlighted. Helpful not-found page for invalid hashes.
- Vote receipt email opt-in — "Email me a vote receipt" checkbox on the voting form, behind the `vote_receipt_emails` feature flag (enabled by default, configurable per-collective/tenant). Emails link to the receipt verification page.
- `generated_at` timestamp in verify.json for cache/staleness awareness.
- Cross-implementation hash consistency tests (Ruby, TypeScript, Python all verified to produce identical hashes).

### Changed

- Verification checks now show SKIPPED with an explanation when nothing was actually verified (no beacon drawn, no votes cast), instead of misleadingly claiming PASS.
- Results are now included in verify.json for open decisions when votes exist, enabling client-side tally verification before close.
- CSP `connect-src` expanded to allow `https://api.drand.sh` for browser-side beacon verification.
- Voter status now based on vote record existence rather than positive acceptance — a voter who unchecks all options is still recognized as having voted (sees results, button says "Update Vote").
- Submit button stays enabled after any checkbox interaction, allowing voters to submit non-acceptance of all options.

### Fixed

- Vote-after-close trigger race condition — changed `deadline < NOW()` to `deadline <= NOW()` to close a sub-millisecond window.
- Audit timestamp precision — `created_at` truncated to second precision before storing, matching the ISO8601 second precision used in hash computation.
- Voter who unchecks all options no longer loses voted status or results visibility.

### Security

- Audit safety check extended to catch instance-level Vote/Option mutations (e.g., `vote.save!`), not just class-level.
- New AI agents are automatically added to the tenant's main collective on creation.

## [1.13.0] - 2026-05-06

### Added

- Tamper-evident audit chain for decision mutations — every vote, option change, close, and beacon draw gets a SHA-256 hash-chained entry in a per-decision append-only log. Tampering with any record breaks the chain.
- Verifiable randomness beacon for vote decision tiebreakers — vote decisions now fetch a drand beacon value on close, making tie-breaking between equally-ranked options provably fair.
- Decision lifecycle tracking — `decision_created`, `decision_updated`, and `option_updated` audit entries record the full history of a decision from creation through close, with before/after metadata.
- Verify page (`/d/:id/verify`) with embedded Python verification script, syntax highlighting, and copy-to-clipboard. Accessible before and after close, with contextual language for vote vs. lottery decisions.
- Vote audit receipts — voters see their receipt hash in a flash notice and API response after voting.
- `AuditChainIntegrityJob` for periodic chain verification.
- DB triggers enforcing audit entry immutability (UPDATE blocked) and vote-after-close prevention (INSERT/UPDATE blocked on votes for closed decisions).
- `check-audit-safety.sh` static analysis script (CI + pre-commit) banning direct Vote/Option mutations outside `DecisionActionService`.
- `Decision::MAX_OPTIONS` cap (100 options per decision).
- Dark mode support for syntax highlighting (highlight.js GitHub Dark theme).
- Comprehensive integration and regression test suites for the audit chain, including cross-language Python script verification.

### Changed

- `LotteryService` and `LotteryDrawJob` generalized to handle both lottery and vote decisions.
- `DeadlineEventJob` now enqueues `LotteryDrawJob` for vote decisions on natural deadline expiry.

## [1.12.1] - 2026-05-04

### Security

- Fix path traversal vulnerability in `LearnController#page_text` by allowlisting valid page actions.
- Update `net-imap` (0.4.20 → 0.6.4) — fixes command injection, DoS, and STARTTLS stripping vulnerabilities.
- Update `addressable` (2.8.4 → 2.9.0) — fixes Regular Expression Denial of Service in URI templates.
- Update `yard` (0.9.38 → 0.9.43) — fixes arbitrary path traversal via yard server.

### Added

- Brakeman static security analysis in CI — scans for Rails-specific vulnerabilities (SQL injection, XSS, path traversal, etc.) on every PR.

## [1.12.0] - 2026-05-04

### Added

- Per-session chat collectives — each chat session gets a dedicated private collective (`collective_type: "chat"`) with only the two participants as members, ensuring `chat_message.created` events are scoped privately and cannot be matched by non-participant automation rules.
- Block enforcement in chat — if either user has blocked the other, chat is disabled. Sending messages returns 403; the chat page renders in read-only mode with existing message history visible and a role-aware banner ("You have blocked X" / "X has blocked you" / mutual block).
- Real-time block notification — when a block is created, a `blocked` event broadcasts via ActionCable so the other participant sees immediate feedback.
- `UserBlock` validation preventing blocks between agents and their parent user (parent is always responsible for agent actions).
- Deployment scripts: `deploy.sh` (pull & restart with explicit migration flag), `rollback.sh` (revert to previous image tag), `hotfix-patch.sh` (emergency file-level patch), `hotfix-build.sh` (cross-compile AMD64 images from dev machine).
- Registry-based layer caching for `hotfix-build.sh` (--cache-from/--cache-to with container registry).

### Changed

- Blocked users are filtered from the chat partner sidebar.
- `Collective` model now validates `collective_type` inclusion (`standard`, `private_workspace`, `chat`).
- Renamed `not_private_workspace` scope to `listable` (positive filter, excludes both private workspaces and chat collectives).
- `ChatMessage` includes the `Tracked` concern, firing `chat_message.created` events scoped to the session's chat collective.

## [1.11.1] - 2026-05-03

### Security

- Fix cross-collective automation rule matching (GHSA-g35v-6gwr-xpwp). Automation rules could fire for events in collectives the rule owner was not a member of, potentially leaking private content via webhook payloads or agent task prompts. Added collective membership enforcement at both the SQL query level and as a redundant Ruby-level check.

## [1.11.0] - 2026-05-02

### Added

- Unified `/chat` page — single DM-style interface replacing the per-agent `/ai-agents/:handle/chat` routes. Sidebar shows all conversations (agents and humans) sorted by recency.
- ChatMessage model — messages are now first-class records in a dedicated `chat_messages` table, decoupled from AgentSessionStep.
- Human-to-human messaging — any two users on the same tenant can chat in real-time via ActionCable.
- Self-chat — message yourself as a scratchpad (no notifications generated).
- Chat notifications — one in-app notification per sender, auto-dismissed on reply.
- Sidebar unread badges — dot indicator for conversations with pending notifications.
- Sidebar user search — "+" button with searchable dropdown to start new conversations.
- Profile "Message" button — quick access to chat from any user's profile page.
- Markdown chat UI — agents can read/send messages via API tokens using `Accept: text/markdown`.
- `send_message` registered as a grantable capability for AI agents.
- Collective scoping for chat sessions and messages (follows existing note/decision pattern).
- Task run resource tracking for agent-produced chat messages.

### Changed

- ChatSession generalized from agent-specific (`ai_agent_id`/`initiated_by_id`) to any two participants (`user_one_id`/`user_two_id`) with canonical UUID ordering.
- Thinking indicator only shown for internal agents (external agents don't have task runs).
- AgentRunnerDispatchService rejects external agents with a clear error (they use API tokens, not the agent-runner).
- Sidebar no longer shows social proximity users — only existing conversations.

### Removed

- `AiAgentChatsController` and `/ai-agents/:handle/chat/:session_id` routes (replaced by `/chat/:handle`).
- AgentSessionStep no longer accepts `step_type: "message"` (orphaned records cleaned up via migration).

## [1.10.1] - 2026-05-01

### Added

- Deadline events — `decision.deadline_reached` and `commitment.deadline_reached` events fire automatically when deadlines pass, enabling automations and webhooks to react without user action.
- `DeadlineEventJob` — sidekiq-cron job (every minute) that polls for past-deadline decisions and commitments across all tenants.
- Lottery decisions now automatically draw when their deadline passes (no longer requires manual close).
- Yabeda metrics for deadline events (`deadline_events.fired_total`, `deadline_events.errors_total`).

## [1.10.0] - 2026-05-01

### Added

- Decision subtypes — decisions now support `vote` (default), `executive`, and `lottery` modes, sharing the same underlying infrastructure but with distinct behavior.
- Executive decisions — a designated decision maker reviews options and selects the outcome. Includes option selection UI, final statement, and help page.
- Lottery decisions — entries are ranked by verifiable randomness from the drand distributed beacon. No voting, results hidden until the lottery closes.
- Verifiable lottery randomness — lottery outcomes are independently verifiable. The beacon round is deterministically derived from the deadline (not choosable), sort keys are computed as `SHA256(beacon_randomness || NFC(option_title))` in the PostgreSQL `decision_results` view, and a verification page at `/d/:id/verify` shows the full derivation with reproducible Python code.
- Multi-relay cross-verification — drand randomness is fetched from 3 independent relays and compared; disagreement raises an error.
- Configurable randomness provider via `LOTTERY_RANDOMNESS_PROVIDER` env var for self-hosted instances.
- Verification page (`/d/:id/verify`) — shows beacon round derivation, beacon data, formula, every entry's sort key, and code to reproduce the results.
- Statementable concern — final statements extracted into statement-subtype notes with embedded inline display. Replaces the `final_statement` text column.
- Batch voting UI — accept/prefer multiple options and submit once.
- Results visible after voting (no longer requires decision to close).
- Voters page — shows individual votes per option at `/d/:id/voters`.
- Help pages for executive decisions and lottery decisions.
- Agent/MCP support for executive and lottery subtypes.
- `search` and `get_help` tools added to agent-runner and MCP server.

### Changed

- Agent-runner `navigate` follows redirects, surfaces errors, and tracks resolved path.
- `decision_results` SQL view now joins the `decisions` table and includes `lottery_sort_key` column. Sorting works for both vote and lottery decisions in a single view.
- `pgcrypto` extension enabled for SHA256 computation in the database view.
- Help controller dynamically generates actions for all help topics (executive and lottery decisions no longer 404 in HTML format).
- Executive selection query optimized — prefetches existing votes instead of N+1 `find_by` in loop.

## [1.9.0] - 2026-04-29

### Added

- Private workspaces — every user gets a personal collective for private notes and drafts. Random handle, `/workspace/` URL prefix, settings disabled. API auto-enabled for agent access.
- Agent memory layer — "Your Memory" section on `/whoami` surfaces pinned workspace notes. Agents can store persistent knowledge across tasks using their private workspace.
- In-app help docs — `/help` pages for features including search, reminder notes, and table notes. Help link added to user dropdown menu.
- Search scope filtering — `scope:public`, `scope:shared`, `scope:private` operators for filtering by collective visibility.
- Content subtypes foundation — `subtype` column on notes, decisions, and commitments. Notes support `text`, `reminder`, `table`, and `comment` subtypes. Decision and commitment subtypes defined but not yet implemented.
- Table notes — JSONB-backed structured data tables with column schema validation, row CRUD, CSV import, edit access controls (`owner`/`members`), and batch operations. Includes human UI (creation form, show page, settings page) and full agent API (add/update/delete rows, add/remove columns, query, summarize, batch update).
- Reminder notes — scheduled notes that resurface in the feed when their countdown expires. Includes DatetimeInputComponent with timezone autodetect, live countdown timer, and reminder lifecycle (pending → delivered → acknowledged/cancelled).
- Reminder acknowledgment — replaces "confirm read" for delivered reminders. Separate history log for acknowledgments vs confirmed readers.
- Upcoming Reminders section on `/whoami` page — shows up to 5 pending reminder notes with links.
- Comment is now a real subtype value — `subtype: "comment"` stored on the model instead of inferred from `commentable` columns. Data migration backfills existing comments. Bidirectional validation enforces consistency.
- All subtypes indexed in search — `subtype:` filter works for all note, decision, and commitment subtypes. Search help documentation updated.
- `rake search:reindex` and `rake search:reindex_type[Model]` tasks for post-deploy index rebuilds.
- NoteReminderService — extracted from Note model following NoteTableService pattern. Thin delegates on Note for `reminder_pending?`, `reminder_delivered?`, `reminder_cancelled?`, `reminder_editable?`.
- Reminder and table actions added to `AI_AGENT_GRANTABLE_ACTIONS` in capability check.
- Markdown UI content truncation with code-fence wrapping for user content in agent-facing views.
- AI agents now receive @mention and comment notifications.

### Changed

- Agent system prompt redesigned — improved scratchpad prompt, workspace concept integrated.
- `is_comment?` now checks `subtype == "comment"` instead of `commentable_type.present?`. New `has_commentable?` method for direct column check.
- `parseDatetimeInTimezone` handles bare "GMT" (UTC) correctly — regex now matches zero-digit offset.
- `update_settings` uses explicit `permit` instead of `to_unsafe_h` for model params.

### Fixed

- Fix vote uncheck bug — `false.present?` returns false in Ruby, causing vote removal to silently fail.
- Fix empty note crash — added `validates :text, presence: true` (unless table subtype) to prevent `T.must(nil)` in title derivation.
- Fix 7-hour timezone offset on reminder edit page — added `utc_value` data attribute with JS UTC-to-local conversion.
- Fix countdown timer ignoring timezone select — `parseDatetimeInTimezone` now uses Intl API to resolve correct UTC offset for selected timezone.
- Fix `replying_to_id` crash on RepresentationSession — added `respond_to?(:created_by_id)` guard.
- Fix infinite page reload loop — countdown `completed` event only fires if countdown was ever positive.

### Dependencies

- Bump postcss from 8.5.6 to 8.5.12 (mcp-server)
- Bump postcss from 8.5.8 to 8.5.10 (root, agent-runner)

## [1.8.0] - 2026-04-25

### Added

- Chat interface for human-AI agent conversations — real-time back-and-forth chat where agents navigate the app, take actions, and respond conversationally.
- `agent_session_steps` table — individual DB rows replace the `steps_data` JSONB array for task run step storage. Backfill migration for existing data. `steps_data` column dropped.
- `chat_sessions` table — groups chat turns into conversations with `current_state` JSONB for navigation continuity between turns.
- ActionCable integration — `ChatSessionChannel` with authenticated subscriptions, real-time broadcasts for status (working/completed/error), activity (navigating/executing), and messages.
- Polling fallback — activates only when WebSocket disconnects, stops when it reconnects. The two transports never run simultaneously.
- Chat sidebar layout with session list, active state highlighting, "New Chat" button, and "Back to agent" link.
- Markdown rendering for agent messages using `MarkdownRenderer` (same sanitization as notes). Server-side pre-rendering ensures consistent output across ActionCable and polling.
- Busy-agent indicator when the agent is working in another session, with link to the active task run.
- Error display in chat UI for all failure paths — dispatch-time failures (billing, suspended agent), agent-runner failures (LLM errors), and preflight failures.
- `respond_to_human` tool in agent-runner for ending chat turns with a message.
- Chat history endpoint returning messages interleaved with action summaries so the agent retains context across turns.
- Auto-dispatch — when a chat turn completes, Rails checks for queued human messages and dispatches the next turn.
- 20 frontend tests (Vitest) covering ActionCable transport, polling fallback, rejected subscription, message sending, and indicator lifecycle.
- `ChatSessionChannel` tests — subscription authorization, rejection for unauthorized/nonexistent sessions.
- Security tests — agent ownership, send/poll authorization, XSS sanitization, non-human user rejection.

### Changed

- Task run steps now stored exclusively in `agent_session_steps` rows. All views, JSON endpoints, and markdown templates read from rows instead of the JSONB column.
- `AgentRunnerDispatchService#fail_task!` broadcasts error status to ActionCable so dispatch-time failures (billing, agent status) are visible in the chat UI.
- System admin task run detail page eager-loads `agent_session_steps` for the timeline partial.
- Parallelized CI test runs and Docker builds.
- Consolidated style guides, renamed dev route, added CSS static analysis check.
- Folded `AGENTS.md` into `CLAUDE.md` and simplified documentation.
- Added CI check to catch test directories missing from the matrix.

### Removed

- `steps_data` JSONB column on `ai_agent_task_runs` — replaced by `agent_session_steps` table. Dual-write, sync-on-complete, and view fallback logic all removed.
- Stale unimplemented plans, TODO index system, and broken doc references.

## [1.7.0] - 2026-04-23

### Added

- User blocking — users can block/unblock others from profile pages. Blocked users' content is hidden, interactions (comments, @mentions, votes, joins) are prevented. Blocks are tenant-wide. Manage blocks from user settings.
- Content deletion — soft delete with text scrubbing for notes, decisions, and commitments via `SoftDeletable` concern. Deleted content shows a tombstone. Creators and admins can delete.
- Content reporting — users can report harmful content (notes, decisions, commitments) for moderator review. Reports follow the actions pattern with `report_content` action on each resource controller. Content snapshot preserved at report time. "Also block" option on report form.
- Admin moderation queue at `/app-admin/reports` — report detail with content snapshot, reporter info, author report history, review form, and delete-from-report. Pending report count on app admin dashboard.
- Account security reset — combined admin action: force password reset, revoke all sessions, delete API tokens. For compromised account response.
- Session revocation via `sessions_revoked_at` timestamp on users. Existing sessions older than the timestamp are force-logged-out on next request.
- `AdminAccessControlTest` — route-enumerating access control tests that automatically cover any new routes added to admin controllers, enforcing strict sys_admin/app_admin/tenant_admin boundaries.
- `delete_note`, `delete_decision`, `delete_commitment`, `report_content` added to `AI_AGENT_GRANTABLE_ACTIONS` in capability check.
- Kebab menu on content show pages (notes, decisions, commitments) for pin and report actions.
- Security policy (`SECURITY.md`), build overlay, and hotfix workflow.
- Safety documentation (`docs/SAFETY.md`) covering the user safety feature set and moderation tools.

### Changed

- Pin and report buttons moved behind kebab dropdown menu on content show pages, matching the block button pattern on user profiles.
- Kebab menu buttons use secondary style (`pulse-action-btn-secondary`) for consistency with adjacent action buttons.
- `pulse-action-btn-secondary` style reset when inside `top-menu` dropdown (no border/padding).
- Security audit log dashboard fixed: event type column, badge colors, and details column now display correctly.
- API base controller returns proper 404 JSON for nil resources instead of raising `NoMethodError`.

### Security

- Admin controller boundaries enforced as inviolable: `AppAdminController` (app_admin only), `SystemAdminController` (sys_admin only), `TenantAdminController` (tenant admin only). No exceptions to `ensure_*_admin` before_actions.
- Block enforcement returns 404 (not 403) to avoid revealing block existence.
- Content snapshots preserved at report time so evidence survives edits and deletions.
- All admin moderation queries use `unscoped_for_admin` or `tenant_scoped_only` (no raw `.unscoped`).

## [1.6.0] - 2026-04-20

### Added

- Scoped 2FA re-verification for sensitive actions (account settings, admin panel access) with configurable expiry.
- TOTP code replay prevention within the drift window.
- Email change with verification flow, including reverification replay protection.
- Credit balance warnings on agent pages and missing markdown views.
- Agent-runner graceful shutdown and orphan recovery for zero-downtime deploys.
- Task run detail page and status filter in agent runner admin UI.
- Date, queue wait, and duration columns in agent runner admin table.
- Agent-runner outcome breakdown stats and stream info on admin dashboard.
- Dispatch-time durability and bounded retries for agent runner.
- Structured JSON logging in agent-runner (replaces `console.log`).
- Agent-runner service — Node.js service for AI agent task execution. Replaces `AgentQueueProcessorJob` + `AgentNavigator` + `LLMClient` (~1,500 LOC + tests removed). Uses Effect.js fibers over a Redis Streams consumer group; handles hundreds of concurrent tasks per process instead of the 5-thread Sidekiq ceiling.
- Internal API (`/internal/agent-runner/tasks/:id/*`) for runner ↔ Rails coordination. `Internal::BaseController` provides IP allowlist (raw TCP peer, unspoofable via XFF), HMAC-SHA256 signing over `{nonce}.{timestamp}.{body}`, and Redis-backed nonce tracking for replay protection.
- `AgentRunnerDispatchService` — validates billing/status, encrypts Bearer token (AES-256-GCM via HKDF-derived key), publishes to Redis Stream.
- Ephemeral per-task API tokens linked to `ai_agent_task_runs` for resource tracking; revoked on completion.
- Usage-based billing via Stripe AI Gateway (active when `LLM_GATEWAY_MODE=stripe_gateway`): credit top-up flow at `/billing/topup`, balance display on `/billing`, pre-flight credit check in dispatch and in the runner's preflight endpoint.
- Stripe credit grants created with idempotency key `credit_grant:<session_id>` so concurrent checkout-return + webhook calls converge on the same grant.
- Admin monitoring UI at `/system-admin/agent-runner` (runner stats + recent task runs).
- `rake agent_runner:redispatch_queued` for one-shot orphan recovery (Phase 2 cutover or after operator error).
- Fail-closed default in `CapabilityCheck.allowed?` for uncategorized actions, plus a test asserting every `ACTION_DEFINITIONS` key is in exactly one of the three capability lists.
- `ActionCapabilityCheck` denies unmapped writes for AI agents (humans and external clients unaffected).
- `start_representation` / `end_representation` moved to `AI_AGENT_GRANTABLE_ACTIONS` (agents can represent when owner opts in).

### Changed

- `Thread.current` tenant/collective state migrated to `ActiveSupport::CurrentAttributes` (auto-resets between requests, no manual cleanup needed).
- `ApiToken` converted to polymorphic `tokenable` context (supports both `User` and `AiAgentTaskRun`).
- `OmniAuthIdentity` linked to `User` via foreign key.
- Rails test Redis isolated to a dedicated DB to prevent test pollution.
- Sidekiq 7.1.3 → 8.0.10 for Rails 7.2 compatibility (pulls in rack 3, rack-protection 4, rackup 2, redis-client 0.28).
- `AutomationContext` chain state is cleared at the top of every HTTP request to prevent cross-request leaks on reused Puma threads (was causing false-positive "loop detected" errors).
- CI Node runtime bumped 20 → 22 to match the agent-runner Docker image (undici 8.x requires Node 22+).
- `request.raw_post` used in internal HMAC verification instead of `request.body.read` + rewind (avoids params parser race).
- Agent token-count params (`input_tokens`, `output_tokens`, `total_tokens`, `steps_count`) are now non-negative coerced and capped (10M) before being written, so a buggy runner can't skew billing/reporting.
- Preflight distinguishes nil (Stripe API error) from 0 credit balance — Stripe outages no longer look like "user out of credit."

### Removed

- `harmonic-agent/` — standalone PoC harness superseded by `mcp-server` for external agent use cases.
- `AgentNavigator`, `AgentQueueProcessorJob`, `LLMClient`, `LLMPricing`, `StripeModelMapper`, `IdentityPromptLeakageDetector` (ported into agent-runner).

### Security

- Fix LIKE injection in login lookups (email/username input was interpolated unsanitized into LIKE clauses).
- Harden session cookies (secure, httponly, SameSite attributes).
- Add 2FA rate limiting to prevent brute-force TOTP guessing.

### Fixed

- Fix Rack 3 login bug by upgrading omniauth-identity to 3.1 (session middleware incompatibility after Sidekiq 8 pulled in rack 3).
- Fix password reset form submitting double-hashed token.
- Fix capability check for humans representing AI agents (was incorrectly applying agent restrictions to human users acting on behalf of agents).
- Fix reverification during representation and update representation tests.
- Webhook credit-grant race: both the checkout-return handler and the webhook could simultaneously create duplicate credit grants via list-then-create. Replaced with Stripe's native idempotency header.
- `StripeWebhooksController` test payload now includes `mode`, which Stripe 18.x requires (missing attribute raises NoMethodError).
- `User#collectives_minus_main` no longer raises `PG::UndefinedTable` under default scopes; switched from `includes(:tenant)` (lazy) to `joins(:tenant)` (explicit JOIN).
- 5 tests that reported "missing assertions" now make real assertions; one of the fixes uncovered the `collectives_minus_main` bug above.
- `Internal::AgentRunnerController#complete` / `#fail` refuse terminal-state transitions, so a late agent report can't overwrite a user-initiated cancel.
- `AgentLoop.runTask` decryption failures now flow through the typed Effect error channel instead of bubbling as a defect and orphaning the task in `queued`.
- Stripe webhook `handle_checkout_completed` no longer blows up on payloads missing `mode`.
- Dispatch refuses to mark a non-queued task as failed (prevents the redispatch rake from clobbering a task that got picked up between enumeration and dispatch).
- Incorrect "Creating an agent is free" message on `/ai-agents/new` removed; $3/month seat cost was already shown elsewhere on the same page.
- `Kernel#fail` no longer shadowed inside `Internal::AgentRunnerController` (action method renamed to `fail_task`).

### Dependencies

- Sidekiq 7.1.3 → 8.0.10 (pulls in rack 3, rack-protection 4, rackup 2, redis-client 0.28)
- Upgrade omniauth-identity to 3.1 (Rack 3 compatibility)
- Bump hono from 4.12.12 to 4.12.14 (mcp-server)

## [1.5.0] - 2026-04-11

### Added

- Stripe billing integration: $3/month per-identity subscription covering human users, AI agents, and collectives
- Billing dashboard with resource inventory, deactivate/reactivate actions, and Stripe portal link
- Billing explanation page and billing gates on agent and collective creation forms
- Pending billing state for resources created before subscription is active
- Per-resource billing exemption for app admins (logged to security audit log)
- Collective archival (archive/unarchive lifecycle tied to billing)
- Billing reconciliation job as safety net for subscription quantity drift
- Stale webhook protection, idempotent webhook handlers, and security audit logging for billing
- Tenant-level allowed attachment categories
- Integration tests pinning attachment XSS protection

### Fixed

- Fix Sorbet error in Attachment#validate_file
- Fix pin_controller test typing for vitest 4

### Dependencies

- Bump hono from 4.12.7 to 4.12.12 (harmonic-agent, mcp-server)
- Bump @hono/node-server to 1.19.13 (harmonic-agent, mcp-server)
- Bump vite from 7.3.1 to 7.3.2 (harmonic-agent, mcp-server)
- Bump vite and vitest (root)
- Bump esbuild from 0.24.2 to 0.28.0

## [1.4.2] - 2026-04-02

### Security

- Bump Rails from 7.2.3 to 7.2.3.1 (activesupport, actionview, activestorage)
- Bump rack from 2.2.22 to 2.2.23
- Bump bcrypt from 3.1.20 to 3.1.22
- Bump json from 2.18.0 to 2.19.2

### Changed

- Pin connection_pool < 3 for Rails 7.2.x compatibility

### Dependencies

- Bump hono from 4.12.5 to 4.12.7 (harmonic-agent, mcp-server)
- Bump picomatch from 4.0.3 to 4.0.4 (harmonic-agent, mcp-server)
- Bump path-to-regexp from 8.3.0 to 8.4.0 (mcp-server)
- Bump effect from 3.19.14 to 3.21.0 (harmonic-agent)

## [1.4.1] - 2026-03-06

### Fixed

- Fix note edit form routing error for main collective items
- Fix OAuth login failing on iOS mobile browsers
- Fix top-right menu misalignment on mobile

### Changed

- Add proximity-ranked content timelines to homepage and user profiles
- Move collectives/subdomains from homepage to top-right menu
- Remove "Schedule Reminder" button from notifications page
- Collapse header search to icon-only on mobile to prevent overflow
- UX fixes: sidebar component, header creation button, visibility hints

### Dependencies

- Bump @hono/node-server from 1.19.9 to 1.19.10 (harmonic-agent, mcp-server)
- Bump hono from 4.11.9 to 4.12.5 (harmonic-agent, mcp-server)
- Bump rollup from 4.55.1 to 4.59.0 (harmonic-agent, mcp-server)
- Bump express-rate-limit from 8.2.1 to 8.3.0 (mcp-server)
- Bump nokogiri from 1.18.9 to 1.19.1

## [1.4.0] - 2026-02-28

### Changed

- Unify studios/scenes as collectives (remove collective_type column)
- Add search scope filtering with scope operator
- Remove explore collectives links and fix index page image sizing
- Clean up references to removed collective types in UI and docs
