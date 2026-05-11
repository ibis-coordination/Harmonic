# Plan: Generalize Decision Maker to Decision Moderator

## Context

Currently, only executive decisions have a `decision_maker` — a user (potentially different from the creator) who can close the decision, select options, and write a final statement. For votes and lotteries, these powers are hardcoded to the creator.

We want to generalize this into a **moderator** concept that works across all subtypes:
- **Executive**: moderator = decision maker (can select options, close, write final statement)
- **Vote/Lottery**: moderator = person who can edit settings, close the decision, and write a final statement

The moderator defaults to the creator but can be reassigned. The creator is immutable but retains the power to reassign the moderator (including back to themselves).

## Design Decisions

1. **Power separation**: Only the moderator can perform moderation actions (close, edit settings, write statement, manage options). The creator's unique retained power is the ability to reassign the moderator.
2. **Moderator manages options too**: The moderator can add/edit/delete options regardless of `options_open`.
3. **Context-sensitive labels**: Executive shows "Decision Maker", vote/lottery shows "Moderator".
4. **Reassignment via Settings page**: The creator always has access to the settings page for moderator reassignment, even though only the moderator can change other settings.
5. **Basic audit log**: Record moderator changes with who/when/from/to.

## Steps

### 1. Migration: rename `decision_maker_id` → `moderator_id`

Create a migration to rename the column. Drop and re-add the foreign key.

- New file: `db/migrate/XXXXXX_rename_decision_maker_to_moderator.rb`

### 2. Audit: use existing `Event` model

No new table needed. The existing `Event` model ([app/models/event.rb](app/models/event.rb)) already has polymorphic `subject`, `actor`, `event_type`, and `jsonb :metadata`. Record moderator changes as:

```ruby
Event.create!(
  tenant: decision.tenant,
  collective: decision.collective,
  event_type: "decision.moderator_changed",
  actor: current_user,
  subject: decision,
  metadata: { from_moderator_id: old_id, to_moderator_id: new_id }
)
```

A dedicated `DecisionHistoryEvent` table could be introduced later if we want comprehensive decision lifecycle tracking, but that's a separate effort.

### 3. Model changes

**File: [app/models/decision.rb](app/models/decision.rb)**

- Rename `belongs_to :decision_maker` → `belongs_to :moderator` (optional, class: User)
- Rename `effective_decision_maker` → `effective_moderator` (returns `moderator || created_by`)
- Update `can_edit_settings?` — returns true if user is `effective_moderator` OR `created_by` (creator retains settings access for reassignment)
- Update `can_close?` — all subtypes check `effective_moderator` (remove executive-only branch)
- Update `can_write_statement?` — all subtypes check `effective_moderator` (remove executive-only branch)
- Update `can_add_options?` / `can_update_options?` / `can_delete_options?` — also allow `effective_moderator`
- Update `api_json` — rename `decision_maker_id` key to `moderator_id`
- Add `can_reassign_moderator?(user)` — returns true if user is `created_by`

### 4. Controller changes

**File: [app/controllers/decisions_controller.rb](app/controllers/decisions_controller.rb)**

- Accept `moderator_id` param in creation and settings update
- Update strong params: `decision_maker_id` → `moderator_id`
- Settings update: gate moderator reassignment behind `can_reassign_moderator?`, record an `Event` (`decision.moderator_changed`)
- Settings page access: allow both moderator and creator (already handled by updated `can_edit_settings?`)
- Settings page rendering: show moderator selector only if `can_reassign_moderator?`, show other fields only if moderator

### 5. API helper changes

**File: [app/services/api_helper.rb](app/services/api_helper.rb)**

- Create: accept `moderator` / `moderator_id` params (keep `decision_maker` / `decision_maker_id` as aliases for backward compat)
- Update: same param renaming, record `Event` (`decision.moderator_changed`) on moderator change
- Close: `effective_decision_maker` → `effective_moderator`

### 6. View changes

#### New decision form: [app/views/decisions/new.html.erb](app/views/decisions/new.html.erb)
- Show the moderator selector for **all subtypes** (remove `display: none` conditional)
- Use context-sensitive label: "Decision Maker" for executive, "Moderator" for vote/lottery
- Hidden input name: `decision[moderator_id]`

#### Stimulus controller: [app/javascript/controllers/decision_subtype_controller.ts](app/javascript/controllers/decision_subtype_controller.ts)
- Remove the show/hide logic for the moderator section (always visible)
- Add logic to update the label text when switching subtypes ("Decision Maker" vs "Moderator")
- Rename target from `decisionMakerSection` to `moderatorSection`

#### Show page (HTML): [app/views/decisions/show.html.erb](app/views/decisions/show.html.erb)
- Lines 91-95: Show moderator info for all subtypes when moderator differs from creator
- Use context-sensitive label
- Settings gear (line 55): already uses `can_edit_settings?` — will now show for both moderator and creator

#### Show page (Markdown): [app/views/decisions/show.md.erb](app/views/decisions/show.md.erb)
- Lines 13-15: Show moderator for all subtypes, not just executive
- Use context-sensitive label

#### Options section: [app/views/decisions/_options_section.html.erb](app/views/decisions/_options_section.html.erb)
- No structural changes needed — already uses `can_close?` and `can_add_options?`

#### Settings page: [app/views/decisions/settings.html.erb](app/views/decisions/settings.html.erb)
- Add moderator selector (member-select widget) — only visible to creator (`can_reassign_moderator?`)
- Gate other settings fields behind moderator check (question, description, options_open, deadline)
- If user is creator but not moderator, they see only the moderator reassignment field
- If user is moderator (and creator), they see everything

### 7. Help page updates

**File: [app/views/help/executive_decisions.md.erb](app/views/help/executive_decisions.md.erb)**
- Update `decision_maker` references to `moderator` in API docs
- Note backward compatibility of `decision_maker_id` param

Consider adding a general "Decision Moderator" help topic explaining the concept across subtypes.

### 8. Test updates

**File: [test/models/decision_test.rb](test/models/decision_test.rb)**
- Rename `decision_maker` → `moderator` in existing tests
- Add tests:
  - Vote: moderator (non-creator) can close, edit settings, write statement, manage options
  - Vote: creator (non-moderator) can access settings but cannot close/write statement
  - Vote: creator can reassign moderator
  - Lottery: same as vote tests
  - Executive: existing behavior preserved with renamed field
  - `effective_moderator` fallback to creator when nil

**File: [test/controllers/decisions_controller_test.rb](test/controllers/decisions_controller_test.rb)**
- Update existing executive tests to use `moderator`
- Add controller tests for moderator on vote/lottery
- Add tests for moderator reassignment via settings
- Add tests for `Event` creation on moderator reassignment

### 9. Sorbet RBI regeneration

- Run `tapioca` to regenerate RBIs after the column rename

## Verification

1. `docker compose exec web bundle exec rails test test/models/decision_test.rb`
2. `docker compose exec web bundle exec rails test test/controllers/decisions_controller_test.rb`
3. `docker compose exec web bundle exec srb tc`
4. `docker compose exec web bundle exec rubocop`
5. Manual testing:
   - Create a vote with a different moderator → moderator can close, creator cannot
   - Creator can access settings and reassign moderator back to themselves
   - Create a lottery with different moderator → same behavior
   - Executive decision → "Decision Maker" label, same close/select behavior
   - Reassign moderator → `Event` with `decision.moderator_changed` is recorded
   - API: `moderator_id` and `decision_maker_id` (backward compat) both work
