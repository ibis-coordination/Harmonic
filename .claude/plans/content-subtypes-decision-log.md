# Content Subtypes — Decision Log

## Context

A "log" decision is a record of a decision that has already been made — no voting, no options to add, no deadline. The simplest subtype to implement because it *removes* UI rather than adding features. Good first test of the subtype UI pattern.

**Depends on:** [Foundation](content-subtypes-foundation.md)

## Database Migration

None — no extra columns needed. Uses existing Decision schema.

## Model Changes (`app/models/decision.rb`)

- Skip `deadline` validation for log subtype: `validates :deadline, presence: true, unless: -> { log? }`
- Skip `options_open` logic — log decisions don't have options
- Override `metric_name` to return something like "recorded" instead of "voters"

## Controller Changes

### DecisionsController (`app/controllers/decisions_controller.rb`)
- `new`: accept `?subtype=log` to pre-select
- `create`: pass `subtype` through
- `show`: skip voting-related setup for log decisions

## View Changes

### Creation form (`app/views/decisions/new.html.erb`)
- Add subtype selector (radio buttons): Vote | Lottery | Log
- When "Log" selected: hide deadline field, hide options section
- Show a "Decision summary" or "Outcome" field instead

### Show page (`app/views/decisions/show.html.erb`)
- Hide voting UI (options list, vote button, results)
- Show the decision description as the recorded outcome
- Keep comments, pinning, linking, attachments

### Feed (`app/components/feed_item_component.rb` + template)
- Type label: "Decision Log" instead of "Decision"
- No vote button or voter count
- Show description/outcome inline

### ResourceHeaderComponent
- Type label: "Decision Log"

## Testing

- Model: log decision valid without deadline, log? predicate
- Controller: create log decision, show page renders without voting UI
- Feed: log decision renders correctly in feed

## Help Documentation

After actions and interfaces are implemented:
- Add help content explaining decision logs (what they are, when to use them vs votes)
- Update any existing help pages that reference decisions

## Verification

```bash
docker compose exec web bundle exec rails test test/models/decision_test.rb test/controllers/decisions_controller_test.rb
docker compose exec web bundle exec rubocop
```
Manual: create a log decision via UI, verify no voting UI on show page, verify feed rendering.
