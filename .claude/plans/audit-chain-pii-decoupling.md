# Audit Chain PII Decoupling

Refactor the decision audit chain so PII is not part of hashed content. After this lands, a user's account closure can scrub their identity from audit entries without invalidating the chain's tamper-evidence guarantees.

This is the architectural fix that makes Phase 5 of [data-lifecycle-management.md](data-lifecycle-management.md) actually possible without forcing a tradeoff between user erasure rights and audit integrity.

## Status

**Architecturally complete.** All planned gates for Phase 5 deletion flow are met:

- v1→v2 schema migration shipped; chain proves sequence-of-actions without including PII; scrubbing works without invalidating verification
- Export/import preserve `actor_token`, `schema_version`; salt is NULLed on import; imported entries are flagged in metadata so binding renders as `:imported` (distinct from `:unattributable`)
- Display logic falls back to stored `actor_handle` (e.g. `[deleted account]`) wherever audit entries surface; verify views render binding-state counts honestly
- Metadata PII constraint documented inline in `DecisionAuditService`; `audit_chain_metadata_pii_test.rb` pins the shape against future drift
- Verify page now includes "What this verification proves and doesn't" copy and an imported-records banner that disclaims provenance for imported chains

Branch: `feature/audit-chain-pii-decoupling` (pre-launch, not yet merged). Ready for PR.

## Window of opportunity

Existing audit chains were test data — no production preservation requirement. We could have just deleted them, but `DecisionAuditEntry` already had a `schema_version` field, so we shipped a multi-version verifier and a one-time migration that re-hashed existing entries with the v2 schema. End state is identical to delete-and-recreate, plus the pattern is established for future schema changes against real data.

## Design (as built)

### Schema versioning

`DecisionAuditEntry.schema_version` is now `inclusion: { in: [1, 2] }` with DB default `2`. After the v1→v2 migration, no v1 rows exist; new `record!` calls always write v2.

- **v1 hash content** (legacy, used only by the internal Ruby verifier for backward compatibility): `{ "v1", previous_hash, sequence_number, action, actor_id, actor_handle, NFC(option_title), accepted, preferred, metadata, created_at }`
- **v2 hash content** (current): `{ "v2", previous_hash, sequence_number, action, actor_token, NFC(option_title), accepted, preferred, metadata, created_at }`

`actor_token` and `actor_token_salt` are nullable string columns on `decision_audit_entries`. The token is in the hash; the salt is not.

The Ruby verifier (`DecisionAuditService.compute_hash`, `DecisionAuditVerifier.verify_actor_binding`) dispatches on `schema_version` and retains v1 logic so backward-compatibility is structural rather than archaeological. **User-facing code (Python script, TypeScript verifier, verify pages) is v2-only** — post-migration nothing is v1, so the user surface doesn't need version dispatch and saying "v1" in user-facing text is misleading.

### Token derivation

Each `DecisionAuditEntry` carries:

- `actor_token_salt` — 256 random bits per (decision, actor) pair, stored as 64-hex chars. NOT included in `entry_hash`. Destroyed on scrub.
- `actor_token` — `SHA256(decision_id || actor_id || actor_handle || actor_token_salt)`. INCLUDED in `entry_hash`.

Both are NULL for system actions with no actor (e.g., `beacon_drawn`).

**Deviation from original plan:** the plan said "different `actor_token_salt` per entry. This is intentional" and "no lookup at write time." Implementation reuses the salt across all entries by the same actor in the same decision because `replay_vote_totals` dedupes votes by `actor_token` — without stable tokens per actor, a `vote_cast` followed by `vote_updated` would look like two voters and double-count. `record!` looks up any prior entry by `(decision_id, actor_id)` with non-NULL salt and reuses it; otherwise generates a fresh one. The lookup is one query inside the per-decision lock that already wraps `record!`, so cost is negligible. Privacy properties are unchanged: salt is still per-(decision, actor), still destroyed on scrub, still 256 bits.

**Why this design:**

- **Public-verifiable pre-scrub**: anyone with DB read access (or anyone the user shares the four inputs with) can recompute the SHA256 and confirm the token matches. No server secret is required — Harmonic doesn't have to be trusted to verify.
- **Tamper-evident**: an attacker who changes `actor_id` without also changing the token will fail the binding check. To make the swap consistent, they'd need to recompute the token, which puts a different value in the hashed content, which forces them to recompute all subsequent `entry_hash` values — same chain-level tamper-evidence we had with v1.
- **Brute-force resistant post-scrub**: the user pool is small enough that a hash over identity-only would be brute-forceable. The 256-bit salt blocks this — without the salt, finding an input that produces the stored token requires a SHA256 preimage attack (infeasible). On scrub the salt is destroyed, so re-identification becomes computationally impossible.
- **Per-decision scoping**: same `actor_id` in a different decision yields a different token (different `decision_id` + different salt). Maximum unlinkability across decisions.

### Verifier outputs

Chain-integrity check: recompute `entry_hash` with the schema-appropriate hash function, check `previous_hash` linkages, check final-hash anchor when present.

Per-entry actor-binding check (`verify_actor_binding`):

- `:verified` — identity binds correctly to the token
- `:unattributable` — `actor_id` and/or `actor_token_salt` is NULL (PII has been scrubbed; intentional)
- `:tamper_or_scrub_inconsistent` — fields don't match. Operator cross-references `SecurityAuditLog` to determine which.
- `:no_actor` — entry has no actor (e.g., `beacon_drawn`). Binding check doesn't apply.
- `:v1_chain_only` — Ruby-internal only. v1 entry; binding is enforced by the chain hash itself rather than a separate token. Not present in user-facing TS/Python.

`verify_chain` returns `binding_statuses`, `binding_inconsistent_count`, and `scrubbed_count` alongside the existing chain integrity result. `valid` is `false` if any entry is `:tamper_or_scrub_inconsistent`. Chain integrity and binding are independent — a chain can be intact while individual entries' bindings have been scrubbed.

### `audit_chain_hash` invariant (terminal snapshot)

`Decision#audit_chain_hash` is set only at terminal moments (`DecisionActionService.close_decision!` for executive decisions; `DecisionActionService.draw_beacon!` for any decision). For ongoing decisions it's intentionally NULL — `DecisionAuditService.record!` does not touch it on every append.

The migrator preserves this invariant: only refreshes `audit_chain_hash` if the decision had one set before migration. Decisions migrated mid-flight retain NULL `audit_chain_hash` until they reach a terminal state via the normal flow. This is pinned in tests on both write paths (`record!` doesn't update it; migrator preserves NULL when NULL before).

### DB trigger: `enforce_audit_entry_immutability`

The `prevent_audit_entry_mutation()` trigger function explicitly lists every column it protects and rejects mutations to anything except `actor_id`, `actor_handle`, `actor_token_salt` (the three scrubbable fields). Pinned by 13 column-level tests in `audit_chain_regression_test.rb` (3 for the allow-list, 10 for the block-list).

The trigger is the load-bearing claim behind audit chain integrity. To enforce that nothing else in the codebase silently weakens it:

- The v1→v2 rehashing logic lives **inline** in the migration file (`db/migrate/20260510000002_migrate_audit_chains_to_v2.rb`) — no `app/services/` entry point exists for disabling the trigger.
- `scripts/check-audit-immutability.sh` (wired into pre-commit) rejects any reference to `(DISABLE|ENABLE) TRIGGER enforce_audit_entry_immutability` outside `db/migrate/`, `db/structure.sql`, `test/`, and itself.

### Metadata caveat (still pending audit)

`metadata` is a free-form JSON field that may contain PII. To make scrubbing work cleanly, **PII should not be put in `metadata`**. Audit producers should use the typed columns for actor-identifying content.

We can't enforce this at the type level. The plan calls for a code-review pass over every `record_*` call site to confirm `metadata` is PII-free. **Not yet done.**

### Scrubbing flow (verified to work; not yet wired up)

When a user requests account closure:

1. For each `DecisionAuditEntry` where `actor_id == user_id`:
   - Set `actor_id = NULL`
   - Set `actor_handle = "[deleted account]"` (display field; not in the hash)
   - Set `actor_token_salt = NULL` (destroys brute-force re-identification)
   - Do NOT recompute `actor_token` or `entry_hash`
2. For each `DecisionParticipant` where `user_id == user_id`:
   - Set `user_id = NULL`

Tests confirm the chain still verifies after this flow and binding checks correctly return `:unattributable`. The actual account-closure flow is Phase 3 (out of scope here).

### `verify_receipt` post-scrub handling

The receipt page (`/verify/:receipt_hash`) needs to scope sibling-entry lookups by `actor_token` when `actor_id` is NULL — otherwise post-scrub it would sweep in unrelated NULL-actor entries (system events, other scrubbed users). Implemented in `DecisionsController#verify_receipt` and tested.

### Display logic (still pending)

Wherever audit entries are rendered:

- If `actor_id` is present: show the user's current display name + handle
- If `actor_id` is NULL: show `[deleted account]` (or the stored `actor_handle`)

`verify_receipt` falls back to the entry's `actor_handle` only implicitly (via `@actor&.display_name || "unknown user"`). The "unknown user" fallback predates this work and doesn't yet say "[deleted account]". Other audit-rendering surfaces have not been audited.

The verifier output already surfaces `scrubbed_count` informationally on the markdown verify view ("N entries have had identifying information removed (account closure); binding for those entries is unattributable by design").

### Cross-instance import

Recommendation from the original plan stood: continue clearing `audit_chain_hash` on import. Source instance's chain only proves "source instance hadn't tampered as of export time"; mixing chains across operators is confusing. `CollectiveImportService` still does this.

Cross-instance preservation is deferred indefinitely.

## Migration (as shipped)

Versioned, in-place migration of existing entries from v1 → v2.

1. **Schema migrations:**
   - `20260510000000_add_actor_token_to_decision_audit_entries` — adds `actor_token` and `actor_token_salt` (both nullable strings)
   - `20260510000001_allow_pii_scrub_on_audit_entries` — updates the immutability trigger to permit PII-scrub mutations only
   - `20260510000002_migrate_audit_chains_to_v2` — re-hashes every chain
   - `20260510000003_bump_audit_schema_version_default_to_2` — defensive: ensures any future row that omits `schema_version` defaults to 2 rather than 1

2. **Data migration** (inlined in `20260510000002`, not a separate service):
   - Iterates `Decision.unscoped_for_system_job.find_each` inside a single `with_immutability_disabled` block (one `ALTER TABLE` pair for the entire run)
   - Per decision: rehashes entries in `sequence_number` order; generates per-actor salt cached for the decision; computes `actor_token`; recomputes `entry_hash` with the v2 hash function and the predecessor's freshly-recomputed hash as `previous_hash`; sets `schema_version = 2`
   - Refreshes `Decision#audit_chain_hash` only if it was already set (terminal-snapshot preservation)
   - Idempotent: skips entries already at `schema_version >= 2`

3. **Verification:** the test suite asserts chain integrity AND actor-binding for every migrated entry; manual run in dev confirmed the same.

After deploy, all production entries are v2. The v1 hashing code stays in `DecisionAuditService` and `DecisionAuditVerifier` so future versioned changes inherit the multi-version pattern.

## Code changes (as built)

| Layer | What changed |
|-------|-------------|
| Schema | `actor_token`, `actor_token_salt` (nullable strings); trigger function updated; `schema_version` DB default = 2 |
| `DecisionAuditService` | v2 hash function alongside v1; `record!` reuses per-(decision, actor) salt and computes token; new entries write `schema_version = 2` |
| `DecisionAuditVerifier` | Schema-version dispatch; `verify_actor_binding` with 5 outcomes; `verify_chain` returns binding statuses + counts; `replay_vote_totals` dedupes by `actor_token` |
| Audit writers | No signature change. **Metadata audit still pending.** |
| Migration | Inlined in `db/migrate/20260510000002`; trigger toggle scoped to `with_immutability_disabled` block, also private to the migration |
| `DecisionsController#verify` JSON | Includes `schema_version`, `actor_token`, `actor_token_salt` per entry |
| `DecisionsController#verify_receipt` | Scopes sibling-entry lookup by `actor_token` when `actor_id` is NULL |
| Verify views (HTML + Markdown) | Technical-details section describes v2 hash formula and actor-token derivation; markdown view renders binding state (`scrubbed_count`, `binding_inconsistent_count`) |
| TS verifier (`audit_chain_verifier.ts`) | v2-only; `verifyActorBinding`; `verifyChain` populates `bindingStatuses`/`bindingInconsistentCount`/`scrubbedCount` |
| TS controller (`audit_verify_controller.ts`) | Renders binding tamper as a distinct chain failure; pass message notes scrubbed entries |
| Python script (`scripts/verify-audit-chain.py`) | v2-only; binding check; vote-tally dedupe by `actor_token` |
| Static check (`scripts/check-audit-immutability.sh`) | New; rejects trigger toggles outside `db/migrate/` |
| `CollectiveExportService` | **Not yet updated to include `actor_token`, `actor_token_salt`, `schema_version`** |
| `CollectiveImportService` | **Not yet updated to preserve same** |
| Display logic | **Not yet audited for `[deleted account]` handling** |
| Tests | 219 audit-related tests across 7 files (unit, integration, regression, controller, JS, Python integration) |

## Test coverage

Pinned invariants (each documented with at least one test that breaks if the invariant is regressed):

1. v2 hash formula stability: 9 pipes (10 fields), starts with `"v2|"`, fields in fixed order
2. Cross-implementation hash parity: Ruby/JS/Python compute the same hash for the same input (reference hash test in TS; Python integration test runs the actual script with mocked drand)
3. Token derivation: `SHA256(decision_id || actor_id || actor_handle || salt)`
4. Salt is 256-bit hex (64 chars)
5. Salt reuse per (decision, actor): subsequent entries by the same actor reuse the salt and produce the same `actor_token`
6. Different actors get different salts
7. `record!` does NOT update `audit_chain_hash`
8. Migrator preserves NULL `audit_chain_hash` for non-terminal decisions; refreshes it for decisions that had one set
9. DB trigger column-level allow (3 columns) and block (10 columns)
10. DB trigger fires on UPDATE only
11. Static check rejects trigger toggles outside `db/migrate/` (manual sanity check; no automated test for the script itself)
12. `verify_actor_binding` returns the right symbol for each of the 4 user-facing / 5 Ruby-internal outcomes
13. Chain still verifies after PII scrub; binding returns `:unattributable`
14. Vote-tally dedupes by `actor_token` (works post-scrub)
15. Verify JSON endpoint includes `schema_version`, `actor_token`, `actor_token_salt` per entry
16. Markdown verify page renders pass / hash-fail / tally-fail / beacon-fail / scrubbed-pass / binding-tamper-fail
17. `verify_receipt` scopes by `actor_token` when `actor_id` is NULL (no cross-actor leakage)
18. Migrator: idempotent; leaves already-v2 entries alone; system entries get NULL token+salt; same-actor entries share the same actor_token

## Trust model — what the chain proves and doesn't

This is the architectural framing it took a beat to surface clearly. Worth being explicit:

**The chain proves:** *this Harmonic instance has not altered its own records since writing them.* The DB-level immutability trigger blocks modification; every entry's hash links to the next; any retroactive change breaks verification. This is a real and useful guarantee — it bounds operator misbehavior to "honest at write time, then can't covertly change later."

**The chain does not prove:**

1. **That the named actors actually performed the actions.** Audit entries are server-written; the actor does not cryptographically sign. The operator could fabricate entries under a user's identity at write time and the chain wouldn't object.
2. **For imported decisions, that any of the recorded actions ever occurred.** An imported audit chain is just data the importing instance received. Anyone with database access on a source instance can hand-craft entries with whatever outcomes they want, compute the hash chain forward, fake actor tokens via SHA256 of any chosen inputs, and (for lotteries) pick any past drand round to use authentic-looking randomness. The verifier confirms internal consistency, not provenance.
3. **That every submission attempt was recorded.** The chain attests only to what the server accepted into the audit log. A vote dropped before being written leaves no trace.
4. **For lottery decisions, that the operator committed before drand revealed.** drand's value is unpredictability of *future* rounds. For native chains written in real time, this means the operator picked the round before knowing its randomness — a meaningful commitment. For imported chains constructed after the fact, the operator can look up drand's past output and choose entries to match. The drand check confirms arithmetic in this case, not honesty.

**What would close these gaps (all deferred or out of scope):**

- Public timestamped log of `entry_hash` values (drand-style beacon, blockchain, certificate transparency log) committed at write time, so a verifier can prove a hash existed at a specific moment.
- Actor cryptographic signing of each action with keys the verifier trusts. Shifts the trust unit from "the operator" to "each actor."
- Cross-instance witnessing where multiple Harmonic instances co-attest events.

None of these exist in Harmonic today.

**Implications for surfaces:**

- The verify page now includes an explicit "What this verification proves and doesn't" section honestly disclaiming the limits.
- An imported-decision banner fires at the top of the verify page (HTML + Markdown) when any entry in the chain is imported, calling out that the checks "cannot prove the imported actions actually happened" and that trust in imported decisions depends on trust in whoever produced the imported data.
- The `:imported` binding status (introduced in this work) makes imported entries distinguishable in the data layer, so future UI or admin tooling can render the trust tier accurately.
- Privacy-policy or marketing language about audit chains should phrase the guarantee as "no covert modification by this operator" rather than "these actions really happened." The former is true; the latter overstates.

## Out of scope

- The actual user-account-closure flow — Phase 3
- Tombstoning of decisions on hard-delete — Phase 5
- Cross-instance chain integrity preservation — deferred
- Public timestamped commitment of entry hashes — would close gap #2 above; out of scope

## Phase 3 prerequisites (not part of this plan)

When Phase 3 wires the account-closure flow, it must enforce one invariant `record!` doesn't enforce on its own:

- **Scrubbed actors must not produce new audit entries.** `record!` looks up the first prior entry by `(decision_id, actor_id) WHERE actor_token_salt IS NOT NULL` to anchor the salt and handle. If every prior entry by that actor has been scrubbed, the lookup misses and `record!` generates a fresh salt, producing a *different* `actor_token` from the actor's preserved earlier entries. `replay_vote_totals` would then count that actor twice. The natural place to enforce this is the auth layer (scrubbed accounts can't sign in, so they can't trigger `record!`) — but Phase 3 should pin it explicitly.

## Sequencing

This work unblocks the privacy policy commitment around deletion. With the architecture in place, the policy can confidently say:

> When you close your account, we will scrub your name, handle, email, and other identifying details from records of group decisions you participated in. The decisions themselves and their outcomes are preserved, with your participation marked as `[deleted account]`. The cryptographic audit trail that proves these decisions weren't tampered with continues to function correctly.
