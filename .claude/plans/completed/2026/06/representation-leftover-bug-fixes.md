# Representation leftover bug fixes

Follow-on to the larger `representation-ux-bug-fixes` branch. Four bugs from `representation-ux-improvements.md` that hadn't been addressed in the first pass.

## Bug 1: Grant show-page advertised actions independent of grant state

The markdown frontmatter on `/u/:handle/settings/trustee-authorizations/:grant_id` listed all five lifecycle actions unconditionally — `accept`/`decline` on already-active grants, `revoke` to the trustee, `start_representation` while a session was open. A state-aware filter existed in the controller (`action_available_for_grant?`) but only ran on the separate `actions_index_show` endpoint; the markdown layout's frontmatter rendered through `ActionsHelper` directly and bypassed it.

**Fix.** Moved the lifecycle actions in `ActionsHelper::ROUTE_PATTERNS` from `actions:` to `conditional_actions:` with condition lambdas that mirror the original filter. The markdown layout already evaluates `conditional_actions`; rewired `actions_index_show` to do the same so both surfaces stay in sync from one source of truth.

## Bug 2: Note history line dropped the representative

The metadata block on a note's show page read "Bob on behalf of Alice" via `resource_author_md`, but the History section line right below it read only "Alice created this note" — same data, two surfaces, inconsistent shape. Agents reading the markdown history lost the audit-trail half.

**Fix.** Added `history_event_actor_md` helper that, for a create event on a resource where `created_via_representation?` is true, renders the same shape `resource_author_md` does. Other event types (update, read_confirmation, reminder_acknowledged, reminder) fall back to the single `event.user` link — update events under rep have no clean per-event rep lookup today and would need separate plumbing.

## Bug 3: Auto-read-confirmation falsely claimed the represented user had read the note

The Note `after_create` hook called `confirm_read!(created_by)`, which under rep is the represented user — who hadn't actually seen the note. Same falsehood propagated to the commentable's `confirm_read` when the new note was a comment. This broke the principal-accountability story: a represented user opening their inbox to review what their agent did would see notes pre-marked as read by them.

**Fix.** Expose the active session's representative on `Current` for the duration of the request via a new `RepresentationContext` domain module (mirrors `AutomationContext`). Set by `ApplicationController` alongside the existing `@current_representation_session` assignments — same request-entry pattern `Current.tenant_id` uses, so any code path during a represented request automatically picks up the right actor without per-call plumbing. `Note.after_create` reads `RepresentationContext.current_representative_user`, attributing the auto-confirms to the representative; self-acting falls through to `created_by` as before.

## Bug 4: Grant flow silently failed when the trustee was an agent missing rep-lifecycle capabilities

A principal could create a trustee authorization for an AI agent and then watch the agent fail on "your capabilities do not include 'accept_trustee_authorization'." The cause: two parallel capability surfaces. `TrusteeGrant::GRANTABLE_ACTIONS` is the per-grant checklist on the new-authorization view (in-session permissions like `create_note`, `vote`). `CapabilityCheck::AI_AGENT_GRANTABLE_ACTIONS` is the agent's overall configuration on its settings page (includes the rep-lifecycle actions `accept_trustee_authorization`, `start_representation`, `end_representation`). The principal had no visibility into the second surface from the grant flow.

**Fix.** Add `CapabilityCheck.missing_rep_lifecycle_capabilities(user)` returning the rep-lifecycle actions the user is missing from their `agent_configuration["capabilities"]` (empty for non-agents, empty when capabilities is nil meaning "all grantable"). Render a warning on the grant show page (markdown + HTML) when the result is non-empty, naming the specific missing actions and linking to the agent's settings page where the parent can enable them. The new-authorization view itself doesn't warn — the trustee isn't selected until form submission; the show page is the next natural surface.

## Verified

- All four fixes covered by red-green TDD tests in `api_representation_test.rb` and `trustee_grants_controller_test.rb`.
- MCP smoke test (2026-06-20): Claude Code Primary acting on behalf of Dan in `green-leaves` collective via a fresh rep session. Grant show-page correctly toggled `start_representation` → `end_representation` as state changed. Created note's metadata + History line both read "Claude Code Primary on behalf of Dan." Auto-confirm-read recorded "Claude Code Primary (ai_agent of Dan) confirmed reading this note." The capability-dependency warning correctly surfaced on the grant show page, naming `accept_trustee_authorization` as the missing capability for the test agent and linking to its settings page.
- Sorbet clean; full Rails test suite green in CI.
