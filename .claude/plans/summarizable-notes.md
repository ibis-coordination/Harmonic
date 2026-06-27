# Summaries as Notes

## Goal

Let any signed-in member create a **summary** of a Note, Decision, or Commitment. A summary is a Note with `subtype: "summary"` linked back to the summarized resource through a polymorphic `summarizable` association. This mirrors the existing Statementable pattern.

This is the data foundation. A specialized AI summarizer persona, scheduled rollups, cycle summaries, and member summaries are out of scope here — they get easier once this exists.

## Scope

In scope:
- `Summarizable` concern, included in `Note`, `Decision`, `Commitment`
- New Note `subtype: "summary"` with matching polymorphic association + validations
- `can_write_summary?(user)` permission method (any signed-in member by default)
- Create / read / update / delete a summary through the existing controller + api_helper patterns, exposed for HTML and Markdown
- Tests at every layer (red-green TDD)

Out of scope, in roughly the order they make sense to revisit:
1. Cycle summaries
2. Collective-member summaries
3. Specialized summarizer AI persona
4. Scheduled / rolled-up / hierarchical summaries

## Design

### Note model

- Add `"summary"` to `Note::SUBTYPES`
- Add `belongs_to :summarizable, polymorphic: true, optional: true` alongside the existing `commentable` and `statementable` associations
- Add `summaries_must_be_summary_subtype` validation that mirrors the statement pair:
  - if `has_summarizable?` and subtype is not `"summary"` → error
  - if subtype is `"summary"` and not `has_summarizable?` → error
- Add `has_summarizable?` helper mirroring `has_statementable?`
- Add `is_summary?` helper mirroring `is_statement?`

### Migration

```ruby
add_reference :notes, :summarizable, polymorphic: true, null: true, index: true
```

No backfill; existing notes are not summaries.

### Summarizable concern

`app/models/concerns/summarizable.rb`:

```ruby
# typed: false

module Summarizable
  extend ActiveSupport::Concern

  included do
    has_many :summaries, -> { where(subtype: "summary") },
             class_name: "Note",
             as: :summarizable,
             dependent: :destroy
  end

  def can_write_summary?(user)
    user.present? && !user.anonymous?
  end
end
```

Differences from `Statementable` worth flagging:
- `has_many`, not `has_one` — a resource can accumulate many summaries over time, from different summarizers and different time ranges
- Default permission is permissive (any signed-in user), not creator-only — the user wants summaries to be a contribution anyone can make
- Override `can_write_summary?` in including models if a model needs stricter rules later

### Including models

`include Summarizable` in:
- `app/models/note.rb`
- `app/models/decision.rb`
- `app/models/commitment.rb`

Confirm the default `can_write_summary?` is right for each. If any needs a stricter rule (e.g. commitment summaries restricted to participants), override there. Default assumption: no overrides needed in v1.

### Permission rule

`user.present? && !user.anonymous?` — any signed-in member of the tenant. Anonymous read-mode users (per the anonymous-read-access feature) cannot create summaries. Edits/deletes follow normal Note rules (creator + collective member edit access).

### Controller / API surface

Mirror `decisions_controller#add_statement_action` and `api_helper#add_statement`, but on each summarizable resource. The minimal addition per controller:

- `GET /actions/add_summary` → `describe_add_summary`
- `POST /actions/add_summary` → `add_summary_action` → `api_helper.add_summary`

`api_helper#add_summary` creates a `Note` with `subtype: "summary"`, polymorphic `summarizable:`, `created_by: current_user`, standard tenant/collective. No upsert — every call creates a new summary (unlike statements, which are has_one).

Action descriptions (markdown surface) follow the existing `ActionsHelper.action_description` pattern.

### Display

Summaries render in the parent resource view alongside (but distinct from) comments. Exact placement / styling is a small UI decision to make when wiring up the view — propose: a `Summaries` section above the comments thread, each summary attributed to its `created_by` with `created_at`. Markdown surface: include summaries in the resource's markdown rendering.

## Implementation steps

Strict red-green TDD: each step writes failing tests first, runs them red, then implements.

1. **Note subtype + polymorphic association.** Migration, `SUBTYPES` update, `belongs_to :summarizable`, validation pair, `has_summarizable?`, `is_summary?`. Tests in `test/models/note_test.rb`.
2. **Summarizable concern.** New file + concern test. Include in Note, Decision, Commitment. Tests cover `has_many :summaries`, `can_write_summary?`, dependent destroy. Tests in `test/models/concerns/summarizable_test.rb` and additions to each including model's test file.
3. **api_helper add_summary.** Test + implementation. Permission check via `can_write_summary?`.
4. **Controllers.** `add_summary` describe + action on `notes_controller`, `decisions_controller`, `commitments_controller`. Route entries. Controller tests for HTML + Markdown formats.
5. **Display.** Render summaries in the HTML and Markdown views of Note, Decision, Commitment. View / system tests for visibility and attribution.
6. **Static analysis.** Sorbet typed: true on the concern (regenerate RBIs via tapioca), RuboCop clean, all checked scripts pass.

## Open questions

1. **UI placement** — summaries-above-comments is the proposed default; confirm or redirect when we get to step 5.
2. **Edit / delete rules** — assume creator-only for now via normal Note semantics; flag if you want a different rule (e.g. collective admins can curate).
3. **Anonymous viewers** — they can read summaries (summaries are just Notes on already-readable resources) but cannot create. Confirm this matches intent.
