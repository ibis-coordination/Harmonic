# Account Deletion and Scrub Integrity

**Status:** Planned 2026-07-28, not started.

Completes the account lifecycle. Users can be created, suspended, and archived
per-tenant, but there is no way to delete an account: no user-facing flow, no admin
flow, and the one deletion mechanism that exists — the console-only
`DataDeletionManager#delete_user!` scrub — predates several subsystems and misses
them. Meanwhile the decision-verify pages already describe account-deletion scrubbing
as if it existed, and the user-data-export controller scopes itself to "records that
would be deleted or scrubbed on their account closure" (since reworded). The product owes the
functionality its own surfaces already describe.

Picks up Phase 3 of
[data-lifecycle-management.md](completed/2026/05/data-lifecycle-management.md)
(account closure — as it was then called — was planned there and never built) plus the scrub gaps found in the
2026-07-28 audit. General table retention stays in
[resource-limits-hardening.md](resource-limits-hardening.md) Phase 4 — not duplicated
here.

## The deletion model

Deleting an account is **anonymization plus access termination**, not content
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

1. **Sessions survive deletion.** The scrub never calls `revoke_all_sessions!`, so
   refresh tokens stay valid, `sessions_revoked_at` stays unset, and an existing
   session cookie keeps working after the scrub. Push subscriptions keep delivering.
   Fix: deletion revokes all sessions, refresh tokens, and push subscriptions.
2. **Trustee authorizations stay active** in both directions — a trustee can still
   represent the deleted account. Fix: deletion revokes all grants where the user is
   grantor or trustee.
3. **User-owned automation rules keep firing**, including the notification
   forwarder, which keeps POSTing the account's notification content to an external
   URL. Fix: deletion disables (soft-deletes) all user-owned rules.
4. **TenantUser free-text fields survive**: `bio`, `location`, `website`. Fix: clear
   them alongside display name and handle.
5. **Audit-chain scrub never runs.** The schema, immutability trigger, and verifier
   were all built for it (`actor_id`/`actor_handle`/`actor_token_salt` are the
   designated mutable columns; scrubbed entries verify as `:unattributable`) but no
   code path invokes it. Fix: deletion nulls the actor columns on the user's audit
   entries — the last step that makes the verify-page copy true.
6. **StripeCustomer untouched** — no subscription cancellation, no customer detach.
   Fix: cancel any active subscription and detach/delete the Stripe customer;
   remaining prepaid balance is forfeited (the deletion UI warns about this before
   confirmation).
7. **User-owned data exports survive** (rows + ZIP files that contain exactly the
   scrubbed data). Fix: purge on deletion rather than waiting out the 7-day TTL.
8. **Sole-admin succession TODO** — the scrub has an unhandled branch when the user
   is the only admin of a collective. Decide: block deletion until ownership is
   transferred (matches the `restrict_with_exception` philosophy elsewhere), or
   auto-archive the collective. Leaning block-with-explanation.
9. **Child AI agents stay live** — only their tokens die today. Fix: deletion
   archives the user's agents (they cannot act without a principal); their content
   survives like the principal's.

## Part 2 — Deletion flows

Built only after Part 1, so the flow never ships ahead of its semantics.

Three rulings shape the design (settled 2026-07-29/30). **Terminology**: the
concept is *account deletion* — "closure" was rejected as misleading (it
suggests reversibility and nothing deleted); deletion is irreversible, just
guarded by a time delay. **Grace period**: deletion is two-phase — *request*
(immediate, reversible lock) then *scrub* (the Part 1 `delete_user!`,
irreversible) after the grace period. **Scope**: users with multiple subdomain
accounts choose between deleting one subdomain account or deleting everywhere;
users with one see only the global option. Governing principle for the whole
flow: **no surprises, no dead ends** — every state the user can reach states
what happens next and has an exit.

### The two phases

**Request (immediate, reversible).** Locks the account without destroying anything:
sessions and tokens revoked, agents paused, user-owned automation rules disabled,
push subscriptions revoked, Stripe subscription cancelled (prepaid balance
untouched), memberships hidden as archived. Login identities and PII survive —
that is what makes restore possible. Logging in during the grace window lands on
a single restore screen: "This account is scheduled for deletion on {date} —
restore it?" Restore undoes the lock; nothing was lost.

**Scrub (after the grace period, irreversible).** The Part 1 scrub, run by a
scheduled job that scans for accounts whose grace expired (natural home: alongside
the existing daily hard-delete job). Stripe customer deletion — and with it
balance forfeiture — happens here, not at request time, so a restored account
keeps its balance.

Grace length: 30 days (constant, not user-configurable). Email: a confirmation at
request time stating the deletion date and the restore path, and a reminder a
few days before the scrub — both possible precisely because the address
survives until the scrub. This resolves the confirmation-email ordering problem.

### Scope

- Detect active subdomain accounts (`TenantUser` rows, unarchived). One → the
  settings section offers only "Close your account" (global). Two or more → two
  options, clearly distinguished: "Close your account on {this subdomain} only"
  and "Close your account on all subdomains".
- **Per-subdomain deletion** scrubs only that tenant's slice after its grace
  window: TenantUser anonymized + archived, memberships archived (sole-admin
  rules applied within that tenant only), that tenant's audit entries scrubbed,
  that tenant's agents/rules/trustee authorizations ended. Global concerns —
  login identities, Stripe, refresh tokens, the User row — are untouched, and
  sessions on other subdomains survive. Requires factoring the Part 1 scrub into
  a per-tenant slice plus a global remainder.
- **Last-account rule**: deleting the only remaining subdomain account is offered
  and executed as global deletion — no orphaned global User with zero subdomain
  accounts (a dead end).

### Flow surfaces

- **Self-serve**: a deletion section on `/settings` (HTML and markdown — both
  interfaces, per the two-interface rule). States the consequences before
  confirmation: content retained under "Deleted User", the scrub date, balance
  forfeited at scrub, agents stop, reversible until the scrub date. Encourages
  (not requires) a data export first. Reverification required.
- **Admin-initiated**: an app-admin action for support cases, driving the same
  service — same phases, same grace, no divergent semantics.
- **Sole-admin block** applies at request time, scoped to the request: global
  deletion checks all tenants, per-subdomain deletion checks only that tenant.

### Terminology

Settled 2026-07-30 (reversing an earlier lean toward "close"): the concept is
**account deletion** and the verb is **delete** — "closure" misleads by
suggesting reversibility and nothing deleted, when the end state is
irreversible; the grace period is a delay on deletion, not a softer act. The
content-survives fact is carried by disclosure copy, not a softened verb.
Glossary row "account deletion" in docs/CONTROLLED_VOCABULARY.md bans "account
closure"/"deactivate your account"; the lint enforces the phrasings. UI copy
renders authorship of scrubbed users as "Deleted User" (existing convention,
kept).

### Open implementation questions (settle during build, not blockers)

- State representation: a `deletion_requested_at`-style timestamp on User for
  global deletion; the per-subdomain equivalent on TenantUser. Suspension stays a
  separate, admin-imposed state.
- Exactly which lock actions are safely reversible on restore (token revocation
  is not un-revocable — restored users re-issue tokens; state that on the
  restore screen, no surprises).
- Whether per-subdomain deletion shows "Deleted User" in that subdomain
  immediately at request time or only after the scrub (leaning: archived-member
  presentation during grace, "Deleted User" after scrub).
- A user who is suspended *and* pending deletion cannot reach the restore screen (the
  suspension gate fires first), so their account scrubs at grace expiry
  unless an admin intervenes. Deliberate for now — suspension is admin
  territory — but the admin-initiated flow should surface this.

## Part 3 — Adjacent lifecycle fixes (small, independent)

1. **Schedule the two token-cleanup jobs.** `CleanupExpiredTokensJob` and
   `CleanupExpiredInternalTokensJob` exist, are tested, and are absent from
   `SIDEKIQ_CRON_SCHEDULE` — the internal-token job's own docstring says to run it
   hourly. Pure wiring.
2. **Refresh-token purge.** Rotated/revoked/expired refresh tokens are never
   deleted, grow one row per silent refresh, and `dependent:
   :restrict_with_exception` makes them a deletion blocker. Add a purge job (e.g.
   rows unusable for 30+ days) and schedule it.
3. **Verify-page and export-controller copy** — re-read after Part 1 lands; the
   copy becomes true rather than aspirational, so expected change is none, but the
   check is the point.

## Sequencing

Part 3 item 1 is a one-line-each quick win, independent of everything. Part 1 in
severity order (items 1–3 first — they are access-termination correctness). Part 2
after Part 1 is complete, scope decision made at its start. Part 3 item 2
alongside Part 1 item 1 (same subsystem). Red-green throughout: every Part 1 item is
a failing test against `delete_user!` (or its successor service) first.

## Out of scope

- General retention windows for append-only tables
  ([resource-limits-hardening.md](resource-limits-hardening.md) Phase 4 owns these).
- Full hard deletion (`force_delete`) — a later decision; the deletion model above
  does not promise it.
- Tenant/subdomain deletion (exists separately via the Admin App API).
