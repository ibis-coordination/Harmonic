# Executive Decision — Option Selection Refactor

## Context

Currently, executive decisions have no structured way for the decision maker to indicate which options they selected. The decision maker can only write a final statement in prose. This refactor adds option selection as a structured input that uses the existing vote system under the hood, but with different UI and terminology.

The key insight: an executive decision is mechanically a vote with one voter (the decision maker). But the UI and language need to reflect the different semantics.

**Depends on:** [Executive Decision](content-subtypes-decision-executive.md)

## Design

### Terminology
- "Select" instead of "Vote"
- "Selected" instead of "Accepted"
- "Submit Selection" instead of "Submit Vote"
- No "preference" concept — just selected or not selected

### Mechanics
- Uses the existing Vote model under the hood
- Checkbox checked = `accepted: 1, preferred: 0`
- Checkbox unchecked = no vote record (or `accepted: 0`)
- Stars are never used — `preferred` is always `0`

### Single Action: Submit Selection + Final Statement
When the decision maker submits, they provide both their option selections and a final statement in one action. This closes the decision. The flow is:
1. Decision maker checks options they want to select
2. Writes final statement text
3. Clicks "Submit" — this creates the votes, creates the statement note, and closes the decision in one transaction

### Display After Closing
- Selected options shown with checkmarks, unselected without
- No ranked results table (no acceptance/preference counts)
- Final statement displayed via StatementEmbedComponent

## Model Changes

None — uses existing Vote model. The `create_votes` check for executive decisions needs to be relaxed to allow the decision maker to "vote."

### ApiHelper changes
- Remove the blanket rejection of votes on executive decisions
- Instead: only the decision maker can submit votes on executive decisions
- New method or update to `close_decision`: accept both `selections` (option titles) and `final_statement`, create votes + statement + close in one transaction

## Controller Changes

### DecisionsController
- `submit_votes`: still rejected for executive (HTML form not used)
- New action or update `close_decision_action`: for executive decisions, accept `selections[]` param alongside `final_statement`
- `show`: for executive decisions, decision maker sees checkboxes (no stars); others see read-only list

## View Changes

### Show page — Decision maker view (open executive decision)
- Options with checkboxes only (no star/preference inputs)
- Below options: final statement textarea
- Single "Submit" button that sends selections + statement together
- Replaces the separate "Submit Final Statement" and "Close Decision" flows

### Show page — Other members view (open executive decision)
- Options as read-only list (no checkboxes)
- Placeholder: "[Decision maker]'s selection and final statement will appear here when the decision is made."

### Show page — Everyone (closed executive decision)
- Options list with checkmarks on selected options
- Final statement via StatementEmbedComponent

### Close dialog
- For executive decisions: remove the close dialog since submission is inline
- The "Close Decision" header button is replaced by the inline submit form

### Markdown view
- Decision maker can use `close_decision` action with `selections` and `final_statement` params
- Others see options as plain list

## Actions Index
- `vote` action remains excluded for executive decisions
- `close_decision` action for executive: updated to accept `selections` and `final_statement`

## Testing

- Model: decision maker can create votes on executive decision, non-decision-maker cannot
- Controller: submit selection + statement closes decision, creates votes and statement
- Controller: non-decision-maker cannot submit selection
- View: decision maker sees checkboxes, others see read-only list
- View: closed executive shows selected options with checkmarks

## Verification

```bash
docker compose exec web bundle exec rails test test/models/decision_test.rb test/controllers/decisions_controller_test.rb
docker compose exec web bundle exec rubocop && docker compose exec web bundle exec srb tc
docker compose exec js npm test
```
