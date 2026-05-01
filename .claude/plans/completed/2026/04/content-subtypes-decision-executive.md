# Content Subtypes — Executive Decision

## Context

An "executive" decision uses the same collaborative option-gathering as a vote, but resolves differently: instead of voting, a designated **decision maker** reviews the options and makes the call by issuing a statement. All other mechanics are the same — deadlines, option adding, closing, comments, attachments, linking, pinning.

The decision maker may or may not be the creator. A common pattern: an AI agent creates the decision with a list of options and designates a human principal as the decision maker. The human reviews the options and issues a statement, and the agent proceeds accordingly. This also works for approval workflows — someone who lacks authority creates the decision and assigns it to someone who has authority.

The only functional differences from a vote decision:
1. **No voting UI** — no checkboxes, no submit vote button, no results table
2. **Designated decision maker** — a specific user who can close the decision and issue the statement (defaults to creator if not set)

**Depends on:**
- [Foundation](content-subtypes-foundation.md)
- [Decision Improvements](decision-improvements.md) (close action, voters page, batch voting)
- [Statementable](statementable.md) (statement as a note, replaces final_statement column)

## Database Migration

```ruby
add_column :decisions, :decision_maker_id, :uuid, null: true
add_foreign_key :decisions, :users, column: :decision_maker_id
```

## Model Changes (`app/models/decision.rb`)

- Rename `log` to `executive` in `SUBTYPES`: `%w[vote lottery executive]`
- Rename `is_log?` to `is_executive?`
- Add `belongs_to :decision_maker, class_name: 'User', optional: true`
- Add `effective_decision_maker` method: returns `decision_maker || created_by`
- Override `can_close?`: for executive decisions, allow the effective decision maker
- Override `can_write_statement?`: for executive decisions, allow the effective decision maker
- Creator retains `can_edit_settings?` — decision maker can only close and write the statement

## Controller Changes

### DecisionsController
- `new`/`create`: accept `subtype` and `decision_maker_id` params
- `show`: skip voting-related setup for executive decisions
- `submit_votes`/`vote`: reject for executive decisions
- `close_decision_action`: already uses `can_close?` — model update handles permissions
- `settings`/`update_settings`: accept `decision_maker_id` param (creator can change the decision maker)

### ApiHelper
- `create_decision`: accept `decision_maker_id` param
- `create_votes`: reject if decision is executive subtype
- `update_decision_settings`: accept `decision_maker_id`

## View Changes

### Creation form (`new.html.erb` + `new.md.erb`)
- Add subtype selector: Vote | Executive
- When "Executive" selected: show decision maker field (member selector)

### Show page (`show.html.erb` + `show.md.erb`)
- For executive decisions:
  - Show "Decision maker: @handle" in metadata
  - Hide voting UI (checkboxes, submit vote button)
  - Hide results table
  - Show options as a readable list (not a voting form)
  - Show close button to the effective decision maker
- Keep: add options section, deadline, comments, backlinks, attachments
- Statement display/edit handled by Statementable concern views

### Settings page
- For executive decisions: show decision maker selector (only creator can change)

### Feed
- Type label: "Executive Decision"
- Show option count instead of voter count
- Show decision maker name

### ResourceHeaderComponent
- Type label: "Executive Decision"

### Actions index
- `vote` action excluded for executive decisions
- `close_decision`: authorized for effective decision maker
- `add_statement`: authorized for effective decision maker

## Testing

- Model: `is_executive?` predicate, `effective_decision_maker`, `can_close?` for decision maker vs creator vs other user, `can_write_statement?` for decision maker
- Controller: create executive with decision maker, show page renders without voting UI, decision maker can close, voting is rejected
- Settings: creator can change decision maker, decision maker cannot change settings

## Help Documentation

- Add section explaining executive decisions
- Explain the decision maker role and how it differs from creator
- Describe the agent-principal use case

## Verification

```bash
docker compose exec web bundle exec rails test test/models/decision_test.rb test/controllers/decisions_controller_test.rb
docker compose exec web bundle exec rubocop && docker compose exec web bundle exec srb tc
docker compose exec js npm test
```
