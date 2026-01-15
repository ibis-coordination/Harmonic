# Plan: Rename Studio to Superagent

## Summary

Rename the `Studio` model to `Superagent` throughout the codebase. This is a backend-only change - users still see "studios" in the UI.

**Scope:**
- `Studio` → `Superagent` (model, table, foreign keys)
- `StudioUser` → `SuperagentMember` (model and table)
- `StudioInvite` → `Invite` (model and table)
- `studio_type` → `superagent_type` (column name, values stay 'studio'/'scene')
- `studio_id` → `superagent_id` (all 18+ foreign key columns)
- `:studio_handle` → `:superagent_handle` (route params)
- URL routes stay as `/studios/` and `/scenes/` (no user-facing changes)

---

## Phase 1: Database Migration

Create a single reversible migration to rename tables and columns.

**Tables to rename:**
- `studios` → `superagents`
- `studio_users` → `superagent_members`
- `studio_invites` → `invites`

**Columns to rename:**
- `superagents.studio_type` → `superagent_type`
- `tenants.main_studio_id` → `main_superagent_id`
- `studio_id` → `superagent_id` in: attachments, commitment_participants, commitments, cycle_data_rows, decision_participants, decisions, events, heartbeats, invites, links, note_history_events, notes, options, representation_session_associations, representation_sessions, superagent_members, votes, webhooks
- `links.resource_studio_id` → `resource_superagent_id`
- `representation_session_associations.resource_studio_id` → `resource_superagent_id`

**Database views to recreate:**
- `cycle_data_commitments`, `cycle_data_decisions`, `cycle_data_notes`, `cycle_data_view`

**File:** `db/migrate/YYYYMMDDHHMMSS_rename_studio_to_superagent.rb`

---

## Phase 2: Core Models

### 2A: Rename primary model files

| Old File | New File | Key Changes |
|----------|----------|-------------|
| `app/models/studio.rb` | `app/models/superagent.rb` | Class `Studio` → `Superagent`, thread-locals `[:studio_id]` → `[:superagent_id]`, `scope_thread_to_studio` → `scope_thread_to_superagent` |
| `app/models/studio_user.rb` | `app/models/superagent_member.rb` | Class `StudioUser` → `SuperagentMember`, `belongs_to :studio` → `belongs_to :superagent` |
| `app/models/studio_invite.rb` | `app/models/invite.rb` | Class `StudioInvite` → `Invite`, update associations |

### 2B: Update ApplicationRecord

**File:** `app/models/application_record.rb`
- `belongs_to_studio?` → `belongs_to_superagent?`
- `set_studio_id` → `set_superagent_id`
- Default scope: `Studio.current_id` → `Superagent.current_id`
- Column check: `studio_id` → `superagent_id`

### 2C: Update models with `belongs_to :studio`

All 18 models need `belongs_to :studio` → `belongs_to :superagent`:
- attachment.rb, commitment.rb, commitment_participant.rb, cycle_data_row.rb
- decision.rb, decision_participant.rb, event.rb, heartbeat.rb
- link.rb (also `resource_studio` → `resource_superagent`)
- note.rb, note_history_event.rb, option.rb
- representation_session.rb, representation_session_association.rb
- vote.rb, webhook.rb

### 2D: Update related models

- `app/models/tenant.rb`: `main_studio` → `main_superagent`
- `app/models/user.rb`: `studio_users` → `superagent_members`, `studios` → `superagents`
- `app/models/scene.rb`: `class Scene < Studio` → `class Scene < Superagent`

### 2E: Update concerns

- `app/models/concerns/pinnable.rb`
- `app/models/concerns/attachable.rb`
- `app/models/concerns/commentable.rb`
- `app/models/concerns/has_feature_flags.rb`

---

## Phase 3: Controllers

### 3A: ApplicationController (critical)

**File:** `app/controllers/application_controller.rb`
- `current_studio` → `current_superagent`
- `@current_studio` → `@current_superagent`
- `current_studio_invite` → `current_invite`
- `params[:studio_handle]` → `params[:superagent_handle]`
- Keep `@current_studio` alias for view compatibility initially

### 3B: Update all controllers

Controllers referencing `current_studio` (search for `current_studio`, `Studio.`, `studio_id`):
- studios_controller.rb, scenes_controller.rb
- notes_controller.rb, decisions_controller.rb, commitments_controller.rb
- cycles_controller.rb, heartbeats_controller.rb, webhooks_controller.rb
- representation_sessions_controller.rb, users_controller.rb
- autocomplete_controller.rb, home_controller.rb
- api/v1/studios_controller.rb, api/v1/base_controller.rb

---

## Phase 4: Routes

**File:** `config/routes.rb`

Change parameter name only (URL paths stay the same):
- `:studio_handle` → `:superagent_handle` throughout
- Keep path segments as `/studios/` and `/scenes/`

---

## Phase 5: Services

Update all services referencing Studio:
- `app/services/api_helper.rb` - `current_studio` → `current_superagent`
- `app/services/actions_helper.rb` - action definitions
- `app/services/event_service.rb` - `Studio.current_id` → `Superagent.current_id`
- `app/services/feature_flag_service.rb`
- `app/services/webhook_dispatcher.rb`
- `app/services/data_deletion_manager.rb`
- `app/services/link_parser.rb`
- `app/services/markdown_renderer.rb`
- `app/services/webhook_test_service.rb`

---

## Phase 6: Views

Update view references (keep user-facing text as "studio"):
- All files in `app/views/studios/`
- All files in `app/views/scenes/`
- Shared partials: `_more_button_studio.html.erb`, `actions_index_studio.html.erb`
- Home views: `_homepage_studio_section.html.erb`, `_scenes_section.html.erb`
- User views referencing studios

---

## Phase 7: JavaScript

**Files:**
- Rename `subagent_studio_adder_controller.ts` → `subagent_superagent_adder_controller.ts`
- Update `app/javascript/controllers/index.ts` imports
- Update data attributes and JSON keys (`studio_id` → `superagent_id`)

---

## Phase 8: Tests

### 8A: Test helper

**File:** `test/test_helper.rb`
- Update `create_studio` → `create_superagent` (keep alias)
- Update teardown deletion order
- Update thread-local clearing

### 8B: Update test files (44+ files)

- Model tests: studio_test.rb → superagent_test.rb, studio_user_test.rb → superagent_member_test.rb
- Integration tests: api_studios_test.rb, notification_studio_privacy_test.rb, etc.
- Service tests: all services with studio references

---

## Phase 9: Sorbet Types

- Delete old RBI files: `sorbet/rbi/dsl/studio.rbi`, `studio_user.rbi`, `studio_invite.rbi`
- Regenerate: `bundle exec srb tc`

---

## Phase 10: Documentation

Update:
- `CLAUDE.md`
- `docs/ARCHITECTURE.md`
- `docs/USER_TYPES.md`
- Run `./scripts/check-todo-index.sh --all`

---

## Verification

After implementation, run:
```bash
# Run tests
./scripts/run-tests.sh

# Run linter
docker compose exec web bundle exec rubocop

# Run type checker
docker compose exec web bundle exec srb tc

# Run TypeScript check
docker compose exec js npm run typecheck

# Manual verification
# - Create a new studio
# - Join a studio
# - Create notes/decisions/commitments
# - Test representation sessions
```

---

## Critical Files (in order of risk)

1. `db/migrate/XXX_rename_studio_to_superagent.rb` - Database migration
2. `app/models/superagent.rb` - Core model with thread-local scoping
3. `app/models/application_record.rb` - Default scope logic
4. `app/controllers/application_controller.rb` - `current_superagent` method
5. `config/routes.rb` - Route parameter names
6. `test/test_helper.rb` - Test setup/teardown

---

## Rollback Plan

If issues arise:
```bash
# Rollback migration
docker compose exec web bundle exec rails db:rollback

# Revert code
git checkout main

# Restart
./scripts/stop.sh && ./scripts/start.sh
```
