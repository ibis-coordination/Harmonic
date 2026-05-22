# Resource Limits Hardening

A combined audit and remediation plan for two related axes of abuse resistance:

1. **Rate limits** — request-frequency caps on endpoints (per IP, per user, per token)
2. **Data volume caps** — per-record size/count limits on accumulated data (per item, per user, per tenant)

Existing protections are strong in spots (login, 2FA, table notes, decision options, AI agent step counts) but the codebase has no overall framework. This plan inventories gaps from both axes and proposes phased remediation.

---

## Status (2026-05-22)

**Shipped on branch `resource-limits-hardening`:**
- ✅ **Phase 1** — webhook throttles (stripe, `/hooks/*`), backlinks cap, length validations on Note/Decision/Commitment text fields (commit `c2440d5`)
- ✅ **Phase 2 (Critical items)** — `RateLimits` controller concern + comment, chat-message, agent-task-run throttles (commit `4527faf`)

**Still open:**
- Phase 2 deferred items: API-token-keyed throttle, password-reset per-email throttle
- Phase 3 — comment threading hardening (Critical from Axis 2)
- Phase 4 — retention jobs (one item blocked on deletion-semantics design)
- Phase 5 — storage and count caps
- Phase 6 — verification work

---

## Axis 1: Rate Limits — what's already there

`config/initializers/rack_attack.rb` is configured with Redis cache and these throttles (all IP-keyed):

| Throttle | Limit | Period |
|---|---|---|
| General requests | 300 | 1 min |
| Write operations | 60 | 1 min |
| Login | 5 | 20 min (also email-keyed) |
| Password reset | 5 | 1 hour |
| 2FA verification | 10 | 15 min |
| Email change | 5 | 1 hour |
| OAuth callback | 10 | 5 min |
| Identity register | 5 | 1 hour |
| Invite-required submit | 5/IP + 10/user | 1 hour |
| Invite accept | 10 | 1 hour |
| Collective data export | 3 | 1 hour |
| Per-user data export | 3 | 1 hour |
| Data import | 100 | 1 hour |
| Stripe webhooks | 50 | 1 min |
| Incoming webhooks (`/hooks/*`, keyed on path+IP) | 100 | 1 min |

App-level protections:
- 2FA OTP lockout after 10 failed attempts
- Single active export per collective; single active import per tenant
- `BotProtection` concern (honeypot + min-form-time gate, optional Cloudflare Turnstile) on `/login`, `/auth/identity/register`, `/password`, `/password/reset/:token`, `/invite-required(/accept)`, `/login/verify-2fa` — see [app/controllers/concerns/bot_protection.rb](app/controllers/concerns/bot_protection.rb)
- 30s email-confirmation send cooldown via `OmniAuthIdentity#email_confirmation_sent_at`
- `RateLimits` controller concern (Redis-backed, post-auth, keyed on `(user, …)`): comments 5/min per `(user, item)`, chat messages 20/min per `(sender, partner)`, agent task runs 5/min per `(user, agent)` — see [app/controllers/concerns/rate_limits.rb](app/controllers/concerns/rate_limits.rb)

## Axis 1: Rate Limits — gaps (prioritized)

### Critical

1. ✅ **Incoming webhook endpoint has no rate limit** — *shipped in `c2440d5`*
   - rack-attack throttle `incoming_webhooks/path_ip` at 100/min keyed on `(IP, path)`.

2. ✅ **AI agent chat / task execution unthrottled** — *shipped in `4527faf`*
   - `RateLimits` concern: chat messages 20/min per `(sender, partner)`, agent task runs 5/min per `(user, agent)`.

3. ✅ **Comment creation unthrottled** — *shipped in `4527faf`*
   - `RateLimits` concern: 5/min per `(user, item)` on `ApplicationController#create_comment`.

### Medium

4. **API tokens bypass IP-based throttles** — [app/controllers/api/v1/base_controller.rb](app/controllers/api/v1/base_controller.rb)
   - All rack-attack rules key on `req.ip`; bot clients with valid tokens are unconstrained
   - **Fix**: Add token-keyed throttle for `/api/v1/*`

5. ✅ **Stripe webhook endpoint unthrottled** — *shipped in `c2440d5`*
   - rack-attack throttle `stripe_webhooks/ip` at 50/min/IP.

6. **No storage quota per user/tenant** — [app/controllers/concerns/attachment_actions.rb:22-108](app/controllers/concerns/attachment_actions.rb#L22-L108)
   - 15MB per file (and 10MB per attachment record at the model — discrepancy worth resolving) but no cumulative cap
   - **Fix**: Per-user and per-tenant cumulative storage quota

### Low

7. **Password reset enables email enumeration** — [app/controllers/password_resets_controller.rb:19-38](app/controllers/password_resets_controller.rb#L19-L38)
   - IP-throttled but not per-email. Honeypot + min-form-time + (when configured) Turnstile now gate `POST /password`, so practical bot-driven enumeration is largely defeated; the per-email throttle is still worth adding as defense in depth.
   - **Fix**: Add per-email throttle (3/hour)

---

## Axis 2: Data Volume Caps — what's already there

Reference points (existing good limits):

| Limit | Value | Location |
|---|---|---|
| Note table rows | 500 | [app/services/note_table_validator.rb](app/services/note_table_validator.rb) |
| Note table columns | 20 | same |
| Note table cell length | 1000 chars | same |
| Note table total bytes | 2MB | same |
| Decision options | 100 | [app/models/decision.rb:136](app/models/decision.rb#L136) |
| Chat message length | 10K chars | [app/controllers/chats_controller.rb:4](app/controllers/chats_controller.rb#L4) |
| Chat messages per page | 50 | same |
| Search per page | 25 default / 100 max | [app/services/search_query.rb:147-153](app/services/search_query.rb#L147-L153) |
| AI agent steps per run | 50 | [app/models/ai_agent_task_run.rb:21](app/models/ai_agent_task_run.rb#L21) |
| Attachment file size | 10MB | [app/models/attachment.rb:98](app/models/attachment.rb#L98) |
| Attachment filename | 255 chars | [app/models/attachment.rb:18](app/models/attachment.rb#L18) |
| Notification inbox load | 50 | [app/controllers/notifications_controller.rb:20](app/controllers/notifications_controller.rb#L20) |
| Expired API token retention | 30 days | [app/jobs/cleanup_expired_tokens_job.rb:10](app/jobs/cleanup_expired_tokens_job.rb#L10) |
| Collective team list | 100 | [app/models/collective.rb:548](app/models/collective.rb#L548) |
| Note title length | 1000 chars | [app/models/note.rb](app/models/note.rb) |
| Note text length | 1,000,000 chars | [app/models/note.rb](app/models/note.rb) |
| Decision question length | 1000 chars | [app/models/decision.rb](app/models/decision.rb) |
| Decision description length | 1,000,000 chars | [app/models/decision.rb](app/models/decision.rb) |
| Commitment title length | 1000 chars | [app/models/commitment.rb](app/models/commitment.rb) |
| Commitment description length | 1,000,000 chars | [app/models/commitment.rb](app/models/commitment.rb) |
| Backlinks per item | 1000 | [app/models/concerns/linkable.rb](app/models/concerns/linkable.rb) |

## Axis 2: Data Volume Caps — gaps (prioritized)

### Critical (UI crash + DB bloat)

1. **Comments per item + recursive thread depth** — [app/models/concerns/commentable.rb:56-68](app/models/concerns/commentable.rb#L56-L68), [app/models/note.rb:271-302](app/models/note.rb#L271-L302), [app/components/comments_list_component.html.erb](app/components/comments_list_component.html.erb)
   - `comments_with_threads` loads all top-level comments, then `all_descendants` (recursive CTE, no depth limit) for each
   - Component renders entire tree in DOM (hidden div for replies)
   - **Fix**: `MAX_COMMENT_DEPTH` constant + paginate replies in component + cap at query level

2. ✅ **Backlinks unbounded** — *shipped in `c2440d5`*
   - `Linkable::BACKLINKS_LIMIT = 1000` applied to the query. UI pagination still open if a single record routinely exceeds 1000 inbound links.

3. ✅ **Note/Decision/Commitment text field length unbounded** — *shipped in `c2440d5`*
   - Length validations: title/question fields capped at 1000 chars; body/description fields at 1,000,000 chars. Note title uses a custom validator against `raw_title` so the soft-delete-aware `.title` accessor isn't called during validation.

### High (DB bloat / query slowdown)

4. **Soft-deleted Decisions/Commitments never hard-deleted** — [app/models/concerns/soft_deletable.rb](app/models/concerns/soft_deletable.rb)
   - Notes now hard-delete after a 30-day grace via `HardDeleteExpiredRecordsJob` (see [completed/2026/05/phased-deletion.md](.claude/plans/completed/2026/05/phased-deletion.md)). Decisions/Commitments still accumulate forever; phased-deletion was deferred for them pending the ownership-after-engagement / withdrawal-vs-delete design.
   - **Fix**: Extend phased-deletion pipeline to Decisions/Commitments once their deletion semantics are decided. Tracking issue / design doc lives with the data-lifecycle plan.

5. **Notification fanout unbounded per event** — [app/models/notification.rb](app/models/notification.rb), [app/models/notification_recipient.rb](app/models/notification_recipient.rb)
   - Comment in 100K-member collective → 100K `notification_recipient` rows
   - **Fix**: Cap recipients per notification, or batch deliver

6. **Notification accumulation per user** — same files
   - No retention policy on dismissed notifications
   - **Fix**: Cleanup job for dismissed > 90 days

7. **Note history events unbounded** — [app/models/note.rb:46-61](app/models/note.rb#L46-L61), [app/models/note_history_event.rb](app/models/note_history_event.rb)
   - Every update creates a row; 1M updates = 1M rows
   - **Fix**: Retention job (last N or last 365 days)

8. **Decision audit entries / automation rule runs / webhook deliveries** — accumulate forever
   - Audit chain is intentional, but other history can be retention-trimmed
   - **Fix**: Per-table retention jobs (90–180 days)

### Medium

9. **Votes per option unbounded** — [app/models/vote.rb](app/models/vote.rb), [app/models/option.rb:18](app/models/option.rb#L18)
   - Decisions cap options at 100 but no per-option vote cap
   - **Fix**: Validate uniqueness per `(option, user)` if not already; consider hard cap

10. **Commitment participants unbounded** — [app/models/commitment.rb:25,91-98](app/models/commitment.rb#L25)
    - **Fix**: Cap or paginate

11. **Attachment count per record unbounded** — [app/models/concerns/attachable.rb](app/models/concerns/attachable.rb)
    - File size capped, count not
    - **Fix**: `MAX_ATTACHMENTS_PER_ITEM`

12. **Cycle view pagination** — [app/controllers/cycles_controller.rb](app/controllers/cycles_controller.rb)
    - Loads all items in a cycle; 50K items = browser hang
    - **Fix**: Paginate cycle item lists

### Verify before fixing

13. **Vote uniqueness constraint** — confirm DB-level unique on `(option_id, user_id)` exists before designing cap fixes
14. **API `index` pagination max** — [app/controllers/api/v1/base_controller.rb](app/controllers/api/v1/base_controller.rb) — confirm whether `current_scope` is bounded; if not, enforce `per_page` max

---

## Cross-cutting design questions

Before implementation, decide:

- **Per-user rate limit infrastructure**: rack-attack supports custom keys (`req.env['warden'].user.id`), but we need a consistent helper since auth happens after rack-attack runs. Options: (a) move some checks into a controller concern with Redis counters; (b) use rack-attack with a request env attribute set by middleware after auth; (c) hybrid.
- **Cap enforcement style**: Hard reject (HTTP 429 / validation error) vs. silent drop vs. queue-with-delay. Comments + agent runs likely want hard reject with friendly UI; notification fanout likely wants batching not rejection.
- **Retention job pattern**: One generic `CleanupSoftDeletedJob` parameterized by model, or one job per concern? Generic is DRY but obscures per-model retention overrides.
- **Storage quotas**: Need a counter cache or live `SUM(byte_size)` query. Counter cache is faster but requires migration + backfill.
- **Backwards compatibility**: Adding length validations to existing unbounded text fields could fail validation on existing records. Need to verify no existing records exceed the new caps before enforcing, or use `length: { maximum: N }, on: :create` then backfill.

---

## Phased plan

### Phase 1 — Quick wins (smallest blast radius, biggest value) — ✅ shipped (`c2440d5`)
- ✅ Rack-attack throttle on `/hooks/*` POST
- ✅ Rack-attack throttle on `/stripe/webhooks` POST
- ✅ Length validations on Note/Decision/Commitment text fields
- ✅ Cap `backlinks` query at 1000

### Phase 2 — User-keyed throttles — partial (`4527faf`)

`RateLimits` controller concern built (Redis via `Sidekiq.redis` pool, fixed-window counters, `Exceeded` exception carries scope/limit/period).

- ✅ Comment creation (per `(user, item)`, 5/min)
- ✅ Chat messages (per `(sender, partner)`, 20/min)
- ✅ Agent task runs (per `(user, agent)`, 5/min)
- ⬜ Password reset (per email) — deferred (Low priority; bot defenses cover the practical risk)
- ⬜ API requests (per token) — deferred (Medium priority)

### Phase 3 — Comment threading hardening
- `MAX_COMMENT_DEPTH` enforcement on creation
- Reply pagination in `CommentsListComponent`
- `MAX_COMMENTS_PER_ITEM` if we decide a cap is right

### Phase 4 — Retention jobs
- Soft-deleted Decision/Commitment cleanup (Notes already covered by `HardDeleteExpiredRecordsJob`; blocked on Decision/Commitment deletion semantics design)
- Notification recipient cleanup
- Note history retention
- Webhook delivery / automation rule run retention

### Phase 5 — Storage and count caps
- Per-user / per-tenant storage quota
- Per-record attachment count cap
- Cycle / collective view pagination audit

### Phase 6 — Verification work (parallel to all phases)
- Confirm vote uniqueness constraints
- Confirm API pagination defaults
- Production data scan: do any existing records exceed proposed caps?

---

## Open decisions for the user

Settled:
- ~~Phase 1 packaging~~ — bundled into one commit
- ~~`RateLimits` concern vs rack-attack only~~ — concern shipped (Phase 2)
- ~~Text field caps~~ — 1000 chars for title/question, 1,000,000 chars for body/description (well under Postgres' 1 GB ceiling but enough to bound mention/link regex passes)

Still open:
- `MAX_COMMENT_DEPTH` value and `MAX_COMMENTS_PER_ITEM` (if any) — Phase 3
- Retention windows: 90 days for dismissed notifications? 365 days for note history? Audit chain explicitly excluded from retention — Phase 4
- Storage quota numbers — Phase 5
