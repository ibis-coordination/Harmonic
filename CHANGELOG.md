# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
