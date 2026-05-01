# Statementable Concern

## Context

A **statement** is a note of subtype `statement` that belongs to a `statementable` resource, similar to how a comment belongs to a `commentable`. The key difference: a statementable can only have **one** statement, whereas a commentable can have many comments.

Statements serve as authoritative declarations attached to resources — the final word on a decision, the outcome of a commitment, the summary of a representation session. Because they are notes, they get full note capabilities: history events, activity feed presence, read confirmations, markdown content, attachments.

### Statementable models
- **Decision** — the decision maker's final statement explaining the outcome
- **Commitment** — the outcome or resolution statement
- **RepresentationSession** — the session summary

### Not statementable
- **Note** — notes don't need statements (a note already is content)

## Note Subtype

Add `statement` to the Note `SUBTYPES` constant: `%w[text reminder table statement]`

A statement note:
- Has `is_statement?` predicate
- Belongs to a statementable via polymorphic association
- Cannot exist without a statementable parent
- Is always created by a specific user (the statement author)
- Is not directly creatable via the new note form — only created through the statementable's interface

## Database Migration

```ruby
# Add statement subtype support to notes
# The statementable association uses existing polymorphic pattern
add_column :notes, :statementable_type, :string, null: true
add_column :notes, :statementable_id, :uuid, null: true
add_index :notes, [:statementable_type, :statementable_id], unique: true
```

The unique index enforces the one-statement-per-resource constraint at the database level.

## Concern: `Statementable` (`app/models/concerns/statementable.rb`)

```ruby
module Statementable
  extend ActiveSupport::Concern

  included do
    has_one :statement, -> { where(subtype: 'statement') },
            class_name: 'Note',
            as: :statementable,
            dependent: :destroy
  end

  def can_write_statement?(user)
    # Default: creator can write the statement.
    # Override in including models for different permission logic
    # (e.g., executive decisions allow the designated decision maker).
    user.id == created_by_id
  end
end
```

## Model Changes

### Note (`app/models/note.rb`)
- Add `statement` to `SUBTYPES`
- Add `is_statement?` predicate
- Add `belongs_to :statementable, polymorphic: true, optional: true`
- Validate: statement subtype requires statementable
- Validate: non-statement subtypes must not have statementable

### Decision (`app/models/decision.rb`)
- `include Statementable`
- Remove `final_statement` text column (replaced by statement note)
- Override `can_write_statement?` for executive subtype to allow the effective decision maker

### Commitment (`app/models/commitment.rb`)
- `include Statementable`

### RepresentationSession
- `include Statementable`

## Migration: Remove `final_statement` column

Since the decision improvements added `final_statement` as a text column, we need to migrate any existing data to statement notes before dropping the column.

```ruby
# Data migration: convert final_statement text to statement notes
Decision.where.not(final_statement: [nil, '']).find_each do |decision|
  Note.create!(
    subtype: 'statement',
    body: decision.final_statement,
    statementable: decision,
    created_by: decision.created_by,
    tenant: decision.tenant,
    collective: decision.collective,
  )
end

remove_column :decisions, :final_statement
```

## Controller / View Integration

Each statementable's controller and views need:
- Display the statement when present (rendered as a note with full markdown)
- Show "Add Statement" or edit UI to the statement author
- Create/update the statement note via the statementable's actions

Specific integration is handled in each feature's plan (executive decision, commitment subtypes, etc.).

## Actions

- `add_statement(text)` — creates or updates the statement note for the resource
- Available in both HTML and markdown/API interfaces
- Authorization: `can_write_statement?(current_user)`

## Feed Integration

Statement notes appear in the activity feed like other notes, with context linking back to the parent resource (e.g., "Dan issued a statement on Decision: What should we do next?").

## Testing

- Model: statement subtype validation, statementable association, uniqueness constraint
- Concern: `can_write_statement?`, `statement_author`, one-statement-per-resource enforcement
- Controller: create statement, update statement, prevent duplicate statements
- Feed: statement appears in feed with parent context

## Verification

```bash
docker compose exec web bundle exec rails test
docker compose exec web bundle exec rubocop
docker compose exec web bundle exec srb tc
```
