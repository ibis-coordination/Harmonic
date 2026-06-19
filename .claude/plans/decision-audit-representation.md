# Spike: Capture representation in the decision audit log

**Status:** Spike / high-level. Not scheduled for implementation yet — keep decisions open, resist over-specifying.

## Problem

The decision audit chain records each lifecycle event as a `DecisionAuditEntry` with a
single `actor` (the `actor_id` / `actor_handle` / `actor_token` triple). When one user
votes (or adds options, closes, etc.) **on behalf of** another via a representation
session, the chain does not capture that representation at all.

Worse, it actively conflates the two parties. During an active representation session the
controller sets `@current_user = rep_session.effective_user`
([application_controller.rb:341](../../app/controllers/application_controller.rb#L341)).
That `effective_user` is the **represented party** (the principal / granting user). It is
this user that flows down as `actor` into `DecisionActionService.cast_vote!` →
`DecisionAuditService.record_vote!`
([decision_audit_service.rb:68](../../app/services/decision_audit_service.rb#L68)).

So the audit chain says *"Bob cast this vote"* when in fact *"Alice cast this vote as
Bob's trustee."* The trustee's identity is recorded only in the separate
`RepresentationSessionEvent` table, which is **not part of the hash chain** and carries no
tamper-evidence. The one signal in the chain that meant to be authoritative — *who took
this action* — is exactly the thing representation breaks.

## Goal

The audit chain should record, in a tamper-evident way, **both** parties of a represented
action:

- the **principal** — the user on whose behalf the action was taken (today's `actor`)
- the **representative** — the user who actually performed it (trustee, or a collective's
  representative)
- enough to distinguish *user representation* (via `TrusteeGrant`) from *collective
  representation* (no grant, `effective_user = collective.identity_user`)

A reader of the chain alone (without joining to mutable tables) should be able to tell a
direct action from a represented one, and identify the representative.

## Current state (reference)

- **Entry model:** `DecisionAuditEntry`
  ([decision_audit_entry.rb](../../app/models/decision_audit_entry.rb)) — columns:
  `actor_id`, `actor_handle`, `actor_token`, `actor_token_salt`, `option_title`,
  `accepted`, `preferred`, `metadata` (jsonb), `previous_hash`, `entry_hash`,
  `schema_version`, `sequence_number`.
- **Hashing:** `DecisionAuditService`
  ([decision_audit_service.rb](../../app/services/decision_audit_service.rb)).
  - `CURRENT_SCHEMA_VERSION = 2`. v1 hashes raw `actor_id`/`actor_handle`; v2 replaces them
    in the hash with `actor_token = SHA256(decision_id | actor_id | actor_handle | salt)`
    so the salt can be destroyed on PII scrub without invalidating the chain.
  - The actor token is anchored to the participant's **first** entry in the decision
    (stable token per `(decision_id, actor_id)` even if they rename).
- **Write chokepoint:** all mutations route through `DecisionActionService`
  ([decision_action_service.rb](../../app/services/decision_action_service.rb)), which
  records the mutation and the audit entry in one transaction.
- **Representation models:** `TrusteeGrant` (granting_user ↔ trustee_user, permissions,
  scope), `RepresentationSession` (`representative_user`, `trustee_grant` or `collective`,
  `effective_user`), `RepresentationSessionEvent` (per-action log, polymorphic `resource`,
  includes `Vote`).
- **PII scrub today:** NULLs `actor_id`, `actor_handle`, `actor_token_salt`; leaves
  `metadata` and the chain intact. Callers are forbidden from putting actor-identifying
  info in `metadata` (pinned by `audit_chain_metadata_pii_test.rb`).

## Design questions to resolve in the spike

1. **Where the representative gets recorded.** Options, roughly in order of preference:
   - **(a) First-class columns** — add `representative_id` / `representative_handle` /
     `representative_token` (+ salt) mirroring the actor triple. Cleanest for querying and
     for symmetric PII scrubbing, but widest schema change.
   - **(b) Structured metadata block** — a reserved, hashed `representation` key in
     `metadata`. Smaller migration, but collides with the existing "no actor PII in
     metadata" invariant and its scrub guarantees — would force scrubbing logic into
     `metadata`. Likely rejected for that reason; note why.
   - Decide based on how much we expect to query/verify representation independently.
2. **Token symmetry.** If we tokenize the representative like the actor, we need a
   representative salt with the same scrub semantics (destroy salt → break re-identification
   without breaking the chain). Confirm whether the representative reuses the actor's
   anchoring scheme or needs its own per-`(decision_id, representative_id)` anchor.
3. **What "actor" means going forward.** Today `actor = effective_user = principal`. Keep
   that meaning (actor = the represented party, on whose authority the action stands) and
   *add* the representative — OR flip it. Recommendation: keep `actor` = principal (matches
   "this vote counts as Bob's") and add representative as the new dimension; this preserves
   existing receipts/tallies that key on `actor_token`. Verify the vote-tally dedupe path
   is unaffected.
4. **Plumbing the representative down.** `actor` reaches the service from the controller,
   but the controller has *already collapsed* identity to `effective_user`. The spike must
   decide how the representative travels to `DecisionActionService` — e.g. pass
   `current_representation_session` (or its `representative_user`) explicitly into the
   `cast_vote!` / `add_option!` / `close_decision!` / etc. signatures, rather than
   re-deriving it. Today's signatures take only `actor:`.
5. **New schema version (v3).** Adding any hashed field requires a new hash input format
   and `CURRENT_SCHEMA_VERSION = 3`. v1/v2 verification must keep working unchanged
   (`compute_hash`/`hash_input` already dispatch on `schema_version`). Define the v3 hash
   input string (where representative fields slot in) and keep it append-only relative to
   v2 so a v3 entry with no representative hashes identically in spirit to v2 (empty
   representative fields).
6. **Verification.** Extend `verify_actor_binding`-style checks to cover the representative
   token. The verifier should detect tampering with either identity.
7. **PII scrubbing.** Representative identity is also PII. Scrub must NULL the
   representative's id/handle/salt symmetrically with the actor's. Update the scrub job and
   `audit_chain_metadata_pii_test.rb` expectations.
8. **Backfill.** Existing v1/v2 entries that *were* represented actions cannot be rewritten
   (immutable chain, DB trigger). Decide: (a) leave historical entries as-is and document
   the limitation, or (b) emit no backfill and rely on `RepresentationSessionEvent` for
   pre-v3 history. Likely (a). Be explicit that pre-v3 represented votes remain
   indistinguishable in the chain.
9. **Collective vs user representation.** Capture which kind it was. For collective
   representation there is no `trustee_grant`; the representative is a human acting as the
   collective identity. Decide whether to record the grant id / session id as a
   (non-PII, hashed?) reference for later correlation.

## Likely shape (non-binding sketch)

- New migration adding `representative_id`, `representative_handle`, `representative_token`,
  `representative_token_salt` to `decision_audit_entries` (all nullable; NULL ⇒ direct
  action).
- `DecisionAuditService`: add v3 hash input + `CURRENT_SCHEMA_VERSION = 3`; derive a
  representative token with the same anchoring + scrub semantics as the actor; thread a
  `representative:` (or `representation_session:`) param through `record_*`.
- `DecisionActionService`: add the representative param to each mutating method; controllers
  pass `current_representation_session&.representative_user`.
- Verifier + PII scrub + metadata-PII test updated for the new fields.
- Decision audit log UI / receipt rendering: show "X on behalf of Y" using the new fields
  (mirrors `TrusteeGrant#display_name` and `RepresentationSessionEvent` phrasing).

## Out of scope (for now)

- Reworking how the controller collapses identity to `effective_user` broadly.
- Changing `RepresentationSessionEvent` (it stays as the rich, mutable activity log;
  this work makes the *immutable chain* representation-aware, not a replacement).
- OAuth/API-token-only representation flows beyond confirming they pass the same param.
- Backfilling historical entries.

## Spike deliverables

1. Decision on recording location (columns vs metadata) and on `actor` semantics.
2. A written v3 hash-input spec.
3. A plumbing decision for getting the representative into the service layer.
4. A scrub + verification + test plan for the new fields.
5. A short note on the historical-data limitation.

## TDD note

When this is implemented, follow red-green: write failing tests for (a) a represented vote
producing an entry with both identities, (b) v3 hash verification, (c) symmetric PII scrub,
and (d) v1/v2 entries still verifying — before writing the implementation.
