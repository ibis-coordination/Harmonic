# Audit Chain Verification Implementations

## Context

The audit chain currently has one verification path: a Python script (`scripts/verify-audit-chain.py`) that users must download and run independently. This creates friction — most users won't bother. We need:

1. **Client-side TypeScript verification** — runs automatically in the browser on the verify page
2. **Server-side Ruby verification via markdown** — AI agents see results inline when reading `Accept: text/markdown`

All three implementations (Python, TypeScript, Ruby) must produce identical results for the same input.

## Phase 1: Extend Ruby Verifier

`DecisionAuditVerifier` currently only verifies chain integrity (hash recomputation + chain links). Extend it to also verify vote tallies and beacon, matching what the Python script does.

### Files
- `app/services/decision_audit_verifier.rb` — add `verify_vote_tallies`, `verify_beacon`, `verify_all`
- `test/services/decision_audit_verifier_test.rb` — tests for each new method

### New methods

**`verify_vote_tallies(decision)`**
- Replay `vote_cast`/`vote_updated` audit entries, keep latest per (actor_id, option_title)
- Sum accepted/preferred per option, compare against `decision.results`
- Return `{ valid:, errors: }`

**`verify_beacon(decision, fetched_randomness:)`**
- Derive expected round from deadline via `RandomnessProvider`
- Compare round against `decision.lottery_beacon_round`
- Recompute sort keys: `SHA256(randomness + NFC(option_title))`
- Accept randomness as parameter (caller fetches — keeps it testable)
- Return `{ valid:, errors: }`

**`verify_all(decision, fetched_randomness: nil)`**
- Calls all three checks, returns `{ chain:, vote_tallies:, beacon:, valid: }`

## Phase 2: Wire Ruby Verification into Markdown Response

### Files
- `app/controllers/decisions_controller.rb` — call `verify_all` for `format.md`
- `app/views/decisions/verify.md.erb` — add verification results section

The markdown verify page gets a "Verification Results" section at the top showing pass/fail for each check. AI agents reading the markdown see verification status inline without needing to run anything.

## Phase 3: TypeScript Verification Library

Pure-function async library with no DOM dependencies. Uses Web Crypto API (`crypto.subtle.digest`) for SHA-256.

### Files
- `app/javascript/lib/audit_chain_verifier.ts` — verification functions
- `app/javascript/lib/audit_chain_types.ts` — TypeScript types for verify.json schema
- `app/javascript/lib/audit_chain_verifier.test.ts` — vitest tests

### Functions

**`verifyChain(data: VerifyData): Promise<ChainResult>`**
- Replay hashes using SubtleCrypto, check chain links, verify final hash
- NFC normalization via `String.prototype.normalize("NFC")`

**`verifyVoteTallies(data: VerifyData): VoteTalliesResult`**
- Synchronous — replay votes, sum totals, compare to results

**`verifyBeacon(data: VerifyData, fetchRandomness: (round: number) => Promise<string>): Promise<BeaconResult>`**
- Derive round from deadline (hardcoded drand params, same as Python)
- Fetch randomness via injected callback (testable)
- Recompute sort keys via SubtleCrypto

**`verifyAll(data: VerifyData, fetchRandomness?): Promise<VerificationResult>`**
- Runs all three, returns unified result

### Testing notes
- jsdom doesn't provide `crypto.subtle` — add `globalThis.crypto = require("node:crypto").webcrypto` to `app/javascript/test/setup.ts`
- Mock drand fetch in beacon tests
- Test against both valid and tampered data

## Phase 4: Stimulus Controller + Verify Page UI

### Files
- `app/javascript/controllers/audit_verify_controller.ts` — Stimulus controller
- `app/javascript/controllers/audit_verify_controller.test.ts` — vitest tests
- `app/javascript/controllers/index.ts` — register controller
- `app/views/decisions/verify.html.erb` — add verification results section

### Controller behavior
- `url` value: points to verify.json endpoint
- On connect: fetch JSON, run `verifyAll()`, render results into targets
- Targets for chain, vote tallies, beacon, and overall status
- Shows "Verifying..." while running, then pass/fail for each check
- Handles network failures gracefully (shows error, doesn't crash)
- `fetchRandomness` callback fetches from drand API directly (cross-origin, CORS supported)

### Verify page update
- New "Automated Verification" section before "Verify Independently"
- Uses the Stimulus controller to show live results
- The Python script section remains for independent verification

## Phase 5: Cross-Implementation Consistency Testing

### Approach
- Generate a static JSON fixture from a seeded decision lifecycle (Rake task or test helper)
- All three implementations verify the same fixture, all must agree
- The existing Python integration test (`test/integration/audit_chain_verification_test.rb`) already validates Python against Ruby-generated data — extend this pattern

### Files
- `test/fixtures/files/audit_chain_fixture.json` — canonical fixture (valid)
- `test/fixtures/files/audit_chain_fixture_tampered.json` — tampered variant
- Extend `test/integration/audit_chain_verification_test.rb` — Python against fixture
- `app/javascript/lib/audit_chain_verifier.test.ts` — TypeScript against same fixture
- Extend `test/services/decision_audit_verifier_test.rb` — Ruby against same fixture (via `verify_from_json`)

### Optional: `verify_from_json` on Ruby verifier
Add a JSON-based entry point to `DecisionAuditVerifier` that accepts parsed verify.json data (same format as the endpoint). This parallels how Python and TypeScript both operate on JSON directly, and enables fixture-based testing without ActiveRecord objects.

## Verification

- `docker compose exec web bundle exec rails test` — all Ruby tests pass
- `docker compose exec js npm test` — all vitest tests pass (including fixture consistency)
- `docker compose exec js npm run typecheck` — TypeScript compiles
- Manual: open verify page in browser, see automated verification results
- Manual: `curl -H "Accept: text/markdown"` on verify endpoint, see verification results inline
