# User Types: Test Coverage, Documentation, and Bug Fixes

## Overview

This plan addresses test coverage gaps, missing documentation, and potential bugs/inconsistencies for the three user types: **person**, **subagent**, and **trustee**.

## Current State

### User Types Summary
| Type | Has OAuth | Has Parent | Purpose |
|------|-----------|------------|---------|
| person | Yes | No | Regular human users |
| subagent | No | Yes (required) | AI agents managed by parent |
| trustee | No | No | Represents studios/delegation |

### Terminology: Impersonation vs Representation

These terms are related but distinct:

- **Impersonation** (`can_impersonate?`): The ability to act *as* another user. A parent can impersonate their subagent; a representative can impersonate a studio's trustee user.
- **Representation** (`can_represent?`): The ability to act *on behalf of* a studio. This is the permission check—if you can represent a studio, you can impersonate its trustee user.

Flow: `can_represent?(studio)` → grants ability to → `can_impersonate?(studio.trustee_user)` → creates → `RepresentationSession`

### Test Coverage Gaps
| Component | Current Tests | Status |
|-----------|--------------|--------|
| Person type | ~20 tests | Well tested |
| Subagent type | ~35 tests | Comprehensive |
| Trustee type | 2-3 tests | **Minimal** |
| RepresentationSession | 0 tests | **NOT TESTED** |
| TrusteePermission | 0 tests | **NOT TESTED** |
| StudioUser#can_represent? | 0 tests | **NOT TESTED** |

### Known Issues
1. TODO in [user.rb:119](../../app/models/user.rb#L119): `can_represent?` doesn't check trustee permissions for non-studio trustee users
2. No validation preventing trustee from having parent_id (may be intentional, needs verification)
3. Tests skipped in `api_users_test.rb` due to association bugs

---

## Implementation Plan

### Phase 1: Investigation (Before Writing Tests)
**Goal:** Understand existing bugs and verify assumptions before writing tests that might encode incorrect behavior

#### 1.1 Investigate TODO at user.rb:119
The `can_represent?` method has a TODO about checking trustee permissions for non-studio trustee users. Determine if this is a missing feature or intentionally deferred.

#### 1.2 Verify trustee + parent_id validation
Check if trustee users should be prevented from having parent_id. If so, add validation; if intentional, document why.

#### 1.3 Review skipped tests in api_users_test.rb
Investigate the `tenant.users` association bug and either fix it or document the workaround.

#### 1.4 Verify TrusteePermission is actually used
Before writing 15 tests for TrusteePermission, check if this model is used in production or if it's scaffolding for future functionality. If unused, deprioritize or skip those tests.

---

### Phase 2: Documentation
**Goal:** Document expected behavior before writing tests

#### 2.1 Create `docs/USER_TYPES.md`
- Overview of three user types and their purposes
- Validation rules (person: no parent_id; subagent: requires parent_id; trustee: no OAuth)
- Authorization rules (who can impersonate/represent whom)
- **Relationship diagram** showing:
  ```
  person ──creates──> subagent (via parent_id)
       │
       └──represents──> studio ──has──> trustee_user
                            │
                            └──> RepresentationSession
  ```

#### 2.2 Create `docs/REPRESENTATION.md`
- **State machine diagram** for RepresentationSession lifecycle:
  ```
  [created] ──begin!──> [active] ──end!──> [ended]
                │
                └──(24h)──> [expired]
  ```
- Activity recording during representation
- Representative role on StudioUser
- Session expiration (24 hours)
- What happens during edge cases (role revoked mid-session, etc.)

#### 2.3 Update existing docs
- Update AGENTS.md if it references outdated terminology

---

### Phase 3: Test Helpers
**Goal:** Create helper methods for consistent test setup

Add to [test/test_helper.rb](../../test/test_helper.rb):

```ruby
def create_subagent(parent:, name: "Test Subagent")
  User.create!(
    email: "#{SecureRandom.uuid}@not-a-real-email.com",
    name: name,
    user_type: "subagent",
    parent_id: parent.id
  )
end

def create_representation_session(
  tenant:,
  studio:,
  representative:,
  confirmed_understanding: true
)
  RepresentationSession.create!(
    tenant: tenant,
    studio: studio,
    representative_user: representative,
    trustee_user: studio.trustee_user,
    confirmed_understanding: confirmed_understanding,
    began_at: Time.current,
    activity_log: { 'activity' => [] }
  )
end

def create_trustee_permission(granting_user:, trusted_user:, relationship_phrase: nil)
  TrusteePermission.create!(
    granting_user: granting_user,
    trusted_user: trusted_user,
    relationship_phrase: relationship_phrase || "{trusted_user} acts for {granting_user}",
    permissions: {}
  )
end
```

---

### Phase 4: Unit Tests for Untested Models

#### 4.1 Create `test/models/representation_session_test.rb` (~20 tests)
- Validation tests (requires began_at, confirmed_understanding, all associations)
- Lifecycle: `begin!`, `end!`, `active?`, `ended?`, `expired?`
- Activity recording: `record_activity!`, `validate_semantic_event!`
- Human-readable log: `human_readable_activity_log`, vote deduplication
- Helper methods: `path`, `url`, `title`, `action_count`, `elapsed_time`

#### 4.2 Create `test/models/trustee_permission_test.rb` (~15 tests) — *if Phase 1.4 confirms it's used*
- Validation: trustee_user must be trustee type
- Validation: granting_user ≠ trusted_user ≠ trustee_user
- Validation: trusted_user cannot be trustee type
- Validation: if granting_user is trustee, must be studio_trustee
- Callback: `create_trustee_user!` auto-creates trustee
- Methods: `display_name`, `grant_permissions!`, `revoke_permissions!`

#### 4.3 Create `test/models/representation_session_association_test.rb` (~8 tests)
- Belongs to representation_session
- Polymorphic resource association
- Validates resource_type inclusion
- Callbacks set tenant/studio from session

#### 4.4 Add StudioUser tests to `test/models/studio_user_test.rb` (~6 tests)
- `can_represent?` returns true with representative role
- `can_represent?` returns true when studio.any_member_can_represent?
- `can_represent?` returns false when archived
- `can_represent?` returns false without role or setting

---

### Phase 5: Trustee User & Authorization Tests (Security Critical)

**Priority:** These tests cover the authorization boundary for representation—a high-risk security surface.

Add to [test/models/user_test.rb](../../test/models/user_test.rb) or [test/models/user_authorization_test.rb](../../test/models/user_authorization_test.rb) (~12 tests):

- `trustee?` returns true for trustee type
- `studio_trustee?` returns true when studio has trustee_user
- `trustee_studio` returns associated studio
- `display_name` returns studio name for studio trustee
- `handle` returns "studios/{handle}" for studio trustee
- **`can_impersonate?` returns true for studio trustee when can_represent?**
- **`can_impersonate?` returns false for studio trustee when cannot represent**
- **`can_impersonate?` returns false for archived studio trustee**
- Trustee cannot be member of main studio (StudioUser validation)
- Trustee cannot be creator of studio (Studio validation)

---

### Phase 6: Integration Tests

#### 6.1 Create `test/integration/representation_session_test.rb` (~18 tests)

**Happy path:**
- User with representative role can start representation
- `current_user` returns trustee_user during representation
- Creating note attributes to trustee_user
- Activity is recorded in session
- Representative can stop their session

**Authorization (security critical):**
- User without permission cannot start representation (returns 403)
- Cannot start if already in active session
- Must confirm understanding to start

**Edge cases:**
- Session expires after 24 hours (even if not ended)
- **Role revoked during active session** — next request should end session gracefully
- **Session expiration mid-action** — action should fail, session should end
- Clearing cookies ends representation gracefully
- Accessing pages outside studio scope during representation

---

## Critical Files

| File | Purpose |
|------|---------|
| [app/models/user.rb](../../app/models/user.rb) | User type definitions, validation |
| [app/models/representation_session.rb](../../app/models/representation_session.rb) | Core representation logic |
| [app/models/trustee_permission.rb](../../app/models/trustee_permission.rb) | Delegation relationships |
| [app/models/studio_user.rb](../../app/models/studio_user.rb) | can_represent? method |
| [test/test_helper.rb](../../test/test_helper.rb) | Test helpers to add |
| [test/models/user_test.rb](../../test/models/user_test.rb) | Existing user tests |
| [test/integration/impersonation_test.rb](../../test/integration/impersonation_test.rb) | Pattern for integration tests |

---

## Verification

After implementation:

1. **Run full test suite:**
   ```bash
   docker compose exec web bundle exec rails test
   ```

2. **Check coverage improvement:**
   ```bash
   docker compose exec web env COVERAGE=true bundle exec rails test
   ```
   Target: Increase from ~47% to ~55%+ line coverage

3. **Run type checker:**
   ```bash
   docker compose exec web bundle exec srb tc
   ```

4. **Manual verification via MCP:**
   - Start a representation session as a user with representative role
   - Create a note while representing
   - Stop the session and verify activity is logged
   - View the representation session record
   - **Test edge case:** Remove representative role while session is active, verify graceful handling

---

## Estimated Scope

- **Investigation:** 4 items to verify before proceeding
- **Documentation:** 2 new files with diagrams, minor updates to existing
- **Test helpers:** ~30 lines added to test_helper.rb
- **New tests:** ~65-80 tests across 4 new test files (depending on Phase 1.4 findings)
- **Bug fixes:** TBD based on investigation findings
