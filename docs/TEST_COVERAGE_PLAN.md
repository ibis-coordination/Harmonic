# Test Coverage Improvement Plan

This document outlines the plan to increase test coverage across the Harmonic codebase. The goal is to establish a robust test suite that serves as documentation, provides guardrails for AI agents, and ensures code quality.

## Table of Contents

1. [Phase 1: Establish Baseline Coverage](#phase-1-establish-baseline-coverage)
2. [Phase 2: Critical Features - Authentication & Authorization](#phase-2-critical-features---authentication--authorization)
3. [Phase 3: Core Domain Models](#phase-3-core-domain-models)
4. [Phase 4: Services & Business Logic](#phase-4-services--business-logic)
5. [Phase 5: Controllers & Integration Tests](#phase-5-controllers--integration-tests)
6. [Phase 6: API Endpoints](#phase-6-api-endpoints)
7. [Phase 7: CI Workflow Enhancements](#phase-7-ci-workflow-enhancements)
8. [Phase 8: Contribution Guidelines & PR Templates](#phase-8-contribution-guidelines--pr-templates)
9. [Testing Patterns & Guidelines](#testing-patterns--guidelines)
10. [Gotchas & Idiosyncrasies](#gotchas--idiosyncrasies)

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
| `ApiHelper` | `api_helper_test.rb` | Exists |
| `DataDeletionManager` | `data_deletion_manager_test.rb` | Exists |
| `CommitmentParticipantManager` | None | Missing |
| `DecisionParticipantManager` | None | Missing |
| `MarkdownRenderer` | None | Missing |
| `LinkParser` | None | Missing |

### Tests to Add

#### 4.1 Participant Managers
**File**: `test/services/decision_participant_manager_test.rb`

| Test Case | Priority |
|-----------|----------|
| Creates participant for new user | High |
| Finds existing participant | High |
| Handles concurrent requests | Medium |

**File**: `test/services/commitment_participant_manager_test.rb`

| Test Case | Priority |
|-----------|----------|
| Creates participant for new user | High |
| Finds existing participant | High |
| Updates commitment status | High |

#### 4.2 Content Processing
**File**: `test/services/markdown_renderer_test.rb`

| Test Case | Priority |
|-----------|----------|
| Renders basic markdown | Medium |
| Handles code blocks | Medium |
| Sanitizes HTML | High |

**File**: `test/services/link_parser_test.rb`

| Test Case | Priority |
|-----------|----------|
| Parses internal links | Medium |
| Parses external links | Medium |
| Creates bidirectional links | Medium |

---

## Phase 5: Controllers & Integration Tests

### Objective
Test controller actions for proper authorization, parameter handling, and response codes.

### Current State
Only `password_resets_controller_test.rb` exists for HTML controllers.

### Controllers to Test (Priority Order)

#### 5.1 High Priority
| Controller | Key Actions to Test |
|------------|---------------------|
| `SessionsController` | Login/logout flow |
| `UsersController` | Profile, settings |
| `StudiosController` | CRUD, membership |
| `NotesController` | CRUD, history |
| `DecisionsController` | CRUD, voting |
| `CommitmentsController` | CRUD, participation |

#### 5.2 Medium Priority
| Controller | Key Actions to Test |
|------------|---------------------|
| `CyclesController` | CRUD, date handling |
| `AdminController` | Admin-only access |
| `ApiTokensController` | Token management |
| `AttachmentsController` | File uploads |

---

## Phase 6: API Endpoints

### Objective
Ensure all API endpoints work correctly with proper authentication and authorization.

### Current State
Good coverage exists in `test/integration/`:
- `api_auth_test.rb` ✓
- `api_notes_test.rb` ✓
- `api_decisions_test.rb` ✓
- `api_commitments_test.rb` ✓
- `api_cycles_test.rb` ✓
- `api_studios_test.rb` ✓
- `api_users_test.rb` ✓
- `api_tokens_test.rb` ✓

### Areas to Expand
| Endpoint | Additional Tests Needed |
|----------|------------------------|
| Notes | Edge cases, error handling |
| Decisions | Voting mechanics, result calculation |
| Commitments | Critical mass logic |
| All | Rate limiting (if implemented) |
| All | Pagination |

---

## Phase 7: CI Workflow Enhancements

### Objective
Enhance the GitHub Actions CI workflow to enforce test coverage, report results, and prevent regressions.

### Current State
**File**: `.github/workflows/ruby-tests.yml`

The existing workflow:
- ✓ Runs on push/PR to `main`
- ✓ Sets up PostgreSQL and Redis services
- ✓ Installs Ruby 3.1.7 with bundler caching
- ✓ Runs `bundle exec rails test`
- ✗ No coverage reporting
- ✗ No coverage threshold enforcement
- ✗ No test result artifacts

### Tasks

#### 7.1 Add Coverage Reporting to CI

Update the workflow to generate and upload coverage reports:

```yaml
      - name: Run tests with coverage
        env:
          RAILS_ENV: test
          DB_HOST: localhost
          AUTH_MODE: oauth
          HOSTNAME: harmonic.localhost
          PRIMARY_SUBDOMAIN: app
          AUTH_SUBDOMAIN: auth
          REDIS_URL: redis://localhost:6379/0
          COVERAGE: true
        run: bundle exec rails test

      - name: Upload coverage report
        uses: actions/upload-artifact@v4
        with:
          name: coverage-report
          path: coverage/
          retention-days: 30
```

#### 7.2 Add Coverage Summary to PR Comments

Consider adding a coverage summary action:

```yaml
      - name: Code Coverage Summary
        uses: irongut/CodeCoverageSummary@v1.3.0
        with:
          filename: coverage/coverage.json
          badge: true
          format: markdown
          output: both

      - name: Add Coverage PR Comment
        uses: marocchino/sticky-pull-request-comment@v2
        if: github.event_name == 'pull_request'
        with:
          recreate: true
          path: code-coverage-results.md
```

#### 7.3 Enforce Minimum Coverage Threshold

Add a step to fail the build if coverage drops below threshold:

```yaml
      - name: Check coverage threshold
        run: |
          COVERAGE=$(cat coverage/.last_run.json | jq '.result.covered_percent')
          THRESHOLD=30
          if (( $(echo "$COVERAGE < $THRESHOLD" | bc -l) )); then
            echo "Coverage $COVERAGE% is below threshold $THRESHOLD%"
            exit 1
          fi
          echo "Coverage $COVERAGE% meets threshold $THRESHOLD%"
```

#### 7.4 Add Test Results Reporting

Add test result reporting for better PR feedback:

```yaml
      - name: Run tests with coverage
        env:
          # ... existing env vars ...
        run: |
          bundle exec rails test --verbose 2>&1 | tee test-results.txt

      - name: Upload test results
        uses: actions/upload-artifact@v4
        if: always()
        with:
          name: test-results
          path: test-results.txt
          retention-days: 7
```

#### 7.5 Add Branch Protection Rules

Configure GitHub branch protection (manual step in GitHub settings):

- [ ] Require status checks to pass before merging
- [ ] Require the "test" job to pass
- [ ] Require branches to be up to date before merging
- [ ] Consider requiring code review approval

#### 7.6 Add Scheduled Test Runs

Add a scheduled workflow to catch flaky tests:

```yaml
on:
  push:
    branches:
      - main
  pull_request:
    branches:
      - main
  schedule:
    # Run tests daily at 6 AM UTC
    - cron: '0 6 * * *'
```

#### 7.7 Add Coverage Badge to README

Once coverage reporting is set up, add a badge to `README.md`:

```markdown
![Coverage](https://img.shields.io/badge/coverage-XX%25-green)
```

Or use a dynamic badge service that reads from coverage artifacts.

### Complete Updated Workflow

Here's the full updated `.github/workflows/ruby-tests.yml`:

```yaml
name: Run Tests

on:
  push:
    branches:
      - main
  pull_request:
    branches:
      - main
  schedule:
    - cron: '0 6 * * *'

jobs:
  test:
    runs-on: ubuntu-latest

    services:
      db:
        image: postgres:13
        ports:
          - 5432:5432
        env:
          POSTGRES_USER: decisiveteam
          POSTGRES_PASSWORD: decisiveteam
          POSTGRES_DB: decisive_team_test
      redis:
        image: redis:6.2-alpine
        ports:
          - 6379:6379

    steps:
      - name: Checkout code
        uses: actions/checkout@v4

      - name: Set up Ruby
        uses: ruby/setup-ruby@v1
        with:
          ruby-version: 3.1.7
          bundler-cache: true

      - name: Install dependencies
        run: bundle install

      - name: Set up database
        env:
          RAILS_ENV: test
          DB_HOST: localhost
          AUTH_MODE: oauth
          HOSTNAME: harmonic.localhost
          PRIMARY_SUBDOMAIN: app
          AUTH_SUBDOMAIN: auth
          REDIS_URL: redis://localhost:6379/0
        run: |
          bin/rails db:create
          bin/rails db:schema:load

      - name: Run tests with coverage
        env:
          RAILS_ENV: test
          DB_HOST: localhost
          AUTH_MODE: oauth
          HOSTNAME: harmonic.localhost
          PRIMARY_SUBDOMAIN: app
          AUTH_SUBDOMAIN: auth
          REDIS_URL: redis://localhost:6379/0
          COVERAGE: true
        run: bundle exec rails test

      - name: Check coverage threshold
        run: |
          COVERAGE=$(cat coverage/.last_run.json | jq '.result.covered_percent')
          THRESHOLD=30
          echo "Coverage: $COVERAGE%"
          if (( $(echo "$COVERAGE < $THRESHOLD" | bc -l) )); then
            echo "::error::Coverage $COVERAGE% is below threshold $THRESHOLD%"
            exit 1
          fi

      - name: Upload coverage report
        uses: actions/upload-artifact@v4
        if: always()
        with:
          name: coverage-report
          path: coverage/
          retention-days: 30

      - name: Upload test results
        uses: actions/upload-artifact@v4
        if: always()
        with:
          name: test-results
          path: test-results.txt
          retention-days: 7
```

### CI Checklist

| Task | Priority | Status |
|------|----------|--------|
| Add SimpleCov with JSON output | High | [ ] |
| Update workflow to run coverage | High | [ ] |
| Upload coverage artifacts | High | [ ] |
| Add coverage threshold check | High | [ ] |
| Add PR comment with coverage | Medium | [ ] |
| Add scheduled test runs | Medium | [ ] |
| Configure branch protection | Medium | [ ] |
| Add coverage badge to README | Low | [ ] |

---

## Phase 8: Contribution Guidelines & PR Templates

### Objective
Establish clear contribution guidelines and PR requirements to ensure consistent quality, especially when AI agents contribute to the codebase.

### Current State
- No `CONTRIBUTING.md` file exists
- No PR template exists
- No issue templates exist

### Tasks

#### 8.1 Create CONTRIBUTING.md

**File**: `CONTRIBUTING.md` (project root)

```markdown
# Contributing to Harmonic

Thank you for your interest in contributing to Harmonic! This document provides guidelines and requirements for contributions.

## Before You Start

1. **Read the documentation**:
   - [AGENTS.md](AGENTS.md) - Guidelines for AI agents and developers
   - [PHILOSOPHY.md](PHILOSOPHY.md) - Project values and motivations
   - [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) - System architecture

2. **Understand the codebase**:
   - This is a Rails 7.0 application with PostgreSQL
   - Multi-tenancy via subdomains is a core pattern
   - See `docs/` for detailed documentation

## Development Setup

1. Clone the repository
2. Run `./scripts/setup.sh` to initialize the environment
3. Run `./scripts/start.sh` to start Docker containers
4. Run `./scripts/run-tests.sh` to verify everything works

## Making Changes

### Branch Naming

Use descriptive branch names:
- `feature/add-user-notifications`
- `fix/decision-voting-bug`
- `test/add-commitment-tests`
- `docs/update-api-documentation`

### Code Style

- Follow existing Rails conventions
- Run `bundle exec rubocop` before committing
- Keep controllers thin, models focused
- Use service objects for complex business logic

### Testing Requirements

**All PRs must:**

1. **Not decrease test coverage** - Coverage must stay at or above the current threshold
2. **Include tests for new features** - New functionality requires corresponding tests
3. **Include tests for bug fixes** - Bug fixes should include a regression test
4. **Pass all existing tests** - No breaking changes to existing tests

**Test guidelines:**

- Follow patterns in `docs/TEST_COVERAGE_PLAN.md`
- Use helper methods from `test/test_helper.rb`
- Be mindful of multi-tenancy in tests
- Clean up test data (handled by global teardown)

### Commit Messages

Write clear, descriptive commit messages:

```
[Type] Short description (50 chars or less)

Longer description if needed. Explain what and why,
not how (the code shows how).

Refs: #123 (if applicable)
```

Types: `feat`, `fix`, `test`, `docs`, `refactor`, `chore`

## Pull Request Process

1. **Create a draft PR early** for visibility on larger changes
2. **Fill out the PR template completely**
3. **Ensure CI passes** before requesting review
4. **Respond to feedback** promptly
5. **Squash commits** if requested

## For AI Agents

If you are an AI agent contributing to this codebase:

1. **Always read `AGENTS.md` first** - It contains critical context
2. **Run tests before and after changes** - Use `./scripts/run-tests.sh`
3. **Check for TODOs** - Run `./scripts/check-todo-index.sh`
4. **Don't introduce debug code** - Run `./scripts/check-debug-code.sh`
5. **Follow existing patterns** - Look at similar code before writing new code
6. **Ask for clarification** if requirements are unclear

## Questions?

Open an issue for questions about contributing.
```

#### 8.2 Create PR Template

**File**: `.github/PULL_REQUEST_TEMPLATE.md`

```markdown
## Description

<!-- Briefly describe what this PR does -->

## Type of Change

<!-- Check all that apply -->

- [ ] 🐛 Bug fix (non-breaking change that fixes an issue)
- [ ] ✨ New feature (non-breaking change that adds functionality)
- [ ] 💥 Breaking change (fix or feature that would cause existing functionality to change)
- [ ] 📝 Documentation update
- [ ] 🧪 Test update (no production code changes)
- [ ] 🔧 Refactor (no functional changes)
- [ ] 🔒 Security fix

## Related Issues

<!-- Link any related issues: Fixes #123, Relates to #456 -->

## Changes Made

<!-- List the specific changes made in this PR -->

-
-
-

## Testing

### Tests Added/Updated

<!-- Describe what tests were added or modified -->

- [ ] Added unit tests for new functionality
- [ ] Added integration tests for new endpoints
- [ ] Updated existing tests for changed behavior
- [ ] No new tests needed (explain why)

### Manual Testing

<!-- Describe any manual testing performed -->

## Pre-Submission Checklist

### Required

- [ ] I have read [CONTRIBUTING.md](../CONTRIBUTING.md)
- [ ] I have read [AGENTS.md](../AGENTS.md) (for context)
- [ ] My code follows the existing code style
- [ ] I have run `./scripts/run-tests.sh` and all tests pass
- [ ] I have run `./scripts/check-debug-code.sh` (no debug code)
- [ ] My changes do not decrease test coverage
- [ ] I have updated documentation if needed

### For New Features

- [ ] I have added tests that prove my fix/feature works
- [ ] I have considered multi-tenancy implications
- [ ] I have updated API documentation if applicable

### For Bug Fixes

- [ ] I have added a test that reproduces the bug
- [ ] The test fails without my fix and passes with it

## Screenshots (if applicable)

<!-- Add screenshots for UI changes -->

## Additional Notes

<!-- Any additional context or notes for reviewers -->

---

## Reviewer Checklist

<!-- For reviewers to complete -->

- [ ] Code follows project conventions
- [ ] Tests are adequate and pass
- [ ] No security concerns
- [ ] Documentation is updated
- [ ] CI is green
```

#### 8.3 Create Issue Templates

**File**: `.github/ISSUE_TEMPLATE/bug_report.md`

```markdown
---
name: Bug Report
about: Report a bug to help us improve
title: '[BUG] '
labels: bug
assignees: ''
---

## Bug Description

<!-- A clear description of the bug -->

## Steps to Reproduce

1.
2.
3.

## Expected Behavior

<!-- What should happen -->

## Actual Behavior

<!-- What actually happens -->

## Environment

- Browser (if applicable):
- Tenant/Studio (if applicable):
- User type:

## Screenshots

<!-- If applicable -->

## Additional Context

<!-- Any other relevant information -->
```

**File**: `.github/ISSUE_TEMPLATE/feature_request.md`

```markdown
---
name: Feature Request
about: Suggest an idea for Harmonic
title: '[FEATURE] '
labels: enhancement
assignees: ''
---

## Problem Statement

<!-- What problem does this feature solve? -->

## Proposed Solution

<!-- Describe the solution you'd like -->

## Alternatives Considered

<!-- Any alternative solutions you've considered -->

## Additional Context

<!-- Any other context, mockups, or examples -->
```

#### 8.4 Create AI Agent Contribution Template

**File**: `.github/ISSUE_TEMPLATE/ai_agent_task.md`

```markdown
---
name: AI Agent Task
about: Task specification for AI agents
title: '[AI TASK] '
labels: ai-task
assignees: ''
---

## Task Description

<!-- Clear description of what needs to be done -->

## Context

<!-- Relevant background information -->

### Related Files

<!-- List files the agent should examine -->

-
-

### Related Documentation

- [ ] Read [AGENTS.md](../AGENTS.md)
- [ ] Read [docs/ARCHITECTURE.md](../docs/ARCHITECTURE.md)
- [ ] Read [docs/TEST_COVERAGE_PLAN.md](../docs/TEST_COVERAGE_PLAN.md)

## Requirements

<!-- Specific requirements for completion -->

- [ ]
- [ ]
- [ ]

## Testing Requirements

<!-- What tests should be added/verified -->

- [ ]
- [ ]

## Acceptance Criteria

<!-- How do we know this task is complete? -->

- [ ] All tests pass
- [ ] Coverage does not decrease
- [ ] No debug code introduced
- [ ] Documentation updated (if needed)

## Out of Scope

<!-- What should NOT be changed -->

-
```

### Contribution Guidelines Checklist

| Task | Priority | Status |
|------|----------|--------|
| Create CONTRIBUTING.md | High | [ ] |
| Create PR template | High | [ ] |
| Create bug report template | Medium | [ ] |
| Create feature request template | Medium | [ ] |
| Create AI agent task template | Medium | [ ] |
| Add contribution section to README | Low | [ ] |
| Set up CODEOWNERS file | Low | [ ] |

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

### Coverage Milestones

| Date | Line Coverage | Branch Coverage | Notes |
|------|---------------|-----------------|-------|
| Jan 7, 2026 | **47.12%** | **29.17%** | Baseline measurement |
| Phase 2 | Target: 50% | Target: 35% | Auth complete |
| Phase 3 | Target: 55% | Target: 40% | Core models |
| Phase 4 | Target: 60% | Target: 45% | Services |
| Phase 5 | Target: 75% | - | - | - | Controllers |
| Phase 6 | Target: 80% | - | - | - | API complete |

### Test File Index

| File | Purpose | Last Updated |
|------|---------|--------------|
| `test/test_helper.rb` | Global setup, fixtures, helpers | - |
| `test/models/user_test.rb` | User model tests | - |
| `test/models/note_test.rb` | Note model tests | - |
| `test/integration/api_auth_test.rb` | API authentication | - |
| ... | ... | ... |

---

## Next Steps

1. [ ] Install SimpleCov and run baseline coverage report
2. [ ] Complete Phase 2 authentication tests
3. [ ] Add model tests for high-priority models
4. [ ] Document patterns as they emerge
5. [ ] Update this document with progress

---

## Related Documentation

- [AGENTS.md](../AGENTS.md) - AI agent guidelines
- [ARCHITECTURE.md](ARCHITECTURE.md) - System architecture
- [API.md](API.md) - API documentation
