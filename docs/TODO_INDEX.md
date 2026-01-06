# TODO Index

This document catalogs all TODO comments in the codebase, organized by category and priority. Use this as a reference when looking for improvement opportunities.

> **Last updated**: January 2026
> **Total TODOs**: 44

---

## Summary by Category

| Category | Count | Priority |
|----------|-------|----------|
| [Webhooks & Tracking](#webhooks--tracking) | 4 | Medium |
| [Validation & Error Handling](#validation--error-handling) | 7 | Medium |
| [Performance](#performance) | 3 | Low |
| [Security & Authorization](#security--authorization) | 4 | High |
| [Refactoring & Cleanup](#refactoring--cleanup) | 8 | Low |
| [Feature Gaps](#feature-gaps) | 7 | Medium |
| [UI/UX](#uiux) | 3 | Low |
| [API Improvements](#api-improvements) | 5 | Medium |
| [Edge Cases](#edge-cases) | 3 | Medium |

---

## Webhooks & Tracking

Webhook functionality is stubbed but not implemented. See `app/services/webhook_services/` for the intended architecture.

| File | Line | Description |
|------|------|-------------|
| `app/models/concerns/tracked.rb` | 5 | Change to `around_` callbacks so tracked changes occur within DB transaction |
| `app/models/concerns/tracked.rb` | 13 | Implement `track_creation` - queue webhook for create events |
| `app/models/concerns/tracked.rb` | 18 | Implement `track_changes` - queue webhook for update events |
| `app/models/concerns/tracked.rb` | 23 | Implement `track_deletion` - queue webhook for delete events |

---

## Validation & Error Handling

| File | Line | Description |
|------|------|-------------|
| `app/services/decision_participant_manager.rb` | 9 | Add validations for decision participant creation |
| `app/services/commitment_participant_manager.rb` | 9 | Add validations for commitment participant creation |
| `app/models/representation_session.rb` | 35 | Add check for active representation session |
| `app/models/representation_session.rb` | 37 | Add more validations for representation sessions |
| `app/controllers/api/v1/decisions_controller.rb` | 12 | Detect specific validation errors and return helpful messages |
| `app/controllers/api/v1/commitments_controller.rb` | 34 | Detect specific validation errors and return helpful messages |
| `app/controllers/api/v1/api_tokens_controller.rb` | 23 | Detect specific validation errors and return helpful messages |

---

## Performance

| File | Line | Description |
|------|------|-------------|
| `app/models/cycle.rb` | 427 | Make homepage query more efficient (ideally one query) |
| `app/controllers/studios_controller.rb` | 202 | Make studio listing more efficient |
| `app/models/decision.rb` | 129 | Clean up `voters` method - inefficient query pattern |

---

## Security & Authorization

| File | Line | Description |
|------|------|-------------|
| `app/controllers/sessions_controller.rb` | 133 | Check if user is allowed to access tenant |
| `app/controllers/application_controller.rb` | 238 | Handle invalid representation session - security concerns unclear |
| `app/controllers/studios_controller.rb` | 182 | Check studio settings for public join permission |
| `app/models/user.rb` | 102 | Check trustee permissions for non-studio trustee users |

---

## Refactoring & Cleanup

| File | Line | Description |
|------|------|-------------|
| `app/controllers/application_controller.rb` | 14 | Remove `current_app` method - logic no longer needed |
| `app/controllers/application_controller.rb` | 183 | Add `last_seen_at` to StudioUser instead of using touch |
| `app/models/note_history_event.rb` | 42 | Refactor note history event logic |
| `app/models/cycle_data_row.rb` | 156 | Change `participants` to `readers` |
| `app/models/api_token.rb` | 31 | Remove invalid scopes (e.g., 'create:cycles', 'update:results') |
| `app/controllers/api/v1/options_controller.rb` | 14 | Abstract `api_json` pattern into base controller and base model |
| `app/controllers/application_controller.rb` | 175 | Decide how to handle trustee not being member of studio |
| `app/models/heartbeat.rb` | 7 | Add activity log functionality |

---

## Feature Gaps

| File | Line | Description |
|------|------|-------------|
| `app/controllers/admin_controller.rb` | 22 | Add Home page, About page, Help page, Contact page |
| `app/models/cycle.rb` | 96 | Implement `group_by`, `selections`, `cycle_name` for cycles |
| `app/models/cycle.rb` | 181 | Handle year, month, week, day cycle periods |
| `app/services/decision_participant_manager.rb` | 18 | Allow users to claim `participant_uid` after logging in |
| `app/services/commitment_participant_manager.rb` | 18 | Allow users to claim `participant_uid` after logging in |
| `app/controllers/api/v1/info_controller.rb` | 5 | Use token scopes to determine what info to show |
| `app/controllers/api/v1/info_controller.rb` | 8 | Use config variable to track API version |

---

## UI/UX

| File | Line | Description |
|------|------|-------------|
| `app/views/shared/_deadline_display.html.erb` | 8 | Add close button to deadline display |
| `app/javascript/controllers/collapseable_section_controller.js` | 59 | Show a spinner during collapse/expand |
| `app/javascript/controllers/decision_controller.js` | 92 | Get server to generate voting URL instead of client |

---

## API Improvements

| File | Line | Description |
|------|------|-------------|
| `app/controllers/api/v1/options_controller.rb` | 19 | Record approval when in representation session |
| `app/controllers/api/v1/options_controller.rb` | 28 | Check for existing approvals before creating |
| `app/controllers/api/v1/options_controller.rb` | 31 | Record unapproval when in representation session |
| `app/javascript/controllers/decision_voters_controller.js` | 12 | Only poll if decision is open |
| `app/javascript/controllers/decision_results_controller.js` | 12 | Only poll if decision is open |

---

## Edge Cases

| File | Line | Description |
|------|------|-------------|
| `app/services/data_deletion_manager.rb` | 78 | Handle case where deleted user is only admin and no other users exist |
| `app/controllers/representation_sessions_controller.rb` | 25 | Design better solution for representation session edge case |
| `app/models/user.rb` | 226 | Track invite accepted event |

---

## Quick Wins

These TODOs are straightforward to address:

1. **Remove dead code**: `app/controllers/application_controller.rb:14` - `current_app` method
2. **Fix naming**: `app/models/cycle_data_row.rb:156` - rename `participants` to `readers`
3. **Clean up scopes**: `app/models/api_token.rb:31` - remove invalid token scopes
4. **Add version config**: `app/controllers/api/v1/info_controller.rb:8` - use env var for version

## High Impact

These TODOs would significantly improve the codebase:

1. **Implement webhooks**: `app/models/concerns/tracked.rb` - enables external integrations
2. **Security review**: `app/controllers/application_controller.rb:238` - clarify security model
3. **Performance**: `app/models/cycle.rb:427` - homepage query optimization
4. **Validation errors**: All API controllers - better error messages for clients

---

## Generating This Index

To regenerate this index, run:

```bash
grep -rn "# TODO\|// TODO\|<!-- TODO" app/ --include="*.rb" --include="*.js" --include="*.erb" | sort
```
