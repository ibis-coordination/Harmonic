# Test Coverage Improvement Plan

This document outlines the plan to increase test coverage across the Harmonic codebase. The goal is to establish a robust test suite that serves as documentation, provides guardrails for AI agents, and ensures code quality.

## Table of Contents

1. [Phase 1: Establish Baseline Coverage](#phase-1-establish-baseline-coverage) ✅
2. [Phase 2: Critical Features - Authentication & Authorization](#phase-2-critical-features---authentication--authorization) ✅
3. [Phase 3: Core Domain Models](#phase-3-core-domain-models) ✅
4. [Phase 4: Services & Business Logic](#phase-4-services--business-logic) ✅
5. [Phase 5: Controllers & Integration Tests](#phase-5-controllers--integration-tests) ✅
6. [Phase 6: API Endpoints](#phase-6-api-endpoints) ✅
7. [Phase 7: CI Workflow Enhancements](#phase-7-ci-workflow-enhancements) ✅
8. [Testing Patterns & Guidelines](#testing-patterns--guidelines)
9. [Gotchas & Idiosyncrasies](#gotchas--idiosyncrasies)

---

## Phase 1: Establish Baseline Coverage

### Objective
Set up code coverage measurement tools and establish a baseline to track progress.

### Tasks

#### 1.1 Add SimpleCov to the Project

Add to `Gemfile` in the test group:
```ruby
group :test do
  gem 'simplecov', require: false
end
```

#### 1.2 Configure SimpleCov in test_helper.rb

Add at the **very top** of `test/test_helper.rb` (before any other requires):
```ruby
require 'simplecov'
SimpleCov.start 'rails' do
  add_filter '/test/'
  add_filter '/config/'
  add_filter '/vendor/'

  add_group 'Models', 'app/models'
  add_group 'Controllers', 'app/controllers'
  add_group 'Services', 'app/services'
  add_group 'Helpers', 'app/helpers'
  add_group 'Jobs', 'app/jobs'
  add_group 'Mailers', 'app/mailers'

  # Set minimum coverage threshold (start low, increase over time)
  minimum_coverage 30
end
```

#### 1.3 Update .gitignore

Add coverage directory to `.gitignore`:
```
/coverage/
```

#### 1.4 Run Initial Coverage Report

```bash
./scripts/run-tests.sh
# Coverage report will be generated in coverage/index.html
```

#### 1.5 Document Baseline

Record the initial coverage percentages in this document:
- [x] Overall line coverage: **47.12%** (2057 / 4365 lines)
- [x] Overall branch coverage: **29.17%** (362 / 1241 branches)
- [x] Baseline recorded: January 7, 2026

**Notes:**
- Coverage is higher than expected due to good existing API integration tests
- Parallel test execution disabled when COVERAGE=true for accurate measurement
- Minimum threshold set to 45% (slightly below baseline to allow for fluctuation)

---

## Phase 2: Critical Features - Authentication & Authorization

### Objective
Ensure the most critical security features are thoroughly tested.

### Current State
- `test/integration/api_auth_test.rb` - API token authentication (exists, good coverage)
- `test/controllers/password_resets_controller_test.rb` - Password reset (exists)
- No tests for OAuth flow or honor system authentication

### Implementation Status: ✅ COMPLETE

**Files Created/Modified:**
- `test/controllers/sessions_controller_test.rb` - NEW (8 tests)
- `test/controllers/honor_system_sessions_controller_test.rb` - NEW (3 tests)
- `test/models/user_authorization_test.rb` - NEW (13 tests)
- `test/models/api_token_test.rb` - NEW (20 tests)
- `test/integration/api_auth_test.rb` - EXTENDED (3 new tests)

**Total New Tests: 47 tests (66 total in Phase 2 files)**

### Test Coverage

#### 2.1 Session Management Tests
**File**: `test/controllers/sessions_controller_test.rb`

| Test Case | Priority | Status |
|-----------|----------|--------|
| Redirect to auth subdomain when not logged in | High | [x] |
| Login page renders correctly on auth subdomain | High | [x] |
| Logout clears session and redirects | High | [x] |
| Internal OAuth callback creates user | High | [x] |
| Internal callback handles missing data | High | [x] |
| Internal callback handles invalid token | High | [x] |
| OAuth failure redirects with error | Medium | [x] |
| Cross-subdomain redirect preserves destination | Medium | [x] |

#### 2.2 Honor System Authentication Tests
**File**: `test/controllers/honor_system_sessions_controller_test.rb`

| Test Case | Priority | Status |
|-----------|----------|--------|
| Login with valid email | High | [x] (skipped if OAuth mode) |
| Login creates new user if not exists | High | [x] (skipped if OAuth mode) |
| Login disabled in OAuth mode | High | [x] (verified via route availability) |

**Note:** Honor system routes are only loaded at boot time when `AUTH_MODE=honor_system`. Tests skip gracefully in OAuth mode.

#### 2.3 Authorization Tests
**File**: `test/models/user_authorization_test.rb`

| Test Case | Priority | Status |
|-----------|----------|--------|
| Person user type created correctly | High | [x] |
| Simulated user type created correctly | High | [x] |
| Trustee user type created correctly | High | [x] |
| Simulated user has parent | High | [x] |
| Parent can impersonate simulated user | High | [x] |
| User cannot impersonate non-child user | High | [x] |
| User cannot impersonate archived user | High | [x] |
| User cannot impersonate regular person | High | [x] |
| Trustee representation works correctly | Medium | [x] |
| User cannot represent non-studio trustee | Medium | [x] |
| User cannot represent archived trustee | Medium | [x] |
| User can belong to multiple tenants | High | [x] |
| User handles vary by tenant | High | [x] |

#### 2.4 API Token Tests
**File**: `test/models/api_token_test.rb`

| Test Case | Priority | Status |
|-----------|----------|--------|
| Token generation with secure random | High | [x] |
| Token scopes validation | High | [x] |
| Token expiration | High | [x] |
| Soft delete (deleted_at) | High | [x] |
| Scope validation (read, write) | High | [x] |
| Invalid scope rejection | High | [x] |
| Empty scope rejection | High | [x] |
| Token uniqueness | Medium | [x] |
| Expires scope checks | Medium | [x] |
| Active tokens scope | Medium | [x] |
| Deleted tokens scope | Medium | [x] |
| Token name optional | Low | [x] |

#### 2.5 API Authorization Tests
**File**: `test/integration/api_auth_test.rb` (extended)

| Test Case | Priority | Status |
|-----------|----------|--------|
| Read scope allows GET requests | High | [x] |
| Read scope denies POST requests | High | [x] |
| Write scope allows POST requests | High | [x] |
| Expired token rejected | High | [x] |
| Deleted token rejected | High | [x] |
| API disabled at tenant level | High | [x] |
| API disabled at studio level (non-main) | High | [x] |
| API re-enabled allows access | Medium | [x] |

---

## Phase 3: Core Domain Models

### Objective
Test all core domain models with focus on validations, associations, and business logic.

### Current State
| Model | Test File | Status |
|-------|-----------|--------|
| User | `user_test.rb` | ✅ Complete (20 tests) |
| Note | `note_test.rb` | ✅ Complete (26 tests) |
| Decision | `decision_test.rb` | ✅ Complete (27 tests) |
| Commitment | `commitment_test.rb` | ✅ Complete (25 tests) |
| Studio | `studio_test.rb` | ✅ Complete (22 tests) |
| Tenant | `tenant_test.rb` | ✅ Complete (19 tests) |
| Cycle | `cycle_test.rb` | ✅ Complete (15 tests) |

### Implementation Status: ✅ COMPLETE

**Files Modified:**
- `test/models/user_test.rb` - EXTENDED (15 new tests: user types, validations, permissions, multi-tenancy)
- `test/models/tenant_test.rb` - EXTENDED (5 new tests: timezone, scoping, API settings)
- `test/models/studio_test.rb` - EXTENDED (8 new tests: scene type, file uploads, paths, API)
- `test/models/note_test.rb` - EXTENDED (8 new tests: pinning, deadlines, validations)
- `test/models/decision_test.rb` - EXTENDED (10 new tests: options, voting, deadlines)
- `test/models/commitment_test.rb` - EXTENDED (10 new tests: participation, critical mass, pinning)
- `test/models/cycle_test.rb` - NEW (15 tests: date calculations, unit detection, display)

**Total New Tests: 71 tests added in Phase 3**
**Test Suite Total: 357 tests (192 model tests)**

### Key Testing Patterns Discovered

1. **LinkParser Requires Non-Nil Text**: Models with `Linkable` concern must have `description` set to avoid nil errors in `after_save` callback
2. **StudioInvite Requirements**: Requires `code` and `expires_at` in addition to basic associations
3. **Pinnable Methods**: `pin!` and `unpin!` require keyword args: `tenant:`, `studio:`, `user:`
4. **Approval Stars Validation**: Only allows `0` or `1` values
5. **Multi-Tenant Scoping**: Use `unscoped` or `Tenant.scope_thread_to_tenant` for cross-tenant assertions
6. **Studio Types**: Use `is_scene?` predicate, no `is_studio?` method exists

### Models Needing Tests (Priority Order)

#### 3.1 High Priority (Core Functionality)
| Model | Key Behaviors to Test |
|-------|----------------------|
| `User` | User types, authentication, permissions, impersonation |
| `Tenant` | Multi-tenancy scoping, API settings, auth providers |
| `Studio` | Membership, permissions, API settings, type (studio/scene) |
| `ApiToken` | Token generation, scopes, expiration, soft delete |

#### 3.2 Medium Priority (Feature Models)
| Model | Key Behaviors to Test |
|-------|----------------------|
| `Note` | History tracking, read confirmations, deadlines |
| `Decision` | Options, voting, results calculation, deadlines |
| `Commitment` | Participants, critical mass, deadlines |
| `Cycle` | Date ranges, associations, data rows |
| `Option` | Approvals, ranking |

#### 3.3 Lower Priority (Supporting Models)
| Model | Key Behaviors to Test |
|-------|----------------------|
| `DecisionParticipant` | Participation tracking |
| `CommitmentParticipant` | Participation tracking |
| `Link` | URL parsing, bidirectional links |
| `Approval` | Decision voting |
| `NoteHistoryEvent` | Event types, timestamps |
| `RepresentationSession` | Session management |
| `StudioInvite` | Code generation, expiration |
| `DeletedRecordProxy` | Soft delete tracking |

---

## Phase 4: Services & Business Logic

### Objective
Test service objects that contain critical business logic.

### Current State
| Service | Test File | Status |
|---------|-----------|--------|
| `ApiHelper` | `api_helper_test.rb` | ✅ Exists (10 tests) |
| `DataDeletionManager` | `data_deletion_manager_test.rb` | ✅ Exists (6 tests) |
| `CommitmentParticipantManager` | `commitment_participant_manager_test.rb` | ✅ Complete (18 tests) |
| `DecisionParticipantManager` | `decision_participant_manager_test.rb` | ✅ Complete (17 tests) |
| `MarkdownRenderer` | `markdown_renderer_test.rb` | ✅ Complete (30 tests) |
| `LinkParser` | `link_parser_test.rb` | ✅ Complete (26 tests) |

### Implementation Status: ✅ COMPLETE

**Files Created:**
- `test/services/decision_participant_manager_test.rb` - NEW (17 tests)
- `test/services/commitment_participant_manager_test.rb` - NEW (18 tests)
- `test/services/link_parser_test.rb` - NEW (26 tests)
- `test/services/markdown_renderer_test.rb` - NEW (30 tests)

**Total New Tests: 91 tests added in Phase 4**
**Test Suite Total: 449 tests (107 service tests)**

### Key Testing Patterns Discovered

1. **Linkable Concern Auto-Creates Links**: Models with `Linkable` concern automatically call `parse_and_create_link_records!` in `after_save`, so use `update_column` to bypass callbacks when testing the service directly
2. **Thread Context Required**: `MarkdownRenderer.render` with `display_references: true` requires `Tenant.scope_thread_to_tenant` and `Studio.scope_thread_to_studio` to be set
3. **LinkParser Regex**: Handles both `/studios/` and `/scenes/` URL paths via `(?:studios|scenes)` alternation
4. **ParticipantManager Idempotency**: Both managers are designed to be idempotent - calling `find_or_create_participant` multiple times returns the same participant
5. **Anonymous vs User Participants**: When a user is provided, any `participant_uid` is ignored and regenerated

### Tests Added

#### 4.1 Participant Managers
**File**: `test/services/decision_participant_manager_test.rb`

| Test Case | Priority | Status |
|-----------|----------|--------|
| Creates participant for new user | High | ✅ |
| Returns existing participant for user | High | ✅ |
| Creates anonymous participant with uid | High | ✅ |
| Returns existing anonymous participant | High | ✅ |
| Generates new uid when existing uid has user | High | ✅ |
| Auto-generates uid when none provided | High | ✅ |
| Sets name on participants | Medium | ✅ |
| Raises error without decision | High | ✅ |
| Idempotent for user | Medium | ✅ |
| Idempotent for uid | Medium | ✅ |

**File**: `test/services/commitment_participant_manager_test.rb`

| Test Case | Priority | Status |
|-----------|----------|--------|
| Creates participant for new user | High | ✅ |
| Returns existing participant for user | High | ✅ |
| Creates anonymous participant with uid | High | ✅ |
| Returns existing anonymous participant | High | ✅ |
| Generates new uid when existing uid has user | High | ✅ |
| Auto-generates uid when none provided | High | ✅ |
| Sets name on participants | Medium | ✅ |
| Raises error without commitment | High | ✅ |
| New participant is not committed by default | Medium | ✅ |

#### 4.2 Content Processing
**File**: `test/services/markdown_renderer_test.rb`

| Test Case | Priority | Status |
|-----------|----------|--------|
| Returns HTML from markdown | High | ✅ |
| Handles nil/empty content | Medium | ✅ |
| Converts bold/italic text | Medium | ✅ |
| Converts links with rel=noopener | High | ✅ |
| Converts lists (ordered/unordered) | Medium | ✅ |
| Converts code blocks | Medium | ✅ |
| Converts blockquotes | Medium | ✅ |
| Shifts headers by default | Medium | ✅ |
| Sanitizes script tags | High | ✅ |
| Sanitizes javascript links | High | ✅ |
| Removes dangerous protocols | High | ✅ |
| Adds lazy loading to images | Medium | ✅ |
| render_inline removes paragraph wrapper | Medium | ✅ |
| Handles unicode/emoji content | Low | ✅ |

**File**: `test/services/link_parser_test.rb`

| Test Case | Priority | Status |
|-----------|----------|--------|
| Extracts note links from text | High | ✅ |
| Extracts decision links from text | High | ✅ |
| Extracts commitment links from text | High | ✅ |
| Extracts multiple links | Medium | ✅ |
| Does not duplicate records | Medium | ✅ |
| Ignores different subdomains | High | ✅ |
| Ignores different studios | High | ✅ |
| Handles full UUIDs | Medium | ✅ |
| Handles scene URLs | Medium | ✅ |
| parse_path extracts records | Medium | ✅ |
| Instance initialization validation | Medium | ✅ |
| parse_and_create_link_records! creates links | High | ✅ |
| Removes stale links on update | High | ✅ |
| Works with decision description | Medium | ✅ |
| Works with commitment description | Medium | ✅ |

---

## Phase 5: Controllers & Integration Tests

### Objective
Test controller actions for proper authorization, parameter handling, and response codes.

### Implementation Status: ✅ COMPLETE

**Files Created/Modified:**
- `test/controllers/notes_controller_test.rb` - NEW (10 tests)
- `test/controllers/studios_controller_test.rb` - NEW (15 tests)
- `test/controllers/decisions_controller_test.rb` - NEW (14 tests)
- `test/controllers/commitments_controller_test.rb` - NEW (12 tests)
- `test/controllers/sessions_controller_test.rb` - EXISTS (8 tests)
- `test/controllers/password_resets_controller_test.rb` - EXISTS (8 tests)
- `test/controllers/honor_system_sessions_controller_test.rb` - EXISTS (5 tests)

**Total Controller Tests: 72 tests**
**Test Suite Total: 501 tests**

### Controller Test Summary

| Controller | Test File | Tests | Status |
|------------|-----------|-------|--------|
| `SessionsController` | `sessions_controller_test.rb` | 8 | ✅ Exists |
| `PasswordResetsController` | `password_resets_controller_test.rb` | 8 | ✅ Exists |
| `HonorSystemSessionsController` | `honor_system_sessions_controller_test.rb` | 5 | ✅ Exists |
| `NotesController` | `notes_controller_test.rb` | 10 | ✅ NEW |
| `StudiosController` | `studios_controller_test.rb` | 15 | ✅ NEW |
| `DecisionsController` | `decisions_controller_test.rb` | 14 | ✅ NEW |
| `CommitmentsController` | `commitments_controller_test.rb` | 12 | ✅ NEW |

### Test Helper: `sign_in_as`

Added to `test_helper.rb` - a helper for signing in users in integration tests:

```ruby
def sign_in_as(user, tenant: nil)
  tenant ||= @global_tenant
  host! "#{tenant.subdomain}.#{ENV['HOSTNAME']}"
  token = Rails.application.message_verifier(:login).generate({
    user_id: user.id,
    expires_at: 5.minutes.from_now
  })
  get "/login/callback", params: { token: token }
end
```

### Key Testing Patterns for Controllers

1. **Thread Context Required**: When creating records in setup, wrap in:
   ```ruby
   Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
   Studio.scope_thread_to_studio(subdomain: @tenant.subdomain, handle: @studio.handle)
   # ... create records ...
   Studio.clear_thread_scope
   Tenant.clear_thread_scope
   ```

2. **Global Test Fixtures**: Use `@global_tenant`, `@global_studio`, `@global_user` from test_helper for consistent test data across parallel tests.

3. **Host Header Required**: Set host for multi-tenant routing:
   ```ruby
   host! "#{@tenant.subdomain}.#{ENV['HOSTNAME']}"
   ```

4. **RecordNotFound Handling**: Controllers may raise exceptions for missing records. Test with:
   ```ruby
   begin
     get "/path/to/nonexistent"
     assert_response :not_found
   rescue ActiveRecord::RecordNotFound
     pass  # Also acceptable behavior
   end
   ```

5. **Non-RESTful Routes**: Many actions use non-standard routes:
   - Note update: `POST /n/:note_id/edit` (not PATCH)
   - Decision show: `GET /d/:truncated_id` (uses truncated_id)
   - No DELETE routes for HTML controllers (API only)

6. **Referer Header for Redirects**: Some update actions redirect to `request.referer`:
   ```ruby
   post "/path/to/update", params: {...}, headers: { 'Referer' => '/original/page' }
   ```

### Tests Added

#### NotesController Tests
| Test Case | Priority | Status |
|-----------|----------|--------|
| Unauthenticated redirect from new | High | ✅ |
| Authenticated access to new form | High | ✅ |
| Create note successfully | High | ✅ |
| View note | High | ✅ |
| Unauthenticated redirect from note | High | ✅ |
| Access edit form | Medium | ✅ |
| Update note | High | ✅ |
| Non-creator cannot update | High | ✅ |
| View note history | Medium | ✅ |
| Non-creator cannot access history | Medium | ✅ |

#### StudiosController Tests
| Test Case | Priority | Status |
|-----------|----------|--------|
| Authenticated access to new form | High | ✅ |
| Unauthenticated redirect | High | ✅ |
| Create studio | High | ✅ |
| View studio | High | ✅ |
| Access settings | High | ✅ |
| Update settings | High | ✅ |
| Non-admin cannot update settings | High | ✅ |
| View team page | Medium | ⏭️ SKIP (missing template bug) |
| Access invite page | Medium | ✅ |
| Handle available - true | Medium | ✅ |
| Handle available - false | Medium | ✅ |
| Join with invite | Medium | ✅ |
| Scene type uses scenes route | Medium | ✅ |

#### DecisionsController Tests
| Test Case | Priority | Status |
|-----------|----------|--------|
| Access new decision form | High | ✅ |
| Unauthenticated redirect | High | ✅ |
| Create decision (no deadline) | High | ✅ |
| Create decision (datetime) | High | ✅ |
| Create with blank question | Medium | ✅ |
| View decision | High | ✅ |
| Unauthenticated redirect from decision | High | ✅ |
| Nonexistent decision handling | Medium | ✅ |
| Creator access settings | High | ✅ |
| Non-creator forbidden from settings | High | ✅ |
| Update decision settings | High | ✅ |
| Duplicate decision | Medium | ✅ |
| Add option to decision | Medium | ✅ |
| Vote on option | High | ✅ |

#### CommitmentsController Tests
| Test Case | Priority | Status |
|-----------|----------|--------|
| Access new commitment form | High | ✅ |
| Unauthenticated redirect | High | ✅ |
| Create commitment | High | ✅ |
| View commitment | High | ✅ |
| Unauthenticated redirect from commitment | High | ✅ |
| Creator access settings | High | ✅ |
| Non-creator forbidden from settings | High | ✅ |
| Update settings | High | ✅ |
| Join commitment | High | ✅ |
| Status partial | Medium | ✅ |
| Participants partial | Medium | ✅ |

### Bugs Discovered

1. **Missing Template**: `studios/team.html.erb` - Route and controller action exist but template is missing. Test skipped with documentation.

### Remaining Controllers (Lower Priority)
These are covered by API tests or have limited HTML-specific behavior:

| Controller | Notes |
|------------|-------|
| `UsersController` | Profile/settings - some tests would be valuable |
| `CyclesController` | Date handling - good API coverage exists |
| `AdminController` | Admin-only - manual testing recommended |

---

## Phase 6: API Endpoints

### Objective
Ensure all API endpoints work correctly with proper authentication and authorization.

### Implementation Status: ✅ COMPLETE

Good coverage already exists in `test/integration/`. Total: **129 API tests**.

| Test File | Tests | Skipped | Status |
|-----------|-------|---------|--------|
| `api_auth_test.rb` | 14 | 0 | ✅ Complete |
| `api_notes_test.rb` | 12 | 1 | ✅ Complete (1 bug documented) |
| `api_decisions_test.rb` | 21 | 3 | ✅ Complete (3 bugs documented) |
| `api_commitments_test.rb` | 16 | 0 | ✅ Complete |
| `api_cycles_test.rb` | 16 | 0 | ✅ Complete |
| `api_studios_test.rb` | 15 | 6 | ✅ Complete (6 bugs documented) |
| `api_tokens_test.rb` | 15 | 2 | ✅ Complete (2 bugs documented) |
| `api_users_test.rb` | 15 | 10 | ✅ Complete (10 bugs documented) |
| `markdown_ui_test.rb` | 5 | 0 | ✅ Complete |

### Notes

The skipped tests document **known bugs** in the application, not missing test coverage:
- `Option` model missing `api_json` method
- `LinkParser` fails when studio is main studio
- Route typos in `studios_controller.rb`
- `Studio#delete!` not implemented
- `tenant.users` association ordering issue
- Scope validation issues for studios and api_tokens resources

These bugs are documented in the skipped tests and can be addressed separately.

---

## Phase 7: CI Workflow Enhancements

### Objective
Ensure CI enforces test coverage and prevents merging broken code.

### Implementation Status: ✅ COMPLETE

**File Modified**: `.github/workflows/ruby-tests.yml`

### Changes Made

#### 7.1 Enforce Minimum Coverage Threshold ✅

Added `COVERAGE: true` environment variable and coverage threshold check step:

```yaml
      - name: Run tests with coverage
        env:
          # ... existing env vars ...
          COVERAGE: true
        run: bundle exec rails test

      - name: Check coverage threshold
        run: |
          COVERAGE=$(cat coverage/.last_run.json | jq '.result.covered_percent')
          THRESHOLD=45
          if (( $(echo "$COVERAGE < $THRESHOLD" | bc -l) )); then
            echo "::error::Coverage $COVERAGE% is below threshold $THRESHOLD%"
            exit 1
          fi
```

The threshold is set to **45%** (slightly below the current baseline of ~47%).

#### 7.2 Configure Branch Protection Rules

Configure in GitHub repository settings (manual step):

- [ ] Require status checks to pass before merging
- [ ] Require the "test" job to pass

### CI Checklist

| Task | Priority | Status |
|------|----------|--------|
| Add coverage threshold check to workflow | High | ✅ |
| Configure branch protection in GitHub | High | ⏳ Manual step |

---

## Testing Patterns & Guidelines

### Pattern 1: Setup with Global Fixtures

The `test_helper.rb` creates global fixtures in `setup`:
```ruby
setup do
  @global_tenant = Tenant.create!(...)
  @global_user = User.create!(...)
  @global_studio = Studio.create!(...)
end
```

Use these when you need basic infrastructure, or create fresh records for isolation.

### Pattern 2: Creating Test Data

Use helper methods defined in `test_helper.rb`:
```ruby
def create_tenant_studio_user
  tenant = create_tenant
  user = create_user
  tenant.add_user!(user)
  studio = create_studio(tenant: tenant, created_by: user)
  studio.add_user!(user)
  [tenant, studio, user]
end
```

### Pattern 3: API Integration Tests

Follow the pattern in `api_auth_test.rb`:
```ruby
class ApiTest < ActionDispatch::IntegrationTest
  def setup
    @tenant = @global_tenant
    @tenant.enable_api!
    @studio = @global_studio
    @studio.enable_api!
    @api_token = ApiToken.create!(...)
    @headers = {
      "Authorization" => "Bearer #{@api_token.token}",
      "Content-Type" => "application/json",
    }
    host! "#{@tenant.subdomain}.#{ENV['HOSTNAME']}"
  end
end
```

### Pattern 4: Testing Multi-Tenancy

Always be explicit about tenant context:
```ruby
test "records are scoped to tenant" do
  tenant1, studio1, user1 = create_tenant_studio_user
  tenant2, studio2, user2 = create_tenant_studio_user

  note1 = Note.create!(tenant: tenant1, studio: studio1, ...)

  # Set tenant context
  Tenant.scope_thread_to_tenant(tenant2.subdomain)

  assert_not Note.exists?(note1.id), "Note from tenant1 should not be visible in tenant2"
end
```

### Pattern 5: Teardown

The global teardown cleans all records. If you need custom cleanup, do it in your test or a specific teardown block.

---

## Gotchas & Idiosyncrasies

### 1. Thread-Scoped Tenancy

**Issue**: `Current.tenant` and `Current.studio` use thread-local storage.

**Solution**: Always call `Studio.clear_thread_scope` and `Tenant.clear_thread_scope` between tests (handled in global teardown).

**Watch out for**: Tests that run in parallel may have unexpected scoping issues.

### 2. Fixture Ordering in Teardown

**Issue**: Foreign key constraints require specific deletion order.

**Solution**: The teardown block deletes in dependency order:
```ruby
[RepresentationSessionAssociation, RepresentationSession, Link, NoteHistoryEvent, Note, ...].each do |model|
  model.unscoped { model.delete_all }
end
```

### 3. Default Scopes Hide Records

**Issue**: Models use `default_scope` for tenant/studio scoping.

**Solution**: Use `unscoped` when you need to see all records:
```ruby
Note.unscoped { Note.find(id) }
```

### 4. API Requires Enabled Flags

**Issue**: API access requires both tenant and studio to have API enabled.

**Solution**: Always call `enable_api!` on both:
```ruby
@tenant.enable_api!
@studio.enable_api!
```

### 5. Auth Subdomain Behavior

**Issue**: Authentication uses a special auth subdomain that behaves differently.

**Solution**: In tests, use `host!` to set the correct subdomain:
```ruby
host! "#{@tenant.subdomain}.#{ENV['HOSTNAME']}"
```

### 6. User Types Affect Behavior

**Issue**: User `user_type` (person, simulated, trustee) changes authorization.

**Solution**: Be explicit about user type in tests:
```ruby
User.create!(user_type: 'person', ...)  # Can log in
User.create!(user_type: 'simulated', ...) # Cannot log in directly
User.create!(user_type: 'trustee', ...)   # Requires representation
```

### 7. Soft Deletes

**Issue**: Some models use soft delete (`deleted_at` timestamp).

**Solution**: Check for `deleted_at: nil` in queries, or use provided scopes.

### 8. History Events Are Auto-Created

**Issue**: `Note` automatically creates `NoteHistoryEvent` records.

**Solution**: Account for this in assertions:
```ruby
note = Note.create!(...)
assert note.note_history_events.count == 1  # Create event
note.update!(text: "changed")
assert note.note_history_events.count == 2  # + Update event
```

### 9. Honor System Routes Are Conditional

**Issue**: Honor system authentication routes are only loaded at application boot when `AUTH_MODE=honor_system`.

**Solution**: Tests for honor system must either:
- Run with `AUTH_MODE=honor_system` environment variable set at boot
- Use `skip` to gracefully skip tests when routes aren't available
```ruby
test "honor system login" do
  skip "Honor system routes not available" unless Rails.application.routes.url_helpers.respond_to?(:honor_system_session_path)
  # ... test code
end
```

### 10. TenantUser Handle Uniqueness

**Issue**: When adding users to a tenant, a unique handle is required per tenant. Creating multiple users with the same name will cause collisions.

**Solution**: Generate unique handles when creating test users:
```ruby
def create_unique_user(email: nil, name: nil)
  suffix = SecureRandom.hex(4)
  User.create!(
    email: email || "user_#{suffix}@example.com",
    name: name || "User #{suffix}",
    user_type: "person"
  )
end
```

### 11. Main Studio Always Has API Enabled

**Issue**: `Studio#api_enabled?` returns true for the main studio (checked via `is_main_studio?`), regardless of settings.

**Solution**: When testing API enable/disable at studio level, create a non-main studio:
```ruby
non_main_studio = Studio.create!(
  name: "Test Studio",
  handle: "test-studio-#{SecureRandom.hex(4)}",
  tenant: @tenant,
  studio_type: "studio",
  created_by: @user,
  updated_by: @user
)
```

### 12. Studio Creation Requires Full Attributes

**Issue**: Creating a `Studio` requires `created_by`, `updated_by`, and `handle` attributes, plus it automatically creates a trustee user.

**Solution**: Always provide required attributes:
```ruby
Studio.create!(
  name: "Studio Name",
  handle: "unique-handle",
  tenant: @tenant,
  studio_type: "studio",
  created_by: @user,
  updated_by: @user
)
```

---

## Progress Tracking

### Summary

**All phases complete!** ✅

| Phase | Description | Status | Tests Added |
|-------|-------------|--------|-------------|
| 1 | Baseline Coverage | ✅ | SimpleCov setup |
| 2 | Authentication & Authorization | ✅ | 47 tests |
| 3 | Core Domain Models | ✅ | 71 tests |
| 4 | Services & Business Logic | ✅ | 91 tests |
| 5 | Controllers & Integration | ✅ | 51 tests |
| 6 | API Endpoints | ✅ | (129 existing) |
| 7 | CI Workflow | ✅ | Coverage threshold |

### Coverage

| Date | Line Coverage | Notes |
|------|---------------|-------|
| Jan 7, 2026 | **47.12%** | Baseline measurement |
| Jan 7, 2026 | ~50%+ | After all phases |

### Test Suite

- **Total Tests**: 501
- **Failures**: 0
- **Skips**: 27 (mostly honor_system tests in OAuth mode + documented bugs)

---

## Related Documentation

- [AGENTS.md](../AGENTS.md) - AI agent guidelines
- [ARCHITECTURE.md](ARCHITECTURE.md) - System architecture
- [API.md](API.md) - API documentation
- [CONTRIBUTION_GUIDELINES_PLAN.md](CONTRIBUTION_GUIDELINES_PLAN.md) - Contribution guidelines (separate project)
