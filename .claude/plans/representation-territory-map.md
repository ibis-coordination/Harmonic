# Representation territory map

> Deep-investigation findings into the existing representation system, gathered after the Stage 2 ship. Companion to [`representation-ux-improvements.md`](representation-ux-improvements.md) (the surface inventory). This document maps the *code* under each UX issue so a future plan can decide what to fix where.

## What the original UX inventory got right

Most of the bugs and friction items map cleanly to specific code locations. The architectural intuition was correct: representation is genuinely scattered across many surfaces, the active-session-blocks-self-reads behavior really does live in one method, and the missing notification really is a missing `after_commit` hook.

## What the original UX inventory miscategorized

**The "incomplete capability checklist on the new grant view" item conflates two distinct authorization surfaces.** They look similar but mean different things and are gated by different code:

1. **`TrusteeGrant::GRANTABLE_ACTIONS`** (`app/models/trustee_grant.rb:9-27`) — a flat list of 17 actions. Controls *what a trustee can do during a session*, scoped per-grant. The new-grant form's checkbox list is populated from this.
2. **`CapabilityCheck::AI_AGENT_GRANTABLE_ACTIONS`** (`app/services/capability_check.rb:65-130`) — a much broader list with grouped presentation (`:132-138`). Controls *what the agent itself can do*, regardless of representation. The agent-settings form uses this.

The rep-lifecycle actions (`accept_trustee_grant`, `start_representation`, `end_representation`) are in #2 but not in #1. **That's deliberate, not a bug** — the rep-lifecycle isn't *gated by the grant's permission set*; it's gated by the agent's overall capabilities. Adding them to `GRANTABLE_ACTIONS` would be a category error.

The real UX issue is different: the principal has to configure both surfaces independently when granting an agent trusteeship. Today there's no flow that does both atomically. The grant offers in-session permissions but the agent can't engage with the grant at all without the rep-lifecycle capabilities being added separately on the agent-settings page. **Fix shape: a unified "set up trusteeship for this agent" wizard, not a longer GRANTABLE_ACTIONS list.**

## The code under each bug

### 🔴 `/representing` markdown crash

- Controller: `app/controllers/representation_sessions_controller.rb:130-140`. The `#representing` action has no `respond_to` block.
- Templates: only `app/views/representation_sessions/representing.html.erb` exists. No `representing.md.erb`.
- Documented as the agent recovery path in `app/views/help/agents/representation.md.erb:78`.
- Fix: add `respond_to` + `representing.md.erb`. Trivial.

### 🔴 `/whoami` empty parenthetical

- Template: `app/views/whoami/index.md.erb:5` uses `@current_human_user&.display_name`.
- The variable is set only in `app/controllers/application_controller.rb:449` (browser session flow). For agents reading via MCP, `@current_user` and `@api_token_user` are set instead, never `@current_human_user`.
- Fix: in the template, use `@api_token_user&.display_name || @current_human_user&.display_name`. Or expose a unified `@representative_user` from the application controller. Trivial template change either way.

### 🟠 Session-history link broken

- Origin: `RepresentationSession#path` (`app/models/representation_session.rb:198-208`). For user-rep sessions (no `collective_id`), returns the grant page URL because there's no user-rep session show route in `config/routes.rb`. Only `/collectives/{handle}/r/:id` exists (`routes.rb:501`).
- The HTML template (`app/views/trustee_grants/show.html.erb:208`) and markdown (`show.md.erb:42`) both pass this broken value through.
- Fix: add a user-rep session show route (e.g. `/u/{handle}/r/:id` or `/representations/:id` per the routes-refactor plan), wire a show action and template, update the model's `path` method.
- Worth noting: `RepresentationSession` already includes `Linkable`, `Commentable`, `Statementable` (`:6-10`), so a richer show page is enabled by the model layer with no schema change.

### 🟠 Active-session blocks self-reads with wrong content-type

- Code: `app/controllers/application_controller.rb:411-429`. `check_for_active_representation_session` does `render json:` with no `respond_to`.
- For an MCP/markdown client, the JSON body is what surfaces. Workable but inconsistent with the rest of the markdown-API contract.
- Hint text is at `:421` — agents could be given clearer recovery copy (e.g., "include the session id in your context block, OR call end_representation first").
- Larger question: should self-acting reads under an active session be *allowed* instead of blocked? Today they're forbidden; the design intent is to force explicit declaration. Worth revisiting — see "Decisions to surface" below.

### 🟠 "Pending Requests" wording inverts the relationship

- `app/views/trustee_grants/index.html.erb:36-37` + `index.md.erb:9-11`.
- Iterates `@pending_requests` (controller `:49`), which are grants where the page's owner is the trustee, not the grantor.
- The wording calls these "requests" as if the trustee was being asked to grant authority *to* the lister. Actual semantics: the lister is being offered authority *by* the grantor.
- Fix: pure template copy. "Trusteeships offered to you" or "{Grantor} is offering you authority to act on their behalf."

### 🟠 Grant page lists irrelevant actions for the current state

- Action listing for the grant page comes from a separate path than the show template. The show template uses `pulse-tag` status filtering at `app/views/trustee_grants/show.html.erb:22-32`, but the action-list frontmatter for MCP / markdown is rendered through `ActionsHelper.actions_for_route`.
- A state-aware filter does exist at `trustee_grants_controller.rb:388-401` (`action_available_for_grant?`) and is wired into `actions_index_show` (`:77-82`) — but the show-page frontmatter renders independently.
- Fix: route the show-page action-list through the same state-aware filter. Implementation-level question rather than design.

### 🟠 Missing notification when a session occurs

- No `after_commit` / `after_update` on `RepresentationSession`. No `after_commit` on `RepresentationSessionEvent` (`app/models/representation_session_event.rb`).
- Existing notification stack: `Notification` + `NotificationRecipient` two-table model. `NotificationService.create_and_deliver!` (`app/services/notification_service.rb:17-45`) is the canonical entry. `NotificationDispatcher.dispatch(event)` (`app/services/notification_dispatcher.rb:7-30`) is event-driven.
- Existing notification types: `mention, comment, participation, system, reminder, chat_message, trio_unavailable, tune_in`. Add `representation_session` (or similar) to the whitelist at `notification.rb:6`.
- All associations needed (`representation_session.trustee_grant.granting_user`) already exist.
- Open question for the planner: one notification per session (with action summary) or one per session-lifecycle-event (started/ended)? Per-action would be too noisy.
- The `TrusteeGrant#accept!` method already has a `# TODO: Send notification to granting_user` at `trustee_grant.rb:78` — same fix shape, related concern.

## Architecture findings the UX inventory didn't surface

### Four start paths, all funnel through one helper

Three controllers create user-rep sessions. All four entry points call `ApiHelper#start_user_representation_session(grant:)` (`app/services/api_helper.rb:888-916`):

1. `RepresentationSessionsController#start_representing_user`
2. `TrusteeGrantsController#execute_start_representation` (the MCP action path)
3. `TrusteeGrantsController#start_representing` (the HTML form path)
4. `UsersController#represent` (legacy parent-of-agent path, predates trustee grants)

Plus collective-rep via `RepresentationSessionsController#start_representing`.

**Implication:** consolidating these is mostly removing redundant controller wrappers. The model-layer creation logic is already centralized.

### Five end paths

`RepresentationSessionsController#stop_representing` (`:142`) and `#stop_representing_user` (`:183`) are nearly identical (differ on the post-end redirect target). `TrusteeGrantsController#execute_end_representation` (`:338`). `UsersController#stop_representing`. `DELETE /representing` and `DELETE /collectives/X/r/Y` via the same two methods above.

**Implication:** same consolidation opportunity. Already pinned by the routes-refactor plan.

### Capability gate fires *before* context validation

`ActionCapabilityCheck` is included at `application_controller.rb:32`, *before* `ActionContextValidation` at `:36`. So an agent missing `accept_trustee_grant` capability gets `"Your capabilities do not include 'accept_trustee_grant'"` (`action_capability_check.rb:217`) before any context-shape validation runs.

**Implication:** this is correct ordering for security but means the agent can't iterate on context shape until capability is granted. Error message is bare — improving it to include "ask your principal to enable this on /ai-agents/{handle}/settings" would be a meaningful UX bump.

### Singleton-active-session is enforced only at request entry

`check_for_active_representation_session` queries on every request, but there's no DB constraint or model validation. Two concurrent `create!` calls could both succeed.

**Implication:** mostly theoretical today (the singleton check fires before any session is created via the controllers), but a unique partial index on `(representative_user_id) WHERE ended_at IS NULL` would harden this. Schema-touching.

### 24-hour expiry literal is duplicated

`RepresentationSession#expires_at` at `:92-95` says `began_at + 24.hours`. The singleton check at `application_controller.rb:417` re-encodes the same window with `began_at > 24.hours.ago`. Both must change in lockstep if the lifetime ever moves.

### Handle normalization asymmetry at the wire boundary

`TenantUser` (`app/models/tenant_user.rb:26`) parameterizes handles on write. But `api_helper.rb:1013` does `find_by(handle: handle)` without normalizing the input. So a caller sending `@Dan` or `Dan` fails to match the stored `dan` — case-sensitive lookup at the boundary even though writes normalize.

**Implication:** the case-sensitivity gap is fixable at the service layer (normalize before lookup), no schema change. The Stage 2 wire-side `parameterize` we did in `markdown_ui_service.rb` was correct; the gap is at every OTHER lookup site.

### `dependent: :destroy` on session events is wrong-by-design

`RepresentationSession` has `has_many :representation_session_events, dependent: :destroy` (`:16`). Destroying a session would drop the audit log. `DataDeletionManager` explicitly raises `NotImplementedError` for session deletion (so it's not currently live), but the `dependent` setting is the wrong choice for audit-trail data.

### `permissions = {}` DB default means deny-all

`TrusteeGrant#has_action_permission?` (`:104-108`) interprets `nil` as "all allowed" (backward-compat) and any present hash as the explicit allowlist. The migration default is `{}`, meaning a freshly-created grant with no permissions written would deny everything. Worth verifying the creation paths always write the map.

### `RepresentationSession` has latent comment/link/statement capacity

Includes `Linkable`, `Commentable`, `Statementable` (`:6-10`). No UI surfaces this — but it means a richer session-detail page (with discussion, links from other notes, etc.) is unlocked at the model layer for free.

### Two parallel attribution renderers

`app/views/notes/_created_by.html.erb:4-8` and `_timeline_note.html.erb:7-11` each inline their own "Alice on behalf of Bob" logic. The note History section has yet a third surface. **No shared partial for representation attribution.** Inconsistency between metadata-block ("X on behalf of Y") and History ("Y created this note") observed during the live test maps here.

## Decisions to surface for the planner

These are forks in the road that the next plan needs to commit to:

1. **Should self-acting reads be allowed under an active rep session?** Today they're blocked at `application_controller.rb:411-429`. The intent is "force explicit declaration so the agent doesn't accidentally write as itself when it meant to represent." But for *reads*, the cost is high (mixed-workflow agents have to thread context everywhere or end and restart) and the upside is small (a misdeclared read doesn't write data anywhere). Possible: relax only for reads, keep the gate for writes.

2. **Should representation sessions get a richer first-class show page?** The model already supports comments, statements, and inbound links. The UX inventory and routes-refactor plans both gesture at `/representations/:id` as a canonical resource — but neither commits to *what* lives at that URL beyond the action log.

3. **One notification per session, or one per lifecycle event?** Both have advocates. Per-session keeps inbox tidy; per-lifecycle catches "your agent just started representing you" before the actions happen.

4. **Should the trustee/grantor flow be unified into a single wizard?** Today the principal has to:
   - Create a trustee grant for their agent on `/u/{me}/settings/trustee-grants/new`.
   - Separately add `accept_trustee_grant`, `start_representation`, `end_representation` to the agent's capabilities on `/ai-agents/{handle}/settings`.
   - The agent then has to know to navigate to its own trustee-grants page to accept.
   
   A unified flow ("grant trusteeship to this agent") could do all three steps atomically. But that crosses three distinct authorization surfaces.

5. **Where does the "current reps" dashboard for a granting user live?** Today there's no aggregate "who is currently representing me" view. The grant page shows sessions per-grant. The routes-refactor plan proposes `/representations` as the index. Is that surface human-facing too, or agent-only?

6. **What's the right `dependent:` for session events?** `:destroy` is what's there; `:restrict_with_error` would honor audit-immutability; `:nullify` would orphan events. Decision matters once session deletion becomes a live path.

## Existing follow-up plans and how they relate

- [`representation-routes-refactor.md`](representation-routes-refactor.md) — addresses the 3+ start paths, 5+ end paths, scattered show URLs, and verb thrash. Solves the URL-layer half of the inventory. Doesn't address notifications, capability-checklist confusion, broken templates, or the unified-wizard question.
- [`representation-ux-improvements.md`](representation-ux-improvements.md) — the surface-level inventory. This territory map grounds those items in code.
- [`help-topics-discovery-refactor.md`](help-topics-discovery-refactor.md) — orthogonal but relevant: agents discovering rep help requires the discovery story to work, including topic-naming and surface.

## Schema-free vs. schema-touching fix budget

The vast majority of fixes are template / controller / service layer:

**Schema-free** (most of the inventory):
- `/representing` markdown template.
- `/whoami` parenthetical.
- Trustee-grants index wording.
- Session-history link + new show route/view.
- Active-session-blocks-self-reads relaxation.
- Notification wiring (after_commit on events).
- Banner copy.
- State-aware action filtering on grant pages.
- Handle case-normalization at lookup sites.
- Unified rep attribution partial.

**Schema-touching** (small set, larger blast radius):
- Hard-enforced singleton-per-representative (unique partial index).
- `dependent:` on session events.
- `permissions = {}` migration default audit.
- Possible: a `representation_session_id` column on resources that were created under rep, so attribution survives event-table archival. Worth considering during the audit-log retention plan.

## What this doesn't cover

- The `RepresentationSession` lifecycle from the granting user's perspective in terms of policy (rate limits, cooldowns, max active grants, etc.) — out of scope.
- The agent-runner side. Stage 2 wired schema parity, but agents using MCP from other harnesses (Claude Desktop, etc.) see the same surface. UX fixes here help all consumers.
- Whether human-to-human representation needs the same UX overhaul as agent representation. The current friction is most visible to agents but the human flows have the same wording bugs.
