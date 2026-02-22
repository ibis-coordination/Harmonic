# Plan: Rename `collective_proxy` to `collective_identity` (Full Rename)

## Overview

Full rename of `collective_proxy` to `collective_identity` including all related methods, associations, and database columns for complete terminology consistency.

## Terminology Mapping

| Old | New |
|-----|-----|
| `"collective_proxy"` (user_type value) | `"collective_identity"` |
| `collective_proxy?` (User method) | `collective_identity?` |
| `proxy_user` (Collective association) | `identity_user` |
| `proxy_user_id` (DB column) | `identity_user_id` |
| `proxy_collective` (User method) | `identity_collective` |
| `create_proxy_user!` (Collective method) | `create_identity_user!` |
| `creator_is_not_collective_proxy` (validation) | `creator_is_not_collective_identity` |
| `proxy_users_not_member_of_main_collective` (validation) | `identity_users_not_member_of_main_collective` |

---

## Files to Modify (25 files total)

### Models (6 files)

| File | Changes |
|------|---------|
| `app/models/user.rb` | `collective_proxy?` → `collective_identity?`, `proxy_collective` → `identity_collective`, validation string, internal calls |
| `app/models/collective.rb` | `proxy_user` → `identity_user` association, `create_proxy_user!` → `create_identity_user!`, validation method rename |
| `app/models/collective_member.rb` | Validation method rename, `collective_identity?` calls, error messages |
| `app/models/trustee_grant.rb` | `collective_identity?` method calls |
| `app/models/representation_session.rb` | `collective.identity_user` call |
| `app/models/concerns/has_roles.rb` | `collective_identity?` call, error message |

### Controllers (1 file)

| File | Changes |
|------|---------|
| `app/controllers/application_controller.rb` | `collective_identity?` method call |

### Services (2 files)

| File | Changes |
|------|---------|
| `app/services/action_authorization.rb` | `collective_identity?` calls, comments |
| `app/services/automation_internal_action_service.rb` | `@collective.identity_user` |

### Views (2 files)

| File | Changes |
|------|---------|
| `app/views/representation_sessions/index.md.erb` | `identity_user` |
| `app/views/representation_sessions/_index_partial.html.erb` | `identity_user` |

### Tests (10 files)

| File | Changes |
|------|---------|
| `test/models/user_test.rb` | String literals, method calls, test names |
| `test/models/user_authorization_test.rb` | String literal |
| `test/models/collective_test.rb` | `identity_user`, string literals |
| `test/models/collective_member_test.rb` | `identity_user`, method calls |
| `test/models/trustee_grant_test.rb` | Method calls |
| `test/models/representation_session_test.rb` | `identity_user` |
| `test/services/action_authorization_test.rb` | String literal, method calls |
| `test/services/automation_internal_action_service_test.rb` | `identity_user` |
| `test/integration/trustee_grant_flow_test.rb` | Method calls |
| `test/integration/representation_session_test.rb` | `identity_user` |

### Documentation (4 files)

| File | Changes |
|------|---------|
| `docs/USER_TYPES.md` | Full rewrite of terminology |
| `docs/REPRESENTATION.md` | "proxy user" → "identity user" |
| `docs/ARCHITECTURE.md` | Entity references |
| `AGENTS.md` | User type table |

---

## Implementation Steps

### Phase 1: Database Migration

Create migration with column rename and data update:

```ruby
# db/migrate/YYYYMMDDHHMMSS_rename_collective_proxy_to_collective_identity.rb
class RenameCollectiveProxyToCollectiveIdentity < ActiveRecord::Migration[7.0]
  def up
    # Rename the column
    rename_column :collectives, :proxy_user_id, :identity_user_id

    # Update the user_type enum value
    execute "UPDATE users SET user_type = 'collective_identity' WHERE user_type = 'collective_proxy';"
  end

  def down
    rename_column :collectives, :identity_user_id, :proxy_user_id
    execute "UPDATE users SET user_type = 'collective_proxy' WHERE user_type = 'collective_identity';"
  end
end
```

### Phase 2: Model Changes

**1. User model** (`app/models/user.rb`):
- Update validation: `["human", "ai_agent", "collective_identity"]`
- Rename method `collective_proxy?` → `collective_identity?`
- Rename method `proxy_collective` → `identity_collective`
- Update string comparison to `"collective_identity"`
- Update ~10 internal `collective_proxy?` calls

**2. Collective model** (`app/models/collective.rb`):
- Rename association: `belongs_to :identity_user, class_name: "User"`
- Rename callback: `before_validation :create_identity_user!`
- Rename validation: `creator_is_not_collective_identity`
- Rename method: `create_identity_user!`
- Update `user_type: "collective_identity"` in user creation
- Update all internal `proxy_user` references

**3. CollectiveMember model** (`app/models/collective_member.rb`):
- Rename validation: `identity_users_not_member_of_main_collective`
- Update `collective_identity?` calls
- Update error message

**4. TrusteeGrant model** (`app/models/trustee_grant.rb`):
- Update `collective_identity?` method calls

**5. RepresentationSession model** (`app/models/representation_session.rb`):
- Update `collective.identity_user` call

**6. HasRoles concern** (`app/models/concerns/has_roles.rb`):
- Update `collective_identity?` call and error message

### Phase 3: Controller/Service Changes

**1. ApplicationController**:
- Update `collective_identity?` call

**2. ActionAuthorization**:
- Update `collective_identity?` calls
- Update comments

**3. AutomationInternalActionService**:
- Update `@collective.identity_user`

### Phase 4: View Changes

Update both view files to use `identity_user`:
- `app/views/representation_sessions/index.md.erb`
- `app/views/representation_sessions/_index_partial.html.erb`

### Phase 5: Test Updates

Update all 10 test files:
- Replace `"collective_proxy"` → `"collective_identity"`
- Replace `collective_proxy?` → `collective_identity?`
- Replace `proxy_user` → `identity_user`
- Replace `proxy_collective` → `identity_collective`
- Update test names referencing old terminology

### Phase 6: Documentation Updates

**docs/USER_TYPES.md**:
- Rename "Collective Proxy" section to "Collective Identity"
- Update table row
- Update all terminology and examples
- Update diagram

**docs/REPRESENTATION.md**:
- Replace "proxy user" with "identity user"
- Update code examples

**docs/ARCHITECTURE.md**:
- Update entity references

**AGENTS.md**:
- Update user type table

### Phase 7: Regenerate Sorbet Files

```bash
docker compose exec web bundle exec tapioca dsl
```

This will regenerate:
- `sorbet/rbi/dsl/collective.rbi`
- `sorbet/rbi/dsl/scene.rbi`

---

## Verification

1. **Run migration**: `docker compose exec web bundle exec rails db:migrate`
2. **Regenerate Sorbet**: `docker compose exec web bundle exec tapioca dsl`
3. **Run RuboCop**: `docker compose exec web bundle exec rubocop`
4. **Run type checker**: `docker compose exec web bundle exec srb tc`
5. **Run all tests**: `./scripts/run-tests.sh`
6. **Manual verification**:
   - Start app: `./scripts/start.sh`
   - Navigate to a studio's representation page
   - Verify collective identity users display correctly

---

## Risks and Mitigations

| Risk | Mitigation |
|------|------------|
| **Sorbet RBI files stale** | Regenerate after model changes before running type checker |
| **Foreign key constraints** | Rails handles FK update automatically with `rename_column` |
| **Cached User objects** | No action needed - cache will refresh on next load |

## Pre-Implementation Verification (Completed)

| Check | Result |
|-------|--------|
| Frontend JavaScript | ✅ No references |
| API serializers | ✅ No custom serializers exposing `user_type` |
| Background jobs | ✅ No hardcoded references |
| Scene model | ✅ Inherits cleanly from Collective |
| Test fixtures | ✅ None exist (uses factories) |
| Database indexes | ✅ No index on `proxy_user_id` |
| Webhooks | ✅ No references |
| Config files | ✅ No references |
| MCP/Markdown UI | ✅ No `user_type` exposure |
