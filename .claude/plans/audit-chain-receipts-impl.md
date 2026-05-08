# Audit Chain Receipts Implementation

## Context

After voting, users receive a receipt hash (the `entry_hash` of their last audit entry). Currently this only appears as a flash notice that disappears after one page load. We need to make receipts persistent and visible so that:
- Anyone can see each voter's receipt on the voters page
- Anyone can click a receipt to see that voter's full audit trail
- This creates full transparency — anyone can verify anyone else's votes

## Items

### 1. Receipt hashes on voters page

Add each voter's receipt hash next to their name on the voters page. Show the first 8 characters as a `<code>` element, linking to the receipt verification page.

**Files:**
- `app/controllers/decisions_controller.rb` — `voters_page` action: load receipts for all voters in a single query
- `app/views/decisions/voters_page.html.erb` — show truncated receipt hash next to each voter name, linked to receipt route
- `app/views/decisions/voters_page.md.erb` — same for markdown

**Data loading (controller):**
Query all receipts in one batch to avoid N+1:
```ruby
receipt_entries = DecisionAuditEntry
  .where(decision_id: @decision.id, action: ["vote_cast", "vote_updated"])
  .order(:sequence_number)
# Group by actor_id, keeping the last entry per actor (the receipt)
@receipts_by_voter = receipt_entries.group_by(&:actor_id).transform_values(&:last)
```

**Display (template):**
Next to each voter name in the "By voter" tab, show:
```
<a href="/d/:decision_id/verify/:receipt_hash"><code>a1b2c3d4...</code></a>
```

### 2. Receipt verification route and page

New route: `GET /d/:decision_id/verify/:receipt_hash`

Shows all audit entries for the user associated with the given receipt hash. Supports HTML, markdown, and JSON formats.

**Files:**
- `config/routes.rb` — add route `get '/verify/:receipt_hash' => 'decisions#verify_receipt'`
- `app/controllers/decisions_controller.rb` — new `verify_receipt` action
- `app/views/decisions/verify_receipt.html.erb` — new template
- `app/views/decisions/verify_receipt.md.erb` — new markdown template

**Controller logic (`verify_receipt`):**
1. Find the audit entry matching the receipt hash: `DecisionAuditEntry.find_by(decision_id: @decision.id, entry_hash: params[:receipt_hash])`
2. If not found, render 404
3. Get the actor_id from that entry
4. Load ALL audit entries for that actor on this decision: `DecisionAuditEntry.where(decision_id: @decision.id, actor_id: actor_id).order(:sequence_number)`
5. Render the full vote history

**Page content:**
- Breadcrumb: Collective → Decision → Verify → Receipt
- Header: "Vote receipt for @handle"
- Full timeline of entries (each showing: sequence #, action, option title, accepted/preferred, timestamp, entry hash)
- Link back to the main verify page
- JSON format returns the entries array for programmatic verification

### 3. Update `receipt_for_user` to work with the new flow

The existing `DecisionAuditEntry.receipt_for_user(decision, user)` returns the last entry for a user. This is still useful — the voters page uses it to get the receipt hash. But the receipt page needs to find a user by receipt hash, which is a different lookup path.

**New class method on `DecisionAuditEntry`:**
```ruby
def self.find_by_receipt(decision, receipt_hash)
  find_by(decision_id: decision.id, entry_hash: receipt_hash)
end
```

### 4. Tests

**Controller tests** (`test/controllers/decisions_controller_test.rb`):
- Voters page shows receipt hashes next to voter names
- Voters page receipt hashes link to receipt verification route
- Receipt verification page renders for valid receipt hash
- Receipt verification page shows full vote history for the voter
- Receipt verification page returns 404 for invalid hash
- Receipt verification page works for markdown format
- Receipt verification JSON returns entries array

**Model tests** (`test/models/decision_audit_entry_test.rb`):
- `find_by_receipt` returns the correct entry
- `find_by_receipt` returns nil for unknown hash

## Key Files

- `app/controllers/decisions_controller.rb` — voters_page action (~line 352), new verify_receipt action
- `app/views/decisions/voters_page.html.erb` — add receipt hashes
- `app/views/decisions/voters_page.md.erb` — add receipt hashes (markdown)
- `app/views/decisions/verify_receipt.html.erb` — new page
- `app/views/decisions/verify_receipt.md.erb` — new page (markdown)
- `config/routes.rb` — new route (~line 516)
- `app/models/decision_audit_entry.rb` — new `find_by_receipt` method
- `test/controllers/decisions_controller_test.rb` — new tests

## Verification

- `docker compose exec web bundle exec rails test test/controllers/decisions_controller_test.rb` — all tests pass
- `docker compose exec web bundle exec rails test test/models/decision_audit_entry_test.rb` — model tests pass
- `docker compose exec web bundle exec srb tc` — Sorbet clean
- Manual: vote on a decision, check voters page shows receipt hash, click it, see full vote history
- Manual: verify markdown format with `curl -H "Accept: text/markdown"`
