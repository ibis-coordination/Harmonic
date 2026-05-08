# Vote Receipt Email Opt-In

## Context

The `VoteReceiptMailer` exists with complete HTML and text templates, but `send_vote_receipt_email` in `ApiHelper` is a no-op because there's no opt-in mechanism. Users should be able to check a box on the voting form to receive an email receipt when they vote.

The preference is per-user per-decision: a checkbox directly above the submit button on the voting form. The entire feature is behind a feature flag that cascades app → tenant → collective, so it can be disabled at any level.

## Implementation

### 1. Feature flag: `vote_receipt_emails`

Add to `config/feature_flags.yml`:
```yaml
vote_receipt_emails:
  name: "Vote Receipt Emails"
  description: "Allows voters to opt in to receiving email receipts when they vote"
  app_enabled: true
  default_tenant: true
  default_collective: true
  collective_level: true
```

Enabled by default at all levels. Can be disabled per-collective or per-tenant.

### 2. Migration: add `vote_receipt_email` to `decision_participants`

Add a boolean column `vote_receipt_email` (default false) to the `decision_participants` table. This stores whether the user wants email receipts for this specific decision.

### 3. Checkbox on voting form

Add a checkbox labeled "Email me a receipt" above the submit button, only shown when the feature flag is enabled.

- File: `app/views/decisions/_options_section.html.erb` (inside `.pulse-vote-submit-row`, before the submit button)
- The checkbox name: `vote_receipt_email` with value "1" / hidden field "0"
- Remembers the user's previous choice via `@participant.decision_participant&.vote_receipt_email`
- Only rendered when `FeatureFlagService.enabled?("vote_receipt_emails", collective: @current_collective)`

### 4. Pass checkbox through submit_votes

- File: `app/controllers/decisions_controller.rb` — `submit_votes` action
- Read `params[:vote_receipt_email]` and update the decision participant's preference
- Find or create the `DecisionParticipant`, then update `vote_receipt_email` before creating votes

### 5. Wire up send_vote_receipt_email

- File: `app/services/api_helper.rb` — `send_vote_receipt_email` method
- Check feature flag AND `current_decision_participant.vote_receipt_email?`
- Get the receipt hash via `DecisionAuditEntry.receipt_for_user`
- Send via `VoteReceiptMailer.receipt_email(...).deliver_later`
- One email per vote transaction (not one per option)

### 6. Update email template to link to receipt page

- File: `app/views/vote_receipt_mailer/receipt_email.html.erb`
- Update the verify link to point to `/d/:id/verify/:receipt_hash` (the receipt verification page)
- Same for `receipt_email.text.erb`

### 7. Markdown voting form

- Check `app/views/decisions/show.md.erb` for vote submission actions and add the opt-in option if applicable

## Key Files

- `config/feature_flags.yml` — new flag definition
- `db/migrate/TIMESTAMP_add_vote_receipt_email_to_decision_participants.rb` — migration
- `app/views/decisions/_options_section.html.erb` — checkbox UI
- `app/controllers/decisions_controller.rb` — submit_votes action (~line 297)
- `app/services/api_helper.rb` — send_vote_receipt_email (~line 1020), create_votes (~line 650)
- `app/mailers/vote_receipt_mailer.rb` — existing mailer
- `app/views/vote_receipt_mailer/receipt_email.html.erb` — update verify link
- `app/views/vote_receipt_mailer/receipt_email.text.erb` — update verify link
- `app/models/decision_participant.rb` — new column

## Tests

- Feature flag: checkbox hidden when flag disabled, shown when enabled
- Controller test: checkbox value is saved to decision_participant
- Controller test: email is sent when opt-in checked AND flag enabled
- Controller test: email is NOT sent when opt-in unchecked
- Controller test: email is NOT sent when flag disabled even if opt-in checked
- Mailer test: email contains receipt hash and links to receipt verification page

## Verification

- `docker compose exec web bundle exec rails test` — targeted test files
- `docker compose exec web bundle exec srb tc` — Sorbet clean
- Manual: vote with checkbox checked, verify email arrives in mailcatcher (localhost:1080)
- Manual: vote with checkbox unchecked, verify no email sent
- Manual: disable feature flag on collective, verify checkbox disappears
