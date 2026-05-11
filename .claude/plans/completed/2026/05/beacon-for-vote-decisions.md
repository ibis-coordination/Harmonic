# Verifiable Random Tiebreakers for Vote Decisions

## Context

Vote decisions currently use `options.random_id` (a Postgres-generated random integer) to break ties when acceptance and preference counts are equal. Lotteries already use an external randomness beacon (drand) to produce verifiably random sort keys. We want to extend the beacon to vote decisions so that tie-breaking is provably fair.

**Key difference from lotteries**: Vote decisions show in-progress results before closing. Since the beacon value isn't known until after the deadline, the random column should show "???" while the decision is open, with an explanation that final tie-breaking will happen at close time. After close, the beacon is fetched and the `lottery_sort_key` replaces `random_id` — exactly as lotteries work today.

The existing DB columns (`lottery_beacon_round`, `lottery_beacon_randomness`) and SQL view (`lottery_sort_key`) already work for any decision type. The main work is generalizing the guards, naming, job triggers, and UI copy.

## Plan

### Step 1: Generalize `lottery_drawn?` on Decision model

**File**: `app/models/decision.rb`

- Add a new method `beacon_drawn?` that checks `lottery_beacon_round.present?` without requiring `is_lottery?`
- Keep `lottery_drawn?` as-is for backward compat (it's used in a few places) or update it to delegate to `beacon_drawn?`
- Update `api_json` to include beacon data when `beacon_drawn?` (not just for lotteries)

```ruby
def beacon_drawn?
  lottery_beacon_round.present?
end

def lottery_drawn?
  is_lottery? && beacon_drawn?
end
```

### Step 2: Generalize LotteryService

**File**: `app/services/lottery_service.rb`

- Rename `draw!` validation: allow both lottery and vote subtypes (not just lottery)
- Or add a second method. Simplest: relax the guard from `is_lottery?` to `is_lottery? || is_vote?`

### Step 3: Generalize LotteryDrawJob

**File**: `app/jobs/lottery_draw_job.rb`

- Change the guard from `decision.is_lottery?` to `decision.is_lottery? || decision.is_vote?`
- The rest of the job logic (reschedule if deadline in future, call `LotteryService.new.draw!`) works as-is

### Step 4: Trigger beacon fetch for vote decisions on close

**File**: `app/services/api_helper.rb` (line ~936)

- Change `if decision.is_lottery?` to `if decision.is_lottery? || decision.is_vote?`

### Step 5: Update results partial

**File**: `app/views/decisions/_results.html.erb`

Three changes:

**a) Random column cells (lines 34-40)**: Add a third branch for vote decisions that are closed but not yet beacon-drawn:
```erb
<% if @decision.beacon_drawn? %>
  <td ...><%= result.lottery_sort_key&.slice(0, 3) %>...</td>
<% elsif @decision.is_vote? && @decision.closed? %>
  <td class="pulse-results-random">???</td>
<% else %>
  <%# existing random_id logic %>
<% end %>
```

**b) Explanation text (lines 45-53)**: Update the vote branch to account for open vs beacon-drawn states:
- **Vote, open**: "Results are sorted first by acceptance ✅, then by preference ⭐, then by random digits 🎲 (final tiebreakers determined at close time)."
- **Vote, closed but not drawn**: Same as open text, or "Fetching verifiable randomness for tiebreakers..."
- **Beacon drawn (any type)**: Include link to verify page. For votes: "Results are sorted first by acceptance ✅, then by preference ⭐, then by verifiably random tiebreakers 🎲."

**c) "Drawing..." spinner (line 2)**: Extend to also show for votes that are closed but not drawn. For votes, this should probably be a subtler inline indicator rather than hiding the whole table — maybe a small note below the table.

### Step 6: Update verify page

**File**: `app/views/decisions/verify.html.erb`

- Change breadcrumb from `['Lottery', ...]` to `[@decision.is_lottery? ? 'Lottery' : 'Decision', ...]`
- Change heading from "Verify Lottery Results" to "Verify Results" (or conditional)
- Change "This lottery uses..." to "This decision uses..." or conditional
- Change "entry/entries" to "option/entry" based on subtype
- For votes, add a note that the beacon only affects tiebreakers, not the acceptance/preference ranking

### Step 7: Update verify controller action

**File**: `app/controllers/decisions_controller.rb` (line 519)

- Change guard from `lottery_drawn?` to `beacon_drawn?`
- Update page title from "Verify Lottery" to "Verify Results" (or conditional)

### Step 8: Update DecisionResult `get_sorting_factor`

**File**: `app/models/decision_result.rb`

- Currently checks `lottery_sort_key.present?` — this already works generically, no change needed
- The `is_sorting_factor?` calls in the results partial may need updating for the "???" state

### Step 9: Tests

Write tests for:
- Beacon fetch triggered when vote decision closes
- Results show "???" in random column for open vote decisions
- Results show beacon sort key after vote decision beacon is drawn
- Verify page accessible for vote decisions with beacon data
- Verify page redirects for vote decisions without beacon data
- LotteryDrawJob processes vote decisions
- LotteryService.draw! works for vote decisions

## Files to modify

| File | Change |
|------|--------|
| `app/models/decision.rb` | Add `beacon_drawn?`, update `api_json` |
| `app/services/lottery_service.rb` | Relax subtype guard |
| `app/jobs/lottery_draw_job.rb` | Relax subtype guard |
| `app/services/api_helper.rb` | Trigger job for votes too |
| `app/views/decisions/_results.html.erb` | "???" state, updated explanation text |
| `app/views/decisions/verify.html.erb` | Generalize lottery-specific language |
| `app/controllers/decisions_controller.rb` | `beacon_drawn?` guard on verify action |
| Tests for all of the above |

## Optional future rename

The DB columns are named `lottery_beacon_*` which is a bit awkward for vote decisions. A migration to rename them to `beacon_round` / `beacon_randomness` would be cleaner but isn't required — the existing names work fine functionally. This could be a follow-up.

## Verification

1. Create a vote decision with 3+ options that tie on acceptance/preference
2. While open, confirm "???" shows in random column and explanation mentions "determined at close time"
3. Close the decision
4. Confirm beacon is fetched (check logs or DB)
5. Confirm results show beacon sort keys and link to verify page
6. Visit verify page, confirm it works for vote decisions
7. Run existing lottery tests to confirm no regressions
8. Run new vote beacon tests
