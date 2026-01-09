# Rename Approvals to Votes

Rename the `Approval` model to `Vote` and update attribute names to align with acceptance voting terminology.

## Naming Changes

| Current | New |
|---------|-----|
| `Approval` (model/table) | `Vote` |
| `approval.value` | `vote.accepted` |
| `approval.stars` | `vote.preferred` |
| `approved_yes` (in results view) | `accepted_yes` |
| `approved_no` (in results view) | `accepted_no` |
| `approval_count` (in results view) | `vote_count` |

## Files to Change

### Database Migration

Create migration to:
1. Rename table `approvals` → `votes`
2. Rename column `value` → `accepted`
3. Rename column `stars` → `preferred`
4. Recreate `decision_results` view with new column names

### Models

- `app/models/approval.rb` → `app/models/vote.rb`
  - Rename class `Approval` → `Vote`
  - Update `api_json` to return `accepted` and `preferred` instead of `value` and `stars`

- `app/models/decision.rb`
  - `has_many :approvals` → `has_many :votes`
  - Update `voter_count` method
  - Update `voters` method

- `app/models/decision_result.rb`
  - Update `api_json`: `approved_yes` → `accepted_yes`, etc.
  - Update `get_sorting_factor` method

- `app/models/option.rb`
  - Update any `has_many :approvals` association

- `app/models/decision_participant.rb`
  - Update any approval association

### Controllers

- `app/controllers/api/v1/approvals_controller.rb` → `app/controllers/api/v1/votes_controller.rb`
  - Rename class
  - Update param references: `params[:value]` → `params[:accepted]`, `params[:stars]` → `params[:preferred]`

### Routes

- `config/routes.rb`
  - `resources :approvals` → `resources :votes`

### Services

- `app/services/api_helper.rb`
  - Update `vote` method references
  - Update param handling

- `app/services/data_deletion_manager.rb`
  - Update any approval references

### Views

- `app/views/decisions/show.md.erb`
- `app/views/decisions/_options_list_items.html.erb`
- `app/views/decisions/_results.html.erb`

### Frontend

- `app/javascript/controllers/decision_controller.ts`
  - Update any approval references

### Tests

- `test/test_helper.rb`
- `test/models/decision_test.rb`
- `test/integration/api_decisions_test.rb`
- `test/services/api_helper_test.rb`

### Sorbet RBI Files

- `sorbet/rbi/dsl/approval.rbi` - will be regenerated
- Other RBI files referencing Approval

### Documentation

- `docs/ARCHITECTURE.md`
- `docs/API.md`

## Migration Strategy

Since there are no external clients, we can do a straightforward rename:

1. Create migration that renames table and columns
2. Rename model file and update class
3. Update all references across codebase
4. Regenerate Sorbet RBI files
5. Run tests

## Progress

- [x] Create database migration
- [x] Rename model file and update class
- [x] Update Decision model associations and methods
- [x] Update DecisionResult model
- [x] Update Option model
- [x] Update DecisionParticipant model
- [x] Rename and update controller
- [x] Update routes
- [x] Update ApiHelper
- [x] Update views
- [x] Update frontend TypeScript
- [x] Update tests
- [x] Regenerate Sorbet RBI files (`bundle exec tapioca dsl`)
- [x] Update documentation
- [x] Run full test suite

## Completed

All tasks completed on 2026-01-09. All 501 backend tests and 17 frontend tests pass.
