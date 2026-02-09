# Plan: RepresentationSessionEvent Model

**Status: ✅ COMPLETED** (2026-02-08)

## Problem

Current representation tracking has two overlapping mechanisms:
1. `activity_log` JSON column on RepresentationSession - stores semantic events but is hard to query
2. `RepresentationSessionAssociation` - links resources to sessions but doesn't track action type

This causes bugs: confirming read on a note creates an association, then `created_via_representation?` incorrectly returns true even though the note wasn't *created* during representation.

## Solution

Create a proper `RepresentationSessionEvent` model that replaces both mechanisms:
- One event per record created/modified
- `action_name` using ActionsHelper naming convention
- `resource` and `context_resource` for clear semantics
- `request_id` for grouping bulk actions deterministically

## Implementation Summary

| Before | After |
|--------|-------|
| `activity_log` JSON column | `RepresentationSessionEvent` records |
| `RepresentationSessionAssociation` table | Removed (events serve as associations) |
| `record_activity!(semantic_event)` | `record_event!(action_name, resource, context_resource)` |
| One association per resource | One event per resource per action |
| `has_one :representation_session_association` | `has_many :representation_session_events` |
| `created_via_representation?` checks any association | `created_via_representation?` checks for creation action |

## Completed Phases

### Phase 1: Create RepresentationSessionEvent Model ✅

- Created migration `db/migrate/20260208191548_create_representation_session_events.rb`
- Created model `app/models/representation_session_event.rb`
- Includes `MightNotBelongToSuperagent` for proper scoping with NULL superagent_id

### Phase 2: Create HasRepresentationSessionEvents Concern ✅

- Created `app/models/concerns/has_representation_session_events.rb`
- Provides: `created_via_representation?`, `creation_representation_session`, `representative_user`

### Phase 3: Update RepresentationSession ✅

- Added `record_event!` and `record_events!` methods
- Added `human_readable_events_log` (replacing old `human_readable_activity_log`)
- Updated `action_count` to use events table

### Phase 4: Data Migration ⏭️ SKIPPED

- User indicated backwards compatibility was not needed
- No existing data to migrate

### Phase 5: Update Callers ✅

- Updated all `record_activity!` calls in `app/services/api_helper.rb` to use `record_event!`
- Covered actions: create_note, create_decision, create_commitment, vote, add_options, confirm_read, send_heartbeat, add_comment, join_commitment, pin/unpin, update settings

### Phase 6: Cleanup ✅

- Created migration `db/migrate/20260208234822_remove_activity_log_system_from_representation_sessions.rb`
- Removed `activity_log` column from `representation_sessions` table
- Dropped `representation_session_associations` table
- Deleted `app/models/representation_session_association.rb`
- Deleted `app/models/concerns/has_representation_session_associations.rb`
- Updated 8 models to use new concern:
  - Note, Decision, Commitment, Heartbeat
  - Vote, Option, CommitmentParticipant, NoteHistoryEvent

## Files Changed

| File | Changes |
|------|---------|
| `db/migrate/20260208191548_create_representation_session_events.rb` | New - creates events table |
| `db/migrate/20260208234822_remove_activity_log_system_from_representation_sessions.rb` | New - removes old system |
| `app/models/representation_session_event.rb` | New model |
| `app/models/concerns/has_representation_session_events.rb` | New concern |
| `app/models/representation_session.rb` | Added `record_event!`, `record_events!`, `human_readable_events_log` |
| `app/models/note.rb` | Changed to `HasRepresentationSessionEvents` |
| `app/models/decision.rb` | Changed to `HasRepresentationSessionEvents` |
| `app/models/commitment.rb` | Changed to `HasRepresentationSessionEvents` |
| `app/models/vote.rb` | Changed to `HasRepresentationSessionEvents` |
| `app/models/option.rb` | Changed to `HasRepresentationSessionEvents` |
| `app/models/heartbeat.rb` | Changed to `HasRepresentationSessionEvents` |
| `app/models/note_history_event.rb` | Changed to `HasRepresentationSessionEvents` |
| `app/models/commitment_participant.rb` | Changed to `HasRepresentationSessionEvents` |
| `app/services/api_helper.rb` | Changed all `record_activity!` → `record_event!` |
| `app/services/data_deletion_manager.rb` | Changed `RepresentationSessionAssociation` → `RepresentationSessionEvent` |
| `test/models/representation_session_test.rb` | Rewritten for new event system |
| `test/integration/trustee_grant_flow_test.rb` | Updated to use `record_event!` |
| `test/test_helper.rb` | Removed `activity_log` from session creation |
| `app/models/representation_session_association.rb` | **Deleted** |
| `app/models/concerns/has_representation_session_associations.rb` | **Deleted** |

## Verification ✅

All 2138 tests pass. The system correctly:
- Records events when actions are taken during representation
- Groups bulk actions by `request_id` for activity log display
- Distinguishes between creation events and other events (e.g., `confirm_read` doesn't mark note as "created via representation")

## Terminology Reference

| Column | Purpose | Example |
|--------|---------|---------|
| `resource` | The record this event is about | Vote, Option, Note |
| `context_resource` | Parent for navigation/grouping (nullable) | Decision, Note |
| `action_name` | ActionsHelper action name | "vote", "add_options", "create_note" |
| `request_id` | Groups all events from same HTTP request | For bulk actions |

## Action Examples

| Action | resource | context_resource |
|--------|----------|------------------|
| `create_note` | Note | nil |
| `create_decision` | Decision | nil |
| `add_comment` | Note (comment) | Note/Decision/Commitment |
| `add_options` (3 options) | Option #1, #2, #3 | Decision |
| `vote` (2 votes) | Vote #1, #2 | Decision |
| `join_commitment` | CommitmentParticipant | Commitment |
| `confirm_read` | NoteHistoryEvent | Note |
| `update_note` | Note | nil |
| `pin_note` | Note | nil |
