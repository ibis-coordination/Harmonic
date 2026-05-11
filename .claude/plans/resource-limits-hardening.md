# Resource Limits Hardening

A combined audit and remediation plan for two related axes of abuse resistance:

1. **Rate limits** — request-frequency caps on endpoints (per IP, per user, per token)
2. **Data volume caps** — per-record size/count limits on accumulated data (per item, per user, per tenant)

Existing protections are strong in spots (login, 2FA, table notes, decision options, AI agent step counts) but the codebase has no overall framework. This plan inventories gaps from both axes and proposes phased remediation.

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
| Data export | 3 | 1 hour |
| Data import | 100 | 1 hour |

App-level: 2FA OTP lockout after 10 failed attempts, single active export per collective, single active import per tenant.

## Axis 1: Rate Limits — gaps (prioritized)

### Critical

1. **Incoming webhook endpoint has no rate limit** — [app/controllers/incoming_webhooks_controller.rb:24-40](app/controllers/incoming_webhooks_controller.rb#L24-L40)
   - HMAC + timestamp + IP allowlist gate it, but no rack-attack rule on `/hooks/*` POST
   - A leaked secret = unbounded `AutomationRuleExecutionJob.perform_later` calls, each potentially invoking LLM agents
   - **Fix**: Add rack-attack throttle keyed on `webhook_path` and IP

2. **AI agent chat / task execution unthrottled** — [app/controllers/chats_controller.rb:44-79](app/controllers/chats_controller.rb#L44-L79), [app/controllers/ai_agents_controller.rb:61](app/controllers/ai_agents_controller.rb#L61)
   - Per-message length cap (10K chars) but no message-rate cap per `(user, agent)`
   - Each call hits LLM inference; cost is real
   - **Fix**: Per-`(user, agent)` rate limit (e.g. 20 msgs/min, 5 task runs/min)

3. **Comment creation unthrottled** — [app/controllers/application_controller.rb:922-967](app/controllers/application_controller.rb#L922-L967)
   - `POST /n/:id/comments`, `POST /d/:id/comments`, `POST /c/:id/comments`
   - No per-`(user, item)` cap; comment spam fans out to notification jobs
   - **Fix**: Per-`(user, item)` rate limit (e.g. 5 comments/min)

### Medium

4. **API tokens bypass IP-based throttles** — [app/controllers/api/v1/base_controller.rb](app/controllers/api/v1/base_controller.rb)
   - All rack-attack rules key on `req.ip`; bot clients with valid tokens are unconstrained
   - **Fix**: Add token-keyed throttle for `/api/v1/*`

5. **Stripe webhook endpoint unthrottled** — [app/controllers/stripe_webhooks_controller.rb:13-43](app/controllers/stripe_webhooks_controller.rb#L13-L43)
   - **Fix**: Add modest throttle (50/min/IP)

6. **No storage quota per user/tenant** — [app/controllers/concerns/attachment_actions.rb:22-108](app/controllers/concerns/attachment_actions.rb#L22-L108)
   - 15MB per file (and 10MB per attachment record at the model — discrepancy worth resolving) but no cumulative cap
   - **Fix**: Per-user and per-tenant cumulative storage quota

7. **Password reset enables email enumeration** — [app/controllers/password_resets_controller.rb:19-38](app/controllers/password_resets_controller.rb#L19-L38)
   - IP-throttled but not per-email
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

## Axis 2: Data Volume Caps — gaps (prioritized)

### Critical (UI crash + DB bloat)

1. **Comments per item + recursive thread depth** — [app/models/concerns/commentable.rb:56-68](app/models/concerns/commentable.rb#L56-L68), [app/models/note.rb:271-302](app/models/note.rb#L271-L302), [app/components/comments_list_component.html.erb](app/components/comments_list_component.html.erb)
   - `comments_with_threads` loads all top-level comments, then `all_descendants` (recursive CTE, no depth limit) for each
   - Component renders entire tree in DOM (hidden div for replies)
   - **Fix**: `MAX_COMMENT_DEPTH` constant + paginate replies in component + cap at query level

2. **Backlinks unbounded** — [app/models/concerns/linkable.rb:18-24](app/models/concerns/linkable.rb#L18-L24)
   - `backlinks` returns `Link.where(to_linkable: self)` with no `.limit()`
   - 10K notes all linking to one note → full table scan
   - **Fix**: Cap query at e.g. 1000, paginate UI

3. **Note/Decision/Commitment text field length unbounded** — [app/models/note.rb:39](app/models/note.rb#L39), [app/models/decision.rb:32-34](app/models/decision.rb#L32-L34), [app/models/commitment.rb:26-29](app/models/commitment.rb#L26-L29)
   - No `length: { maximum: ... }` on `.text`, `.question`, `.description`, `.title`
   - Single 100MB field → DB bloat + slow regex passes (mention parser, link parser)
   - **Fix**: `length: { maximum: 1_000_000 }` (or domain-appropriate) on all user text fields

### High (DB bloat / query slowdown)

4. **Soft-deleted records never hard-deleted** — [app/models/concerns/soft_deletable.rb](app/models/concerns/soft_deletable.rb)
   - Only API tokens have a cleanup job; notes/decisions/commitments accumulate forever
   - **Fix**: `CleanupSoftDeletedItemsJob` (e.g. hard-delete > 90 days old)

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

### Phase 1 — Quick wins (smallest blast radius, biggest value)
- Rack-attack throttle on `/hooks/*` POST
- Rack-attack throttle on `/stripe/webhooks` POST
- Length validations on Note/Decision/Commitment text fields (after backfill check)
- Cap `backlinks` query at 1000

Each is a small, self-contained PR with focused tests.

### Phase 2 — User-keyed throttles
Build the per-user throttle helper (concern + Redis counters), then apply to:
- Comment creation (per `(user, item)`)
- Chat messages (per `(user, agent)`)
- Agent task runs (per `(user, agent)`)
- Password reset (per email)
- API requests (per token)

### Phase 3 — Comment threading hardening
- `MAX_COMMENT_DEPTH` enforcement on creation
- Reply pagination in `CommentsListComponent`
- `MAX_COMMENTS_PER_ITEM` if we decide a cap is right

### Phase 4 — Retention jobs
- Soft-deleted item cleanup
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

- Are these caps acceptable? (`MAX_COMMENTS_PER_ITEM=10000`, `MAX_COMMENT_DEPTH=5`, text field max 1MB, etc.)
- Phase 1 first as a single PR, or split per item?
- Do we want to introduce a `RateLimits` concern as part of Phase 2, or keep throttling logic in rack-attack only?
- Retention windows: 90 days for soft-deleted? 365 days for note history? Audit chain explicitly excluded from retention?
