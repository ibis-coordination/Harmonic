# Content Subtypes — Lottery Decision

## Context

A "lottery" decision selects randomly from options instead of voting. The existing results view already sorts tied options by random ID, so a decision with zero votes is already a random ordering. The only work is to disable voting and present the results as a lottery.

**Depends on:** [Foundation](content-subtypes-foundation.md)

## Database Migration

None — no extra columns needed.

## Model Changes (`app/models/decision.rb`)

- `can_vote?` should return false for lottery decisions (voting disabled)
- Override `metric_name` to "options" or "entries" instead of "voters"

## Controller Changes

### DecisionsController (`app/controllers/decisions_controller.rb`)
- `new`: accept `?subtype=lottery`
- `show`: skip voting UI setup for lottery decisions

## View Changes

### Creation form (`app/views/decisions/new.html.erb`)
- When "Lottery" selected: keep options section, label options as "entries"

### Show page (`app/views/decisions/show.html.erb`)
- Hide vote buttons — no voting allowed
- Show results in the existing random order (already sorted by random ID for ties)
- When closed: present the top result as the "winner"

### Feed (`app/components/feed_item_component.rb` + template)
- Type label: "Lottery"
- No vote button
- Show option count

### ResourceHeaderComponent
- Type label: "Lottery"

## Testing

- Model: lottery? predicate, can_vote? returns false for lottery
- Controller: create lottery, show page has no vote UI, results show random order
- Feed: lottery renders without vote button

## Verification

```bash
docker compose exec web bundle exec rails test test/models/decision_test.rb test/controllers/decisions_controller_test.rb
docker compose exec web bundle exec rubocop
```
Manual: create a lottery, add options, close it, verify top result shown as winner, no vote buttons anywhere.
