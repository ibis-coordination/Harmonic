# Audit Chain Receipts

Follow-up work for vote receipt features on the audit chain.

## Items

### 1. Receipt hashes on voters page
Show each voter's receipt hash next to their name on the voters page. The hash should link to the per-user verification page (item 2).

### 2. Receipt verification route
New page at `/d/:decision_id/verify/:receipt_hash` that shows all audit entries for the user associated with that receipt hash. Enables anyone to verify anyone else's votes — full transparency.

Together with item 1, this replaces the originally-deferred "receipt lookup UX" (paste hash to search). The voters page links directly to per-user verification via a dedicated route.

### 3. Email receipt opt-in toggle
`VoteReceiptMailer` exists and works, but `send_vote_receipt_email` in `ApiHelper` is currently a no-op. Needs:
- A user preference / notification setting for opting in to vote receipt emails
- UI for toggling the preference
- Wire up `send_vote_receipt_email` to check the preference and send when enabled

### 4. Vote history visibility on verify page
Open design question: should the verify page (and the per-user receipt page) show the full vote change history (every `vote_cast` + `vote_updated` entry) or just the final state?

This affects what users and verifiers can learn from the audit log. Full history gives maximum transparency but may be noisy. Final state is cleaner but hides intermediate changes.

## Dependencies
- Item 2 depends on item 1 conceptually (the voters page is the primary entry point to per-user verification)
- Item 3 is independent
- Item 4 is a design decision that affects items 2 and 3 (what's shown on the receipt page and in the email)
