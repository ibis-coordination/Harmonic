# Decision Audit Chain (Tamper-Evident Hash Chain for All Decisions)

## Context

Vote decisions show individual votes publicly, allowing voters to verify their own vote was recorded and that totals add up. However, there's no cryptographic guarantee that votes weren't tampered with by the server — votes could be silently altered, dropped, or fabricated. We want a tamper-evident audit chain that anyone can independently verify.

The approach: a per-decision append-only hash chain where each action (options added, votes cast, decision closed, beacon drawn) gets a cryptographic entry. If any entry is modified or removed, all subsequent hashes break. The chain hash is finalized after the last entry, and the full chain is available on the verify page.

All decision types (vote, lottery, executive) have an audit chain, which simplifies the user model — every decision is verifiable.

## Data Model

### New table: `decision_audit_entries`

| Column | Type | Description |
|--------|------|-------------|
| `id` | uuid | Primary key |
| `tenant_id` | uuid | FK to tenants |
| `collective_id` | uuid | FK to collectives |
| `decision_id` | uuid | FK to decisions (indexed) |
| `sequence_number` | integer | Position in the chain (1-indexed, unique per decision) |
| `schema_version` | integer | Version of the hash formula used (starts at 1) |
| `action` | string | `"option_added"`, `"option_removed"`, `"vote_cast"`, `"vote_updated"`, `"executive_selection"`, `"decision_closed"`, or `"beacon_drawn"` |
| `actor_id` | uuid | User ID of the person who performed the action |
| `actor_handle` | string | Handle snapshot at time of action |
| `option_title` | string | The option's title at time of action (snapshot) |
| `accepted` | integer | 0 or 1 (null for non-vote actions) |
| `preferred` | integer | 0 or 1 (null for non-vote actions) |
| `metadata` | jsonb | Additional action-specific data (null for most actions) |
| `previous_hash` | string | Hex hash of the previous entry (null for first entry) |
| `entry_hash` | string | SHA-256 hex hash of this entry's data |
| `created_at` | datetime | Timestamp of this audit entry |

**Key design choices:**
- Store `actor_id` (canonical UUID) and `actor_handle` (human-readable snapshot). The ID is for verification, the handle is for readability.
- Store `option_title` as a string snapshot, not FK. This makes the chain self-contained and independently verifiable without needing DB access.
- `sequence_number` makes ordering unambiguous and makes it easy to detect gaps.
- All decision types (vote, lottery, executive) have an audit chain.
- Actions: `option_added`, `option_removed`, `vote_cast`, `vote_updated`, `executive_selection`, `decision_closed`, `beacon_drawn`.
- `accepted`/`preferred` are null for non-vote actions.
- `metadata`: null for most actions; `beacon_drawn` stores `{ round:, randomness: }`; `executive_selection` stores `{ selected_option_titles: [...] }`.
- `actor_id`/`actor_handle` are null for `beacon_drawn` (system action).
- `option_title` is null for `beacon_drawn`, `decision_closed`, and `executive_selection`.
- No `updated_at` — entries are immutable once written.

### Hash computation (Version 1)

```
entry_hash = SHA256(
  "v1" + "|" +
  previous_hash + "|" +
  sequence_number + "|" +
  action + "|" +
  actor_id + "|" +
  actor_handle + "|" +
  NFC(option_title) + "|" +
  accepted + "|" +
  preferred + "|" +
  sorted_json(metadata) + "|" +
  ISO8601(created_at)
)
```

- `|` delimiter, NFC-normalized option titles (consistent with beacon sort keys).
- First entry uses empty string for `previous_hash`.
- Null fields are empty strings.
- `sorted_json(metadata)` is JSON with keys sorted alphabetically (empty string if null).
- Version prefix `"v1"` included in hash so verifiers know which formula to use. Future formula changes use a new version number while old entries remain verifiable.

### Decision model additions

| Column | Type | Description |
|--------|------|-------------|
| `audit_chain_hash` | string | Final chain hash, set once after last entry |

Set after `beacon_drawn` entry for vote/lottery decisions, or after `decision_closed` entry for executive decisions.

## Architecture

Four services with clear responsibilities:

| Service | Responsibility |
|---------|---------------|
| **`DecisionAuditEntry`** | Thin AR model. Associations, validations, constants. |
| **`DecisionAuditService`** | Records audit entries: hash computation, chain linking, row locking, retry logic. |
| **`DecisionAuditVerifier`** | Verification: recomputes hashes, checks chain integrity. Used by integrity job and verify controller. |
| **`DecisionActionService`** | Chokepoint for all audited mutations. Wraps mutation + audit in a single transaction. `api_helper.rb` delegates to it. |

## Implementation

### Step 1: Migration

- Create `decision_audit_entries` table with all columns above
- Add `audit_chain_hash` column to `decisions` (string, nullable)
- Add unique index on `(decision_id, sequence_number)`
- Add index on `decision_id`
- Create DB triggers for integrity protection (see Integrity Protection section)

### Step 2: DecisionAuditEntry model

**File**: `app/models/decision_audit_entry.rb`

Thin AR model:
- `belongs_to :tenant`, `belongs_to :collective`, `belongs_to :decision`
- `self.implicit_order_column = "sequence_number"`
- Constant `ACTIONS = %w[option_added option_removed vote_cast vote_updated executive_selection decision_closed beacon_drawn].freeze`
- Constant `CURRENT_SCHEMA_VERSION = 1`
- Validations: action inclusion, schema_version presence

### Step 3: DecisionAuditService

**File**: `app/services/decision_audit_service.rb`

Recording and hash computation:
- `record_vote!(decision:, vote:, actor:)` — determines `vote_cast` vs `vote_updated`
- `record_option!(decision:, option:, actor:, action:)` — `option_added` or `option_removed`
- `record_close!(decision:, actor:)`
- `record_executive_selection!(decision:, actor:, selected_option_titles:)`
- `record_beacon!(decision:, round:, randomness:)`
- Private `record!(...)`:
  1. Returns nil if `!decision.audit_chain_enabled?`
  2. Locks `decision` row to prevent concurrent chain corruption
  3. Finds last entry by sequence_number
  4. Computes entry hash via version-specific method (`compute_hash_v1`)
  5. Creates and returns entry
  6. Retries up to 3 times on transient DB errors

### Step 4: DecisionAuditVerifier

**File**: `app/services/decision_audit_verifier.rb`

Verification logic (separate from recording):
- `verify_chain(decision)` — recomputes all hashes, checks links, returns pass/fail with details
- `verify_entry(entry)` — recomputes single entry hash, compares
- `hash_input(entry)` — canonical string being hashed, dispatches by `schema_version`

Used by the integrity check job and the verify controller action.

### Step 5: DecisionActionService (chokepoint)

**File**: `app/services/decision_action_service.rb`

Single entry point for all audited mutations. `api_helper.rb` delegates to this.

```ruby
class DecisionActionService
  def self.cast_vote!(decision:, vote:, actor:)
    ActiveRecord::Base.transaction do
      vote.save!
      audit_entry = DecisionAuditService.record_vote!(decision: decision, vote: vote, actor: actor)
      audit_entry # returned so caller can include receipt in response
    end
  end

  def self.add_option!(decision:, option:, actor:)
    ActiveRecord::Base.transaction do
      option.save!
      DecisionAuditService.record_option!(decision: decision, option: option, actor: actor, action: "option_added")
    end
  end

  def self.close_decision!(decision:, actor:, executive_selections: nil)
    ActiveRecord::Base.transaction do
      decision.update!(deadline: Time.current)
      DecisionAuditService.record_close!(decision: decision, actor: actor)
      if executive_selections
        DecisionAuditService.record_executive_selection!(
          decision: decision, actor: actor, selected_option_titles: executive_selections,
        )
      end
      if decision.is_executive?
        last_entry = DecisionAuditEntry.where(decision_id: decision.id).order(:sequence_number).last
        decision.update!(audit_chain_hash: last_entry&.entry_hash)
      end
    end
  end

  def self.draw_beacon!(decision:, round:, randomness:)
    ActiveRecord::Base.transaction do
      decision.update!(lottery_beacon_round: round, lottery_beacon_randomness: randomness)
      entry = DecisionAuditService.record_beacon!(decision: decision, round: round, randomness: randomness)
      decision.update!(audit_chain_hash: entry&.entry_hash)
    end
  end
end
```

### Step 6: Update api_helper.rb and LotteryService to delegate

**File**: `app/services/api_helper.rb`

Replace direct vote/option/close mutation with calls to `DecisionActionService`. api_helper still handles validation, authorization, param parsing, representation session events, etc.

**File**: `app/services/lottery_service.rb`

Replace direct `decision.update!` with `DecisionActionService.draw_beacon!`.

### Step 7: Show audit receipt to voters

`DecisionActionService.cast_vote!` returns the audit entry. api_helper passes the receipt to the response:

- **API response**: `audit_receipt: entry.entry_hash` in the vote JSON
- **HTML interface**: Subtle dismissible notice after vote submission with copy button
- **Vote updates**: New receipt; previous receipts remain valid in chain

### Step 8: Email audit receipts

**Files**: Notification mailer or existing notification system

Include the receipt hash in the vote notification email:

> Your vote on "Which option do we choose?" was recorded.
> Audit receipt: `a7f3b2c8...`
> You can verify this receipt on the decision's verify page after it closes.

Every voter's email provider becomes an independent timestamp witness.

### Step 9: Real-time chain visibility

**File**: `app/views/decisions/show.html.erb`

Show current chain state while the decision is open:

> Audit chain: 12 entries · latest hash: `a7f3b2...`

Updates via existing polling/Turbo refresh. After close + beacon, becomes a link to the verify page.

### Step 10: Verify page — audit chain section

**File**: `app/views/decisions/verify.html.erb`

New section showing the full chain with explanation:

> **Audit Chain**
>
> Every action on this decision — options added, votes cast, votes changed, and the random tiebreaker — is recorded in a tamper-evident chain. Each entry includes a cryptographic hash of the previous entry, so if any record were altered, inserted, or removed after the fact, the chain would break. You can independently replay the chain to verify that the results shown match the votes recorded.
>
> **What this proves:** No recorded votes were changed, inserted, or removed after they were cast. The tiebreaker values are derived from a public randomness beacon and cannot be manipulated. Anyone can replay the chain to independently derive the final results.
>
> **What this does not prove:** The audit chain verifies the integrity of votes that were recorded, but it cannot prove that the server accepted every vote that was submitted. If a vote was never recorded (e.g., due to a server error), it would not appear in the chain. Voters can check that their own votes are present by reviewing the chain or the voters page.

Chain table, hash formula, and Python verification snippet.

### Step 11: Controller — verify action updates

**File**: `app/controllers/decisions_controller.rb`

Load audit entries in the `verify` action:
```ruby
@audit_entries = DecisionAuditEntry.where(decision_id: @decision.id).order(:sequence_number)
```

### Step 12: JSON endpoint for programmatic verification

**Route**: `GET /collectives/:handle/d/:id/verify.json`

Respond to JSON format in the `verify` action. Response includes everything needed for independent verification: decision metadata, beacon data, full audit chain, and results.

### Step 13: verify.md.erb — markdown API

Same chain table in markdown format.

### Step 14: Audit receipts in API responses

No new event types — `DecisionAuditEntry` is a verification layer, not a user-facing action. Existing `Tracked` concern fires `vote.created`/`vote.updated` for automations/webhooks. The receipt is included in API responses and email notifications. Automations needing the receipt can use the verify JSON endpoint.

### Step 15: Update documentation

**Help topics (user-facing):**
- `app/views/help/decisions.md.erb` — Add section on the audit chain: what it is, what it proves, what it doesn't prove, how to verify, audit receipts
- `app/views/help/lottery_decisions.md.erb` — Mention the audit chain covers lotteries too
- `app/views/help/executive_decisions.md.erb` — Mention audit chain for executive decisions

**Internal docs (developer-facing):**
- `docs/ARCHITECTURE.md` — Document the audit chain architecture: `DecisionAuditEntry` model, `DecisionAuditService`, `DecisionAuditVerifier`, `DecisionActionService` as the mutation chokepoint. Update the Decision model diagram to show `has_many :decision_audit_entries`. Document that all vote/option mutations must go through `DecisionActionService`.
- `docs/SECURITY_AND_SCALING.md` — Add section on vote integrity: the four protection layers (static check, immutable entries trigger, closed-vote trigger, integrity job), the hash chain design, and the audit receipt system.
- `docs/API.md` — Document the verify JSON endpoint (`GET /d/:id/verify.json`), the `audit_receipt` field in vote API responses, and the `audit_chain_hash` field in decision responses.

### Step 16: Static analysis check

**File**: `scripts/check-audit-safety.sh`

Pre-commit/CI check that bans direct Vote/Option mutation outside `DecisionActionService`:
- Scans for `Vote.create`, `Vote.new`, `vote.save`, `vote.update`, `Option.create`, `option.save` etc. in `app/` excluding `decision_action_service.rb` and test files
- Clear error message explaining the constraint and where to go

Added to pre-commit hooks alongside existing checks (`check-tenant-safety.sh`, `check-debug-code.sh`, etc.).

### Step 17: Tests

- `test/models/decision_audit_entry_test.rb`:
  - Hash computation is deterministic
  - Chain links correctly (previous_hash matches prior entry's hash)
  - Tampering with any field causes hash mismatch
  - Vote entries have accepted/preferred, option entries have nil

- `test/services/decision_audit_service_test.rb`:
  - record_vote! creates entry with correct action and fields
  - record_option! creates entry with correct action
  - record_beacon! creates entry with metadata
  - Chain builds correctly across multiple entries
  - Retry logic handles transient failures

- `test/services/decision_audit_verifier_test.rb`:
  - verify_chain passes for valid chain
  - verify_chain fails for tampered entries
  - verify_chain fails for gaps in sequence numbers

- `test/services/decision_action_service_test.rb`:
  - cast_vote! creates vote + audit entry in same transaction
  - add_option! creates option + audit entry
  - close_decision! records close + sets chain hash for executive
  - draw_beacon! records beacon + sets chain hash
  - Transaction rolls back both vote and audit entry on failure

- `test/controllers/decisions_controller_test.rb`:
  - Verify page shows audit chain
  - JSON endpoint returns structured chain data
  - JSON endpoint requires beacon drawn / decision closed

- `test/jobs/audit_chain_integrity_job_test.rb`:
  - Detects votes without audit entries
  - Detects invalid chain hashes
  - Detects sequence number gaps
  - Passes for valid chains

## Integrity Protection

Four layers of defense:

### Layer 1: Static analysis check (pre-commit/CI)

**File**: `scripts/check-audit-safety.sh`

Bans direct Vote/Option mutation outside `DecisionActionService`. Runs in pre-commit hooks and CI. Catches the most common mistake: a developer writing `vote.save!` in a new service without knowing about the audit chain.

### Layer 2: Immutable audit entries (DB trigger)

PostgreSQL trigger preventing UPDATE and DELETE on `decision_audit_entries`:

```sql
CREATE FUNCTION prevent_audit_entry_mutation() RETURNS TRIGGER AS $$
BEGIN
  RAISE EXCEPTION 'decision_audit_entries are immutable';
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER enforce_audit_entry_immutability
  BEFORE UPDATE OR DELETE ON decision_audit_entries
  FOR EACH ROW EXECUTE FUNCTION prevent_audit_entry_mutation();
```

### Layer 3: Prevent vote mutation after close (DB trigger)

PostgreSQL trigger preventing INSERT/UPDATE/DELETE on `votes` when the decision is closed:

```sql
CREATE FUNCTION prevent_vote_mutation_after_close() RETURNS TRIGGER AS $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM decisions
    WHERE id = COALESCE(NEW.decision_id, OLD.decision_id)
    AND deadline < NOW()
  ) THEN
    RAISE EXCEPTION 'Votes cannot be modified after the decision is closed';
  END IF;
  RETURN COALESCE(NEW, OLD);
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER enforce_vote_immutability_after_close
  BEFORE INSERT OR UPDATE OR DELETE ON votes
  FOR EACH ROW EXECUTE FUNCTION prevent_vote_mutation_after_close();
```

### Layer 4: Periodic integrity check job

**File**: `app/jobs/audit_chain_integrity_job.rb`

Verifies:
- Every vote (on audit-chain-enabled decisions) has corresponding audit entries
- All chain hashes are valid (recompute and compare)
- Final chain hash matches `decision.audit_chain_hash`
- No gaps in sequence numbers

Logs warnings/alerts on mismatches. Runs periodically or on-demand.

## Edge Cases

**Existing decisions:** No audit chain for decisions created before deployment. Verify page only shows audit section when entries exist.

**Open decisions at deployment:** Only record audit entries for decisions created after deployment (`decision.audit_chain_enabled?` checks `created_at >= AUDIT_CHAIN_LAUNCH_DATE`). Avoids partial chains.

**Cascade-deleted votes:** Audit entries remain after vote cascade deletion. The closed-vote DB trigger (layer 3) prevents this after close.

## Files to create/modify

| File | Change |
|------|--------|
| `db/migrate/XXXX_create_decision_audit_entries.rb` | New migration (table + triggers) |
| `app/models/decision_audit_entry.rb` | New model (thin) |
| `app/services/decision_audit_service.rb` | New service (recording + hashing) |
| `app/services/decision_audit_verifier.rb` | New service (verification) |
| `app/services/decision_action_service.rb` | New service (chokepoint) |
| `app/services/api_helper.rb` | Delegate to DecisionActionService |
| `app/services/lottery_service.rb` | Delegate to DecisionActionService |
| `app/models/decision.rb` | Add `audit_chain_enabled?` method |
| `app/controllers/decisions_controller.rb` | Load audit entries, JSON endpoint |
| `config/routes.rb` | Add verify.json format (if needed) |
| `app/views/decisions/show.html.erb` | Real-time chain visibility |
| `app/views/decisions/verify.html.erb` | Audit chain section + Python snippet |
| `app/views/decisions/verify.md.erb` | Audit chain section |
| `app/views/help/decisions.md.erb` | Document audit chain (user-facing) |
| `app/views/help/lottery_decisions.md.erb` | Mention audit chain |
| `app/views/help/executive_decisions.md.erb` | Mention audit chain |
| `docs/ARCHITECTURE.md` | Audit chain architecture, DecisionActionService chokepoint |
| `docs/SECURITY_AND_SCALING.md` | Vote integrity, four protection layers |
| `docs/API.md` | Verify JSON endpoint, audit_receipt in responses |
| Notification mailer | Email audit receipts |
| `scripts/check-audit-safety.sh` | Static analysis check |
| `app/jobs/audit_chain_integrity_job.rb` | Integrity check job |
| `test/models/decision_audit_entry_test.rb` | Model tests |
| `test/services/decision_audit_service_test.rb` | Service tests |
| `test/services/decision_audit_verifier_test.rb` | Verifier tests |
| `test/services/decision_action_service_test.rb` | Action service tests |
| `test/controllers/decisions_controller_test.rb` | Controller tests |
| `test/jobs/audit_chain_integrity_job_test.rb` | Integrity job tests |

## Implementation Notes (context for post-compaction)

### Key existing methods in api_helper.rb

- **`vote()`** (lines ~615-643): Single vote create/update for REST API v1. Uses `Vote.find_by(associations) || Vote.new(associations)`, then `vote.save!`. Delegate to `DecisionActionService.cast_vote!`.
- **`create_votes()`** (lines ~645-694): Bulk vote create/update. Same find-or-create pattern in a transaction. Delegate to `DecisionActionService.cast_vote!` per vote.
- **`close_decision()`** (lines ~909-941): Sets `deadline = Time.current`, creates executive selections if executive, triggers `LotteryDrawJob` if lottery/vote. Delegate close + audit to `DecisionActionService.close_decision!`.
- **Option creation** (lines ~580-612): `create_options` method, creates `Option.create!` in a transaction. Delegate to `DecisionActionService.add_option!`.
- **`update_option()`** (lines ~1094-1110): Updates option title. Consider whether title changes need an audit entry.
- **`delete_option()`** (lines ~1112-1120): Destroys option. Delegate to `DecisionActionService` with `option_removed` action.
- **`duplicate_decision()`** (lines ~1122+): Creates a copy. New decision, so audit chain starts fresh — no special handling needed.

### Existing notification system

- `EventService.record!` → `NotificationDispatcher.dispatch(event)` → `NotificationService.create_and_deliver!`
- Vote events dispatch `"decision.voted"` which notifies the decision creator
- `NotificationService.create_and_deliver!` accepts `channels: ["in_app"]` (default). Email channel available.
- For audit receipts: either extend the existing vote notification to include the receipt hash, or create a new notification type.
- Mailers: `NotificationMailer` exists for email delivery.

### Tracked concern timing

The `Tracked` concern uses `after_create_commit` / `after_update_commit` — these fire AFTER the transaction commits. The audit entry is created INSIDE the transaction. So the order is:
1. Transaction: `vote.save!` + `DecisionAuditEntry` created
2. Transaction commits
3. `Tracked` fires → `EventService.record!` → notifications/automations

This means the audit entry exists before the notification fires. The receipt hash is available.

### Test patterns

- `create_tenant_collective_user` — creates a tenant, collective, and user for test setup
- `sign_in_as(@user, tenant: @tenant)` — signs in for controller tests
- `Tenant.scope_thread_to_tenant(subdomain:)` / `Collective.scope_thread_to_collective(...)` — set thread-local scoping for test setup
- `DecisionParticipantManager.new(decision:, user:).find_or_create_participant` — creates participant
- Existing test files: `test/models/decision_test.rb`, `test/services/lottery_service_test.rb`, `test/controllers/decisions_controller_test.rb`

### Existing static analysis scripts

Located in `scripts/`. Run in pre-commit hooks and CI:
- `check-tenant-safety.sh` — bans `.unscoped`
- `check-debug-code.sh` — bans `binding.pry`, `console.log`, etc.
- `check-job-inheritance.sh` — checks job base classes
- `check-audit-safety.sh` (NEW) — will ban direct Vote/Option mutation outside `DecisionActionService`

### LotteryService.draw! (to be refactored)

Currently in `app/services/lottery_service.rb` lines 12-24:
- Validates lottery/vote subtype
- Calls `@provider.round_for_timestamp(deadline)`
- Calls `@provider.fetch_round(round_number)`
- Calls `decision.update!(lottery_beacon_round:, lottery_beacon_randomness:)`
- Refactor: replace `decision.update!` with `DecisionActionService.draw_beacon!`

### Multi-tenancy

- `Tenant.current_id` and `Collective.current_id` thread-locals required for model operations
- Background jobs use `TenantScopedJob` base class with `set_tenant_context!(decision.tenant)`
- `DecisionAuditEntry` needs `belongs_to :tenant` + `before_validation :set_tenant_id` (standard pattern)

### Decision.audit_chain_enabled?

New method on `app/models/decision.rb`:
```ruby
AUDIT_CHAIN_LAUNCH_DATE = Time.utc(2026, ...) # set to deployment date

def audit_chain_enabled?
  created_at >= AUDIT_CHAIN_LAUNCH_DATE
end
```

## Manual Verification

1. Create a vote decision with 2+ options
2. Cast votes from multiple users — confirm receipt shown
3. Update a vote — confirm new receipt
4. Check email for receipt
5. Confirm chain visibility on decision page while open
6. Close the decision
7. Visit verify page — confirm audit chain displayed
8. Confirm chain hashes link correctly
9. Confirm chain hash matches `decision.audit_chain_hash`
10. Hit verify.json endpoint — confirm structured data
11. Use Python snippet to independently verify the chain
12. Run all tests
