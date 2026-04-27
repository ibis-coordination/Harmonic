# Content Subtypes — Commitment Policy

## Context

A "policy" commitment represents an ongoing rule or agreement — no deadline, no critical mass threshold. Members "sign" to indicate endorsement. Like decision log, this is simple because it removes features (deadline, critical mass) rather than adding new ones.

**Depends on:** [Foundation](content-subtypes-foundation.md)

## Database Migration

None — no extra columns needed. Uses existing Commitment schema.

## Model Changes (`app/models/commitment.rb`)

- Skip `deadline` validation: `validates :deadline, presence: true, unless: -> { policy? }`
- Skip `critical_mass` validation/logic for policy subtype
- Override `metric_name` to "signatories" instead of "participants"
- `closed?` should return false for policies (they're always open)

## Controller Changes

### CommitmentsController (`app/controllers/commitments_controller.rb`)
- `new`: accept `?subtype=policy` to pre-select
- `create`: pass `subtype` through
- `show`: skip deadline/critical-mass display for policy

## View Changes

### Creation form (`app/views/commitments/new.html.erb`)
- Add subtype selector: Action | Calendar Event | Policy
- When "Policy" selected: hide deadline field, hide critical mass field, hide limit field

### Show page (`app/views/commitments/show.html.erb`)
- Hide deadline display
- Hide progress bar (no critical mass target)
- Show participant list as "Signatories"
- "Sign" button instead of "Join"

### Feed (`app/components/feed_item_component.rb` + template)
- Type label: "Policy"
- "Sign" button instead of "Join"
- Show signatory count instead of progress bar

### ResourceHeaderComponent
- Type label: "Policy"

## Testing

- Model: policy valid without deadline, policy? predicate, closed? returns false
- Controller: create policy, show page renders without deadline/progress
- Feed: policy renders correctly

## Verification

```bash
docker compose exec web bundle exec rails test test/models/commitment_test.rb test/controllers/commitments_controller_test.rb
docker compose exec web bundle exec rubocop
```
Manual: create a policy via UI, verify no deadline/progress on show page, sign it, verify feed rendering.
