# Known Bugs

This file tracks known bugs discovered during testing. Each bug includes a description, location, and any relevant test references.

## API Controller Bugs

### 1. Tenant#users has_many through association order issue

**Location:** `app/models/tenant.rb`

**Description:** The `has_many :users, through: :tenant_users` association is defined before `has_many :tenant_users`, causing an `ActiveRecord::HasManyThroughOrderError`.

**Affected endpoints:**
- `GET /api/v1/users/:id`
- `PUT /api/v1/users/:id`
- `DELETE /api/v1/users/:id`

**Test references:**
- `test/integration/api_users_test.rb` (multiple skipped tests)

---

### 2. Option model missing api_json method

**Location:** `app/models/option.rb`

**Description:** The `Option` model does not implement an `api_json` method, but the API controllers expect it when serializing options.

**Affected endpoints:**
- `GET /api/v1/decisions/:id?include=options`
- `GET /api/v1/decisions/:id/options`

**Test references:**
- `test/integration/api_decisions_test.rb`: `test_show_with_include=options_returns_options`
- `test/integration/api_decisions_test.rb`: `test_list_options_returns_all_options`

---

### 3. CommitmentParticipant#api_json wrong method signature

**Location:** `app/models/commitment_participant.rb`

**Description:** The `api_json` method doesn't accept keyword arguments like `include:`, but `BaseController#index` calls it with `api_json(include: includes_param)`.

**Affected endpoints:**
- `GET /api/v1/commitments/:id/participants`

**Test references:**
- `test/integration/api_commitments_test.rb` (participant list test removed)

---

### 4. StudiosController typo: references 'note' instead of 'studio'

**Location:** `app/controllers/api/v1/studios_controller.rb`, line 28

**Description:** In the `update` method, there's a check `return render json: { error: 'Studio not found' }, status: 404 unless note` - should be `unless studio`.

**Affected endpoints:**
- `PUT /api/v1/studios/:id`

**Test references:**
- `test/integration/api_studios_test.rb`: `test_update_updates_a_studio`
- `test/integration/api_studios_test.rb`: `test_update_can_change_tempo`
- `test/integration/api_studios_test.rb`: `test_update_handle_without_force_update_returns_error`

---

### 5. StudiosController destroy typo: references 'studio' column

**Location:** `app/controllers/api/v1/studios_controller.rb`, line 52

**Description:** The destroy method has `find_by(studio: params[:id])` which should be `find_by(handle: params[:id])`.

**Affected endpoints:**
- `DELETE /api/v1/studios/:id`

**Test references:**
- `test/integration/api_studios_test.rb`: `test_delete_returns_404_for_non-existent_studio`

---

### 6. Studio#delete! not implemented

**Location:** `app/models/studio.rb`, line ~390

**Description:** The `delete!` method raises `RuntimeError: Delete not implemented`.

**Affected endpoints:**
- `DELETE /api/v1/studios/:id`

**Test references:**
- `test/integration/api_studios_test.rb`: `test_delete_deletes_a_studio`

---

### 7. ApiToken scope validation doesn't recognize 'studios' resource

**Location:** `app/models/api_token.rb`, line 117

**Description:** The `can?` method raises `RuntimeError: Invalid resource: studios` because 'studios' is not in the `valid_resources` list.

**Affected endpoints:**
- `POST /api/v1/studios` (with read-only token)

**Test references:**
- `test/integration/api_studios_test.rb`: `test_create_with_read-only_token_returns_forbidden`

---

### 8. ApiToken scope validation doesn't recognize 'apitokens' resource

**Location:** `app/models/api_token.rb`, line 117

**Description:** The `can?` method raises `RuntimeError: Invalid resource: apitokens` because the resource name is derived incorrectly (should be 'api_tokens').

**Affected endpoints:**
- Token endpoints with read-only tokens

**Test references:**
- `test/integration/api_tokens_test.rb`: `test_create_with_read-only_token_returns_forbidden`
- `test/integration/api_tokens_test.rb`: `test_token_with_read_scope_can_read_but_not_write`

---

### 9. Notes confirm route points to wrong controller

**Location:** `config/routes.rb`

**Description:** The route `post :confirm, to: 'note#confirm'` points to `NoteController` (singular) which doesn't exist. Should be `notes#confirm`.

**Affected endpoints:**
- `POST /api/v1/notes/:id/confirm`

**Test references:**
- `test/integration/api_notes_test.rb`: `test_confirm_creates_a_read_confirmation_event`

---

### 10. UsersController#create references undefined generate_token method

**Location:** `app/controllers/api/v1/users_controller.rb`, line 17

**Description:** The create action calls `generate_token(user)` but this method is not defined.

**Affected endpoints:**
- `POST /api/v1/users` with `generate_token: true`

**Test references:**
- `test/integration/api_users_test.rb`: `test_create_with_generate_token_returns_token`

---

### 11. LinkParser fails when studio is main studio

**Location:** `app/services/link_parser.rb` or `app/models/concerns/linkable.rb`

**Description:** Creating decisions with options fails when the studio is the main studio, due to link parsing issues.

**Affected endpoints:**
- `POST /api/v1/decisions` (with options, in main studio context)

**Test references:**
- `test/integration/api_decisions_test.rb`: `test_create_with_options_creates_decision_and_options`

---

## Summary

| Bug # | Severity | Component | Status |
|-------|----------|-----------|--------|
| 1 | High | Tenant model | Open |
| 2 | Medium | Option model | Open |
| 3 | Medium | CommitmentParticipant model | Open |
| 4 | High | StudiosController | Open |
| 5 | Medium | StudiosController | Open |
| 6 | Medium | Studio model | Open |
| 7 | Medium | ApiToken model | Open |
| 8 | Medium | ApiToken model | Open |
| 9 | Medium | Routes | Open |
| 10 | Low | UsersController | Open |
| 11 | Medium | LinkParser | Open |
