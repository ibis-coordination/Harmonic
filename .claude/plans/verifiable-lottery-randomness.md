# Verifiable Lottery Randomness

## Context

Currently, lottery decisions assign each option a `random_id` via PostgreSQL's `random()` at creation time. This means users must trust that the server didn't manipulate the numbers. The goal is to make lottery outcomes **independently verifiable** — given the inputs, anyone can prove the outcome wasn't rigged.

## Approach: drand Beacon + Deterministic Hashing

[drand](https://drand.love) is a distributed randomness beacon that publishes publicly verifiable random values on a fixed schedule. The scheme:

1. **Commitment phase** (lottery is open): Users add entries. Titles are the committed inputs — visible to all participants and not server-controlled.
2. **Round determination** (deterministic from deadline): The drand round is computed as the first round whose timestamp >= the decision's deadline. Formula: `round = floor((deadline_unix - genesis_time) / period) + 1`. Nobody chooses the round — it's a mathematical consequence of the deadline.
3. **Draw phase** (after deadline): A background job fetches the predetermined drand round's randomness.
4. **Sorting**: For each option, compute `sort_key = SHA256(beacon_randomness || NFC(option_title))`. Sort by sort_key. Titles are NFC-normalized before hashing to prevent unicode encoding tricks.
5. **Verification**: Display the beacon round number and a link to look it up. Anyone can recompute the SHA256 hashes and verify the ordering.

**Security properties**:
- Option titles are committed before the beacon value is known, and are user-visible so they can't be retroactively tampered with.
- The beacon value is produced by a distributed network that nobody controls.
- The round is deterministic from the deadline — nobody can shop for a favorable round.
- Using titles (not server-generated IDs) is critical — users need to verify inputs they can see.
- Unicode NFC normalization prevents encoding-based manipulation.

## UX Changes

**While lottery is open:**
- No change — entries already show in creation order, results only appear after closing.

**When lottery closes:**
- Close immediately (set deadline), then fetch drand beacon asynchronously via background job
- While beacon is pending: show "Drawing..." state instead of results
- Once beacon is fetched: display ranked results with a "Verification" section showing:
  - The drand round number used
  - Link to look up the round on drand's public API
  - The formula: `SHA256(beacon_hex + option_title)`
  - Each option's computed sort key (so users can verify with any SHA256 tool)

## Database Migration

Add columns to `decisions`:
- `lottery_beacon_round` (bigint, nullable) — the drand round number used
- `lottery_beacon_randomness` (string, nullable) — the hex randomness value from that round

No changes to `options` table — sort keys are derived deterministically at display time.

## Implementation

### 1. Randomness Provider Interface

All providers implement the same interface — return a hash with `{ round:, randomness: }` and a verification URL. The provider is selected via `LOTTERY_RANDOMNESS_PROVIDER` env var (default: `drand`).

#### `RandomnessProvider::Drand` (new: `app/services/randomness_provider/drand.rb`)
- Chain: quicknet (see `CHAIN_HASH` in `app/services/randomness_provider/drand.rb`)
- Genesis: `1692803367`, period: `3` seconds
- `round_for_timestamp(timestamp)` — `floor((timestamp - genesis) / period) + 1`
- `fetch_round(round_number)` — GET `https://api.drand.sh/{chain}/public/{round}`
- `verification_url(round)` — returns the public drand API URL for that round
- Uses `Net::HTTP` (no gem needed)

#### `RandomnessProvider::Test` (new: `app/services/randomness_provider/test.rb`)
- Returns a deterministic/configurable randomness value for testing
- `verification_url` returns nil or a placeholder

#### `RandomnessProvider.current` (new: `app/services/randomness_provider.rb`)
- Factory method that returns the configured provider based on env var
- Self-hosters can add their own provider class and set the env var

### 2. `LotteryService` (new: `app/services/lottery_service.rb`)

Provider-agnostic lottery logic. Receives randomness, doesn't care where it came from.

- `draw!(decision)` — called when a lottery decision closes:
  1. Compute the target round from `decision.deadline` via the provider
  2. Fetch that round's randomness from `RandomnessProvider.current`
  3. Store `lottery_beacon_round` and `lottery_beacon_randomness` on decision
  4. Return the decision
- `compute_sort_key(beacon_randomness, option_title)` — `Digest::SHA256.hexdigest(beacon_randomness + option_title.unicode_normalize(:nfc))`
- `compute_results(decision)` — for each option, compute sort key and return sorted array
- `verification_url(decision)` — delegates to the provider

### 3. Model Changes (`app/models/decision.rb`)

- `lottery_drawn?` — returns true if `lottery_beacon_round.present?`
- Update `results` method: for lottery decisions that have been drawn, sort results by computed sort key instead of `random_id`
- Include beacon info in `api_json` for lottery decisions

### 4. Close Flow (`app/services/api_helper.rb`)

In `close_decision`, after setting the deadline:
```ruby
if decision.is_lottery?
  LotteryDrawJob.perform_later(decision.id)
end
```

### 5. Background Job (new: `app/jobs/lottery_draw_job.rb`)

- Computes the target round from the decision's deadline
- If the round hasn't been published yet (deadline is in the near future), schedules itself to retry after the deadline passes
- Calls `LotteryService.new.draw!(decision)` to fetch the predetermined round and store data
- Retries on failure (drand unreachable) with exponential backoff
- On success, broadcasts a Turbo Stream to update the results section

### 6. View Changes

#### Results partial (`app/views/decisions/_results.html.erb`)
- For lottery: replace `random_id` column with `sort key` column showing truncated SHA256
- When lottery is drawn: show verification section at bottom of results

#### Show page (`app/views/decisions/show.html.erb`)
- While open: no change (entries in creation order, no results)
- When closed but beacon pending (`lottery_drawn?` is false): show "Drawing..." spinner/message
- When closed + drawn: show results with verification info

#### New partial: `app/views/decisions/_lottery_verification.html.erb`
- Brief summary: "This lottery uses verifiable randomness"
- Link to the full verification page at `/d/:id/verify`

### 7. Verification Page

**Route**: `GET /d/:id/verify` → `decisions#verify`

**View**: `app/views/decisions/verify.html.erb`

Full verification page with everything needed to independently reproduce the results:
- The decision's deadline and how the round was determined from it (`round = floor((deadline - genesis) / period) + 1`)
- The drand beacon round number and randomness value used
- Link to look up the round on the provider's public API
- The formula: `sort_key = SHA256(beacon_hex + NFC(option_title))`
- A table listing every option with:
  - Option title
  - Full SHA256 input string (`beacon_hex + title`)
  - Computed sort key (full hex)
  - Resulting position
- Step-by-step instructions for manual verification (e.g., using `echo -n "..." | sha256sum` in a terminal)
- Only accessible for lottery decisions that have been drawn; redirects otherwise

### 8. Markdown/API view (`app/views/decisions/show.md.erb`)
- Include verification section with beacon round and URL
- Show sort key for each result

### 9. Results View (`decision_results` SQL view)

No changes to the SQL view itself. For lottery decisions, the Ruby `results` method will re-sort the view results using the beacon-derived keys. The SQL view still provides the base data (option titles, vote counts, etc.) — we just override the ordering.

### 10. Help Documentation (`app/views/help/lottery_decisions.md.erb`)

Update to explain:
- How verifiable randomness works
- What the drand beacon is
- How to independently verify results
- Link to drand's website

## Testing

### Model tests (`test/models/decision_test.rb`)
- `LotteryService.compute_sort_key` returns deterministic SHA256
- `LotteryService.compute_results` sorts correctly by sort key
- `draw!` stores beacon data on decision
- `results` for drawn lottery returns beacon-sorted order

### Service tests (new: `test/services/lottery_service_test.rb`, `test/services/randomness_provider_test.rb`)
- `RandomnessProvider::Drand` parses drand API response correctly (mock HTTP)
- `RandomnessProvider::Test` returns deterministic values
- `RandomnessProvider.current` returns the correct provider based on env var
- `LotteryService.draw!` fetches and stores beacon data (uses Test provider)
- Sort key computation is deterministic and matches manual SHA256

### Controller tests (`test/controllers/decisions_controller_test.rb`)
- Closing a lottery triggers beacon fetch and stores data
- Closed lottery show page includes verification info
- Open lottery shows entries without ranking

## Verification

```bash
docker compose exec web bundle exec rails test test/models/decision_test.rb test/services/lottery_service_test.rb test/services/randomness_provider_test.rb test/controllers/decisions_controller_test.rb
docker compose exec web bundle exec rubocop
docker compose exec web bundle exec srb tc
```

Manual: Create a lottery, add entries, close it, verify:
- Results show SHA256-based ordering
- Verification section shows beacon round + link
- Clicking the drand link shows the same randomness value
- Computing `SHA256(beacon_hex + option_title)` manually matches displayed sort keys
