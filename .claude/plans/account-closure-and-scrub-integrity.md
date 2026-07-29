# Account Closure and Scrub Integrity

**Status:** Planned 2026-07-28, not started.

Completes the account lifecycle. Users can be created, suspended, and archived
per-tenant, but there is no way to close an account: no user-facing flow, no admin
flow, and the one deletion mechanism that exists — the console-only
`DataDeletionManager#delete_user!` scrub — predates several subsystems and misses
them. Meanwhile the decision-verify pages already describe account-closure scrubbing
as if it existed, and the user-data-export controller scopes itself to "records that
would be deleted or scrubbed on their account closure." The product owes the
functionality its own surfaces already describe.

Picks up Phase 3 of
[data-lifecycle-management.md](completed/2026/05/data-lifecycle-management.md)
(account closure was planned there and never built) plus the scrub gaps found in the
2026-07-28 audit. General table retention stays in
[resource-limits-hardening.md](resource-limits-hardening.md) Phase 4 — not duplicated
here.

## The closure model

Closing an account is **anonymization plus access termination**, not content
destruction:

- Content the user created (notes, comments, votes, decisions, commitments) survives,
  attributed to "Deleted User" — group history stays intact.
- Everything that identifies the person is scrubbed; everything that lets anyone act
  as, for, or against the account is terminated.
- Not reversible.

Full destruction (`force_delete: true`) stays unimplemented and out of scope.

## Part 1 — Scrub integrity (fix before any flow exposes it)

The existing scrub handles identities, tokens, avatar, and membership archival. It
misses, in rough severity order (each item red-green, asserting the post-scrub
state):

1. **Sessions survive closure.** The scrub never calls `revoke_all_sessions!`, so
   refresh tokens stay valid, `sessions_revoked_at` stays unset, and an existing
   session cookie keeps working after the scrub. Push subscriptions keep delivering.
   Fix: closure revokes all sessions, refresh tokens, and push subscriptions.
2. **Trustee authorizations stay active** in both directions — a trustee can still
   represent the closed account. Fix: closure revokes all grants where the user is
   grantor or trustee.
3. **User-owned automation rules keep firing**, including the notification
   forwarder, which keeps POSTing the account's notification content to an external
   URL. Fix: closure disables (soft-deletes) all user-owned rules.
4. **TenantUser free-text fields survive**: `bio`, `location`, `website`. Fix: clear
   them alongside display name and handle.
5. **Audit-chain scrub never runs.** The schema, immutability trigger, and verifier
   were all built for it (`actor_id`/`actor_handle`/`actor_token_salt` are the
   designated mutable columns; scrubbed entries verify as `:unattributable`) but no
   code path invokes it. Fix: closure nulls the actor columns on the user's audit
   entries — the last step that makes the verify-page copy true.
6. **StripeCustomer untouched** — no subscription cancellation, no customer detach.
   Fix: cancel any active subscription and detach/delete the Stripe customer;
   remaining prepaid balance is forfeited (the closure UI warns about this before
   confirmation).
7. **User-owned data exports survive** (rows + ZIP files that contain exactly the
   scrubbed data). Fix: purge on closure rather than waiting out the 7-day TTL.
8. **Sole-admin succession TODO** — the scrub has an unhandled branch when the user
   is the only admin of a collective. Decide: block closure until ownership is
   transferred (matches the `restrict_with_exception` philosophy elsewhere), or
   auto-archive the collective. Leaning block-with-explanation.
9. **Child AI agents stay live** — only their tokens die today. Fix: closure
   archives the user's agents (they cannot act without a principal); their content
   survives like the principal's.

## Part 2 — Closure flows

Built only after Part 1, so the flow never ships ahead of its semantics.

- **Self-serve**: a closure section on `/settings` (HTML and markdown — both
  interfaces, per the two-interface rule) with an explicit confirmation step that
  states what happens: content retained under "Deleted User", prepaid balance
  forfeited, agents archived, not reversible. Reverification required (sensitive
  operation).
- **Admin-initiated**: an app-admin action for support cases, driving the same
  service. No divergent semantics between the two paths.
- The flow ends with hard logout everywhere (Part 1, item 1 does the work).
- Suggested data flow: encourage (not require) a data export before closure — the
  export feature already exists and its stated purpose is exactly this.

**Design decision needed — closure scope.** An account is the per-subdomain
relationship, but the scrub operates on the global User across all subdomains.
Options: (a) closure is global (one action ends every subdomain relationship —
simplest, matches the current scrub), or (b) per-subdomain leave (archive TenantUser
on one subdomain) with global closure as the final step. The audit found `archive!`
already implements most of per-tenant deactivation, so (b) is mostly assembly — but
(a) can ship first with (b) as a follow-up.

**Terminology.** Settle the verb in docs/CONTROLLED_VOCABULARY.md as part of this
work: "close" (account) is distinct from "archive" (reversible hide), "delete"
(destroy content), and "remove" (take out of a set). Closure retains content, so
"delete your account" would be false advertising in both directions; "close" is the
honest verb. UI copy renders authorship of scrubbed users as "Deleted User" (existing
convention, kept).

## Part 3 — Adjacent lifecycle fixes (small, independent)

1. **Schedule the two token-cleanup jobs.** `CleanupExpiredTokensJob` and
   `CleanupExpiredInternalTokensJob` exist, are tested, and are absent from
   `SIDEKIQ_CRON_SCHEDULE` — the internal-token job's own docstring says to run it
   hourly. Pure wiring.
2. **Refresh-token purge.** Rotated/revoked/expired refresh tokens are never
   deleted, grow one row per silent refresh, and `dependent:
   :restrict_with_exception` makes them a closure blocker. Add a purge job (e.g.
   rows unusable for 30+ days) and schedule it.
3. **Verify-page and export-controller copy** — re-read after Part 1 lands; the
   copy becomes true rather than aspirational, so expected change is none, but the
   check is the point.

## Sequencing

Part 3 item 1 is a one-line-each quick win, independent of everything. Part 1 in
severity order (items 1–3 first — they are access-termination correctness). Part 2
after Part 1 is complete, closure-scope decision made at its start. Part 3 item 2
alongside Part 1 item 1 (same subsystem). Red-green throughout: every Part 1 item is
a failing test against `delete_user!` (or its successor service) first.

## Out of scope

- General retention windows for append-only tables
  ([resource-limits-hardening.md](resource-limits-hardening.md) Phase 4 owns these).
- Full hard deletion (`force_delete`) — a later decision; the closure model above
  does not promise it.
- Tenant/subdomain deletion (exists separately via the Admin App API).
