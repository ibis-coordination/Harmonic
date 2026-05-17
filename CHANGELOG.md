# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
