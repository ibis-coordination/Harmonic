# Subagent User Type Plan

## Overview

This plan renames "simulated" users to "subagent" users and makes the parent-child relationship visible throughout the application. The goal is to clarify that subagents are managed by their parent user, establishing clear social responsibility for subagent actions.

## Background

Currently there are three user types:
- **person**: Real users with OAuth login credentials and no parent
- **simulated**: Users with a parent user, can be impersonated by their parent
- **trustee**: Representative users for studios or other users

The term "simulated" is unclear—it doesn't communicate what these users are or who manages them. Renaming to "subagent" better describes the relationship: these are agents that act under the authority and responsibility of their parent user.

## Goals

1. Rename `simulated` to `subagent` throughout the codebase and database
2. Make the parent relationship visible in all contexts (UI, markdown, API)
3. Enable parents to add subagents to studios without requiring invite acceptance
4. Establish foundation for future studio-scoped permissions (out of scope)

## Non-Goals (Future Work)

- Studio-specific permission scoping for subagents
- Granular permission restrictions for subagents
- Notification system for subagent actions

---

## Part 0: Add Impersonation Integration Tests

Before making any code changes, we need comprehensive integration tests for the impersonation flow. Currently only model-level tests exist for `can_impersonate?`. We need integration tests to verify the full HTTP flow works correctly, so we can detect any regressions during the refactor.

### 0.1 Test File

Create: `test/integration/impersonation_test.rb`

### 0.2 Test Cases

**Starting Impersonation:**
- Parent can start impersonating their simulated user via POST
- Parent cannot impersonate another user's simulated user
- Parent cannot impersonate archived simulated user
- Parent cannot impersonate a regular person user
- Unauthenticated user cannot impersonate anyone

**Session Management:**
- After impersonation starts, `current_user` returns the simulated user
- Session stores `simulated_user_id` correctly
- Original person user is preserved in session

**Actions While Impersonating:**
- Creating a note while impersonating attributes it to the simulated user
- Creating a comment while impersonating attributes it to the simulated user
- Voting on a decision while impersonating records the simulated user's vote

**Stopping Impersonation:**
- Parent can stop impersonating via DELETE
- After stopping, `current_user` returns the original person user
- Session clears `simulated_user_id`

**Edge Cases:**
- If simulated user is archived during session, impersonation ends gracefully
- If simulated user's parent changes (shouldn't happen, but defensive), impersonation ends

### 0.3 Implementation Notes

These tests should use the existing test helpers:
- `create_tenant_studio_user` for creating users
- `sign_in_as(user, tenant:)` for authentication
- Direct session manipulation may be needed to set up impersonation state

---

## Part 1: Rename Simulated to Subagent

### 1.1 Database Migration

Create a migration to update the `user_type` column values:

```ruby
class RenameSimulatedToSubagent < ActiveRecord::Migration[7.0]
  def up
    User.where(user_type: 'simulated').update_all(user_type: 'subagent')
  end

  def down
    User.where(user_type: 'subagent').update_all(user_type: 'simulated')
  end
end
```

### 1.2 Model Changes

**File: `app/models/user.rb`**

- Update validation: `inclusion: { in: %w(person subagent trustee) }`
- Rename method: `simulated?` → `subagent?`
- Rename association: `simulated_users` → `subagents`
- Rename validation method: `simulated_user_must_have_parent` → `subagent_must_have_parent`
- Update all internal references

### 1.3 Controller Changes

**Files to update:**
- `app/controllers/simulated_users_controller.rb` → rename to `subagents_controller.rb`
- `app/controllers/users_controller.rb` - update impersonation references
- `app/controllers/application_controller.rb` - update `@current_simulated_user` → `@current_subagent_user`
- `app/controllers/api/v1/users_controller.rb` - update comments and logic

### 1.4 Route Changes

**File: `config/routes.rb`**

```ruby
# Before
resources :simulated_users, path: 'settings/simulated_users', only: [:new, :create]

# After
resources :subagents, path: 'settings/subagents', only: [:new, :create]
```

### 1.5 View Changes

**Files to update:**
- `app/views/simulated_users/` → rename to `app/views/subagents/`
- `app/views/users/settings.html.erb` - update section headers and labels
- `app/views/layouts/application.html.erb` - update impersonation banner text

### 1.6 Service Changes

**File: `app/services/api_helper.rb`**

- Rename method: `create_simulated_user` → `create_subagent`
- Update `user_type: 'simulated'` → `user_type: 'subagent'`

### 1.7 Test Changes

Update all test files that reference "simulated":
- `test/models/user_test.rb`
- `test/models/user_authorization_test.rb`
- `test/integration/api_users_test.rb`
- Any other tests discovered during implementation

---

## Part 2: Make Parent Relationship Visible

### 2.1 Display Formats

| Context | Format |
|---------|--------|
| Text/labels | "Alice (subagent of Bob)" |
| Avatar | Parent avatar overlaid in corner |
| Tooltip | "Managed by Bob" on hover |
| Markdown | `@alice (subagent of @bob)` |

### 2.2 User Model Helper Methods

Add methods to `User` model:

```ruby
def display_name_with_parent
  return display_name unless subagent?
  "#{display_name} (subagent of #{parent.display_name})"
end

def parent
  return nil unless parent_id
  User.unscoped.find_by(id: parent_id)
end
```

### 2.3 Avatar Component Changes

Create or update avatar partial/helper to:
- Accept a `show_parent: true` option
- Render parent avatar as small overlay in bottom-right corner
- Add tooltip with parent information on hover

### 2.4 Profile Page Updates

**File: `app/views/users/show.html.erb`**

- Display subagent badge/label if user is a subagent
- Show "Managed by [Parent Name]" with link to parent profile
- Style distinctively (consider subtle background or border)

### 2.5 Activity Feed Updates

When subagents take actions (comments, votes, commitments), display:
- Subagent name with parent attribution
- Visual indicator (badge/icon) that this is a subagent

**Files to update:**
- Note display partials
- Comment display partials
- Decision participant lists
- Commitment participant lists

### 2.6 Markdown Interface Updates

**File: `app/controllers/concerns/markdown_rendering.rb`** (or equivalent)

When rendering user references in markdown:
- Format subagents as `@handle (subagent of @parent_handle)`
- Include in participant lists, author attributions, etc.

### 2.7 Impersonation Banner Update

**File: `app/views/layouts/application.html.erb`**

Change from:
> "You are impersonating simulated user Alice"

To:
> "Acting as subagent Alice"

---

## Part 3: Add Subagents to Studios Without Invite

### 3.1 Authorization Logic

Parents can add their subagents to any studio where the parent has invite permission. This bypasses the invite acceptance step since the parent controls the subagent.

**File: `app/models/user.rb`**

```ruby
def can_add_subagent_to_studio?(subagent, studio)
  return false unless subagent.subagent? && subagent.parent_id == id
  can_invite_to_studio?(studio)
end
```

### 3.2 Parent Settings Page

**File: `app/views/users/settings.html.erb`**

For each subagent in the list:
- Show which studios they belong to
- Add "Add to Studio" dropdown/button
- List available studios (where parent has invite permission)

### 3.3 Studio Member Management

**File: `app/views/studios/members.html.erb`** (or equivalent)

When viewing studio members:
- Add option to "Add Subagent" for users who have subagents
- Show dropdown of parent's subagents not already in studio
- Direct add without invite flow

### 3.4 API Support

**File: `app/controllers/api/v1/`**

Add endpoint or extend existing to allow:
```
POST /api/v1/studios/:id/members
{
  "user_id": "<subagent_id>"
}
```

With authorization check that current user is the subagent's parent and has invite permission.

### 3.5 Service Layer

**File: `app/services/api_helper.rb`** (or new service)

```ruby
def add_subagent_to_studio(subagent:, studio:)
  raise AuthorizationError unless current_user.can_add_subagent_to_studio?(subagent, studio)
  studio.add_user!(subagent)
end
```

---

## Implementation Order

### Phase 0: Impersonation Tests (FIRST) ✓
- [x] Create `test/integration/impersonation_test.rb`
- [x] Add tests for starting impersonation
- [x] Add tests for session management
- [x] Add tests for actions while impersonating
- [x] Add tests for stopping impersonation
- [x] Add edge case tests
- [x] Verify all tests pass before proceeding

### Phase 1: Core Rename ✓
- [x] Database migration
- [x] Model changes (User)
- [x] Controller renames and updates
- [x] Route updates
- [x] View renames and text updates
- [x] Service updates
- [x] Update existing tests (rename simulated → subagent)

### Phase 2: Visibility
- [ ] Add helper methods for display with parent
- [ ] Update avatar component
- [ ] Update profile pages
- [ ] Update activity displays
- [ ] Update markdown rendering
- [ ] Update impersonation UI

### Phase 3: Studio Membership
- [ ] Add authorization method
- [ ] Update parent settings page
- [ ] Update studio member management
- [ ] Add API support
- [ ] Add tests

---

## Files to Modify

### Models
- `app/models/user.rb`

### Controllers
- `app/controllers/simulated_users_controller.rb` → `app/controllers/subagents_controller.rb`
- `app/controllers/users_controller.rb`
- `app/controllers/application_controller.rb`
- `app/controllers/api/v1/users_controller.rb`
- `app/controllers/studios_controller.rb` (or members controller)

### Views
- `app/views/simulated_users/` → `app/views/subagents/`
- `app/views/users/settings.html.erb`
- `app/views/users/show.html.erb`
- `app/views/layouts/application.html.erb`
- Various partials for notes, comments, participants

### Routes
- `config/routes.rb`

### Services
- `app/services/api_helper.rb`

### Tests
- `test/integration/impersonation_test.rb` (NEW - created first)
- `test/models/user_test.rb`
- `test/models/user_authorization_test.rb`
- `test/integration/api_users_test.rb`
- New tests for visibility and studio membership

---

## Open Questions

1. **Icon/badge design**: What icon represents a subagent? Robot? Chain link? Nested circles?
2. **Avatar overlay size**: How large should the parent avatar overlay be? 25%? 33%?
3. **Color/styling**: Should subagent profiles have a distinct background color or border?

---

## Success Criteria

- [x] Impersonation integration tests written and passing (before any refactor)
- [x] All references to "simulated" replaced with "subagent" in code and UI
- [x] Database migration runs successfully
- [ ] Parent relationship visible on subagent profiles
- [ ] Parent relationship visible in activity feeds
- [ ] Parent relationship visible in markdown output
- [ ] Avatars show parent overlay for subagents
- [ ] Parents can add subagents to studios from settings page
- [ ] Parents can add subagents to studios from studio member page
- [x] All existing tests pass after updates
- [ ] New tests cover visibility and studio membership features
