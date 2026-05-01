# Content Subtypes — Foundation

## Context

Infrastructure for all subtypes. Add `subtype` column to each table, model validations, predicate methods, and wire through ApiHelper/API. No UI changes — just the plumbing that all subsequent subtype plans build on.

## Database Migration

```ruby
add_column :notes, :subtype, :string, null: false, default: "text"
add_column :decisions, :subtype, :string, null: false, default: "vote"
add_column :commitments, :subtype, :string, null: false, default: "action"
```

All existing records get the default automatically. No data migration needed.

## Model Changes

Each model (`app/models/note.rb`, `app/models/decision.rb`, `app/models/commitment.rb`) gets:

- `SUBTYPES` constant: `%w[text reminder table]` / `%w[vote lottery log]` / `%w[action calendar_event policy]`
- `validates :subtype, inclusion: { in: SUBTYPES }`
- Predicate methods use `is_` prefix to avoid collisions with Rails attribute presence checks: `is_text?`, `is_reminder?`, `is_table?` / `is_vote?`, `is_lottery?`, `is_log?` / `is_action?`, `is_calendar_event?`, `is_policy?`
- `api_json` includes `subtype` in response hash

## Service Changes

### ApiHelper (`app/services/api_helper.rb`)
- `create_note`: accept `subtype` param, default `"text"`
- `create_decision`: accept `subtype` param, default `"vote"`
- `create_commitment`: accept `subtype` param, default `"action"`

### API v1 Controllers
- Add `subtype` to permitted params for create/update
- Return `subtype` in JSON responses (via `api_json`)

## Testing

- Model tests: subtype validation, predicate methods, default values
- ApiHelper tests: create with explicit subtype, create with default
- API controller tests: subtype in request/response

## Verification

```bash
docker compose exec web bundle exec rails test test/models/note_test.rb test/models/decision_test.rb test/models/commitment_test.rb
docker compose exec web bundle exec rubocop
docker compose exec web bundle exec srb tc
```
