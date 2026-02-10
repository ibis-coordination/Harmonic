# Plan: Rename User Type `trustee` to `superagent_proxy`

## Goal

Rename the user type `trustee` to `superagent_proxy` to eliminate confusion between:
- **TrusteeGrant** - the grant relationship between users (keeping this name)
- **trustee user type** - synthetic users representing superagents as collective entities (renaming to `superagent_proxy`)

A "superagent proxy" is a synthetic user that allows a superagent to function as a user - enabling collective agency where a group can act as a single entity.

## Scope

### What CHANGES
1. User type value: `"trustee"` → `"superagent_proxy"` (database + code)
2. User model methods:
   - `trustee?` → `superagent_proxy?`
   - `superagent_trustee?` → remove (redundant with `superagent_proxy?`)
   - `trustee_superagent` → `proxy_superagent` (the superagent this user is a proxy for)
   - `@trustee_superagent` → `@proxy_superagent`
3. Superagent model:
   - `trustee_user` association → `proxy_user`
   - `trustee_user_id` column → `proxy_user_id`
   - `create_trustee!` → `create_proxy_user!`
4. Related validations, comments, and documentation

### What STAYS THE SAME
- `TrusteeGrant` model and all its references
- `trustee_user` / `trustee_user_id` in `TrusteeGrant` model (the person receiving the grant)
- `granting_user` / `trustee_user` terminology in TrusteeGrant context
- All grant-related language: "trustee of", "is_trusted_as?", etc.

## Implementation Phases

### Phase 1: Database Migration
Create migration to:
1. Rename column `superagents.trustee_user_id` → `superagents.proxy_user_id`
2. Update `users.user_type` values from `'trustee'` to `'superagent_proxy'`

```ruby
class RenameTrusteeToSuperagentProxy < ActiveRecord::Migration[7.0]
  def up
    # Rename column in superagents
    rename_column :superagents, :trustee_user_id, :proxy_user_id

    # Update user_type values
    execute "UPDATE users SET user_type = 'superagent_proxy' WHERE user_type = 'trustee'"
  end

  def down
    rename_column :superagents, :proxy_user_id, :trustee_user_id
    execute "UPDATE users SET user_type = 'trustee' WHERE user_type = 'superagent_proxy'"
  end
end
```

### Phase 2: User Model Updates

**File: `app/models/user.rb`**

1. Update validation:
   ```ruby
   validates :user_type, inclusion: { in: ["person", "subagent", "superagent_proxy"] }
   ```

2. Rename/simplify methods:
   - `trustee?` → `superagent_proxy?`
   - `superagent_trustee?` → remove (now redundant - a superagent_proxy is always a superagent proxy)
   - `trustee_superagent` → `proxy_superagent`

3. Update instance variable:
   - `@trustee_superagent` → `@proxy_superagent`

4. Update reload method to clear new instance variable name

5. Update all internal references to use new method names

### Phase 3: Superagent Model Updates

**File: `app/models/superagent.rb`**

1. Update association:
   ```ruby
   belongs_to :proxy_user, class_name: "User"
   ```

2. Rename method:
   ```ruby
   def create_proxy_user!
     return if proxy_user
     proxy = User.create!(
       name: name,
       email: SecureRandom.uuid + "@not-a-real-email.com",
       user_type: "superagent_proxy"
     )
     # ...
   end
   ```

3. Update before_validation callback:
   ```ruby
   before_validation :create_proxy_user!
   ```

### Phase 4: Update All References

Files to update (search for `trustee_user` and `trustee?` excluding TrusteeGrant context):

1. **Controllers:**
   - `app/controllers/users_controller.rb`
   - `app/controllers/representation_sessions_controller.rb`
   - `app/controllers/application_controller.rb`
   - `app/controllers/app_admin_controller.rb`
   - `app/controllers/tenant_admin_controller.rb`
   - `app/controllers/admin_controller.rb`

2. **Services:**
   - `app/services/api_helper.rb`
   - `app/services/data_deletion_manager.rb`
   - `app/services/actions_helper.rb`
   - `app/services/action_authorization.rb`

3. **Views:**
   - `app/views/representation_sessions/_index_partial.html.erb`
   - `app/views/representation_sessions/index.md.erb`

4. **Other Models:**
   - `app/models/representation_session.rb`
   - `app/models/superagent_member.rb`
   - `app/models/concerns/has_roles.rb`

### Phase 5: Update Tests

Files to update:
- `test/models/user_test.rb`
- `test/models/superagent_test.rb`
- `test/models/user_authorization_test.rb`
- `test/services/action_authorization_test.rb`
- `test/integration/trustee_grant_flow_test.rb` (may have references to user type)

### Phase 6: Update Documentation

1. `docs/USER_TYPES.md` - Update terminology
2. `AGENTS.md` - Update references
3. `README.md` - Update any references
4. `docs/REPRESENTATION.md` - Update terminology
5. Comments throughout codebase

### Phase 7: Update Sorbet RBI Files

Regenerate Sorbet RBI files after model changes:
- `sorbet/rbi/dsl/superagent.rbi`
- `sorbet/rbi/dsl/tenant.rbi`
- Other affected RBI files

## Terminology Mapping

| Old Term | New Term | Context |
|----------|----------|---------|
| `user_type: "trustee"` | `user_type: "superagent_proxy"` | User model |
| `trustee?` | `superagent_proxy?` | User method |
| `superagent_trustee?` | (removed - redundant) | User method |
| `trustee_superagent` | `proxy_superagent` | User method |
| `trustee_user` | `proxy_user` | Superagent association |
| `trustee_user_id` | `proxy_user_id` | Superagent column |
| `create_trustee!` | `create_proxy_user!` | Superagent method |

## Edge Cases to Handle

1. **TrusteeGrant overlap**: In User model's `is_trusted_as?` method, we still use `trustee?` for the user type check - this needs to become `superagent_proxy?`
2. **Comments referencing "trustee user"**: Update to "superagent proxy" or "proxy user"
3. **Existing database values**: Migration handles converting `'trustee'` → `'superagent_proxy'`

## Verification Steps

1. Run full test suite
2. Run RuboCop
3. Run Sorbet type checker
4. Search for remaining `trustee` references (should only be in TrusteeGrant context)
5. Manual testing of representation flow

## Files Summary

| Category | Files |
|----------|-------|
| Migration | 1 new migration |
| Models | `user.rb`, `superagent.rb`, `representation_session.rb`, `superagent_member.rb`, `concerns/has_roles.rb` |
| Controllers | 6 controller files |
| Services | 4 service files |
| Views | `representation_sessions/*.erb` |
| Tests | ~5-6 test files |
| Docs | `USER_TYPES.md`, `AGENTS.md`, `README.md`, `REPRESENTATION.md` |
| Sorbet | RBI regeneration |

## Notes

- This is a semantic rename for clarity - no behavioral changes
- The migration is reversible
- After this change, "trustee" only appears in `TrusteeGrant` context
