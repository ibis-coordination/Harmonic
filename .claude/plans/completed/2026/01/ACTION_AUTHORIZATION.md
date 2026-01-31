# Declarative Action Authorization

## Problem Statement

The `/actions` endpoint displays a global list of ALL actions in the system, including admin-only actions, to any authenticated user. While execution is properly authorized (non-admins get 403 when trying to execute admin actions), the **listing itself leaks information** about admin functionality.

This is a symptom of a deeper architectural issue: **authorization logic is scattered and duplicated**.

- Execution authorization: lives in controllers (before_actions, permission checks)
- Display/listing: uses static `ActionsHelper.routes_and_actions` with no authorization
- No single source of truth for "who can see/execute what"

Every new action requires the developer to remember to add authorization in multiple places. This pattern makes it easy for authorization gaps to slip through.

## Solution: Declarative Authorization in Action Definitions

Add authorization requirements directly to `ACTION_DEFINITIONS` in `ActionsHelper`. Both the action listing AND execution will consult this single source of truth.

### Example

Current:
```ruby
"suspend_user" => {
  description: "Suspend this user's account, preventing them from logging in",
  params_string: "(reason)",
},
```

Proposed:
```ruby
"suspend_user" => {
  description: "Suspend this user's account, preventing them from logging in",
  params_string: "(reason)",
  authorization: :app_admin,
},
```

### Authorization Types

Define a set of authorization symbols that map to permission checks.

**Admin Levels:**

These are independent flags - a user can have any combination of these roles. There is no inheritance between them.

| Symbol | Meaning | Check |
|--------|---------|-------|
| `:system_admin` | System-wide admin (primary tenant only) | `user.sys_admin?` |
| `:app_admin` | Application admin (can manage tenants) | `user.app_admin?` |
| `:tenant_admin` | Tenant administrator | `user.tenant_admin?` (via TenantUser or ApiToken) |
| `:superagent_admin` | Admin of the studio/superagent in context | `user.superagent_member&.is_admin?` |

**Role-based:**

| Symbol | Meaning | Check |
|--------|---------|-------|
| `:public` | Anyone, including unauthenticated users | `true` |
| `:authenticated` | Any authenticated user | `user.present?` |
| `:superagent_member` | Member of the studio in context | `studio.member?(user)` |
| `:resource_owner` | Owner of the resource | `resource.created_by == user` |
| `:self` | User acting on their own profile | `target_user == user` |
| `:representative` | User representing another user/subagent | `user.representing?(target)` |

For complex cases, allow a Proc:
```ruby
authorization: ->(user, context) { user.app_admin? || context[:resource]&.created_by == user }
```

For cases where multiple roles can access (OR logic), allow an Array:
```ruby
authorization: [:self, :representative]  # Either the user themselves OR someone representing them
```

### Default Behavior (Fail Closed)

If an action definition does not specify `authorization`, it should default to the **most restrictive** behavior:
- Not shown in listings
- Returns 403 on execution attempt

This ensures new actions are secure by default. Developers must explicitly opt-in to making actions visible.

## Implementation Plan

### Phase 1: Add Authorization Infrastructure

1. **Define authorization checker module** (`app/services/action_authorization.rb`):
   ```ruby
   module ActionAuthorization
     AUTHORIZATION_CHECKS = {
       # Public/authenticated
       public: ->(_user, _context) { true },
       authenticated: ->(user, _context) { user.present? },

       # Admin levels (independent, not hierarchical)
       system_admin: ->(user, _context) { user&.sys_admin? },
       app_admin: ->(user, _context) { user&.app_admin? },
       tenant_admin: ->(user, _context) { user&.tenant_admin? },
       superagent_admin: ->(user, context) {
         context[:studio]&.then { |s| user&.superagent_member_for(s)&.is_admin? } || false
       },

       # Role-based
       superagent_member: ->(user, context) { context[:studio]&.member?(user) || false },
       resource_owner: ->(user, context) { context[:resource]&.created_by == user },
       self: ->(user, context) { context[:target_user] == user },
       representative: ->(user, context) { user&.representing?(context[:target]) || false },
     }

     def self.authorized?(action_name, user, context = {})
       action = ActionsHelper::ACTION_DEFINITIONS[action_name]
       return false unless action  # Unknown action = denied

       auth = action[:authorization]
       return false if auth.nil?  # No auth specified = denied (fail closed)

       check_authorization(auth, user, context)
     end

     def self.check_authorization(auth, user, context)
       case auth
       when Symbol
         AUTHORIZATION_CHECKS[auth]&.call(user, context) || false
       when Proc
         auth.call(user, context)
       when Array
         # Array means ANY of these authorizations suffice (OR logic)
         auth.any? { |a| check_authorization(a, user, context) }
       else
         false
       end
     end
   end
   ```

2. **Add `authorization` key to all `ACTION_DEFINITIONS`** in `ActionsHelper`:
   - Audit each action and assign appropriate authorization
   - Admin actions get appropriate admin level
   - Studio actions get `:superagent_member` or `:authenticated`
   - User settings get `[:self, :representative]`
   - etc.

### Phase 2: Filter Action Listings

3. **Update `routes_and_actions` to accept user context**:
   ```ruby
   def self.routes_and_actions_for_user(user, context = {})
     @@routes_and_actions.map do |route_info|
       filtered_actions = route_info[:actions].select do |action|
         ActionAuthorization.authorized?(action[:name], user, context)
       end
       { route: route_info[:route], actions: filtered_actions }
     end.reject { |ri| ri[:actions].empty? }
   end
   ```

4. **Update `HomeController#actions_index`** to use filtered list:
   ```ruby
   def actions_index
     @page_title = 'Actions | Home'
     @routes_and_actions = ActionsHelper.routes_and_actions_for_user(@current_user)
     render 'actions'
   end
   ```

### Phase 3: Enforce on Execution (Defense in Depth)

5. **Add authorization check in action execution path**:

   The controllers already have their own authorization (before_actions, etc.), but we can add a defense-in-depth check in the shared action execution code path. This ensures that even if a controller forgets authorization, the action definition's authorization is enforced.

   In `ApplicationController` or wherever actions are dispatched:
   ```ruby
   def execute_action(action_name, params)
     unless ActionAuthorization.authorized?(action_name, @current_user, build_context)
       return render_forbidden("Not authorized to execute this action")
     end
     # ... proceed with action
   end
   ```

### Phase 4: Testing

6. **Add tests for authorization filtering**:
   - Test that non-admin users don't see admin actions in `/actions` listing
   - Test that each admin level sees only actions appropriate to their level
   - Test that execution is denied for unauthorized users
   - Test that execution is allowed for authorized users
   - Test representative access patterns

7. **Add audit test** to ensure all actions have authorization defined:
   ```ruby
   test "all actions have authorization defined" do
     ActionsHelper::ACTION_DEFINITIONS.each do |name, definition|
       assert definition.key?(:authorization),
         "Action '#{name}' must have :authorization defined"
     end
   end
   ```

## Migration Checklist

For each action in `ACTION_DEFINITIONS`:

- [ ] Identify who should be able to see/execute this action
- [ ] Add appropriate `:authorization` key
- [ ] Verify existing controller authorization matches
- [ ] Add/update tests

### Action Inventory

**System admin actions** (`:system_admin`):
- `retry_sidekiq_job`
- (Review SystemAdminController for other actions)

**App admin actions** (`:app_admin`):
- `create_tenant`
- `suspend_user`
- `unsuspend_user`

**Tenant admin actions** (`:tenant_admin`):
- `update_tenant_settings`

**Superagent/Studio admin actions** (`:superagent_admin`):
- `update_studio_settings`
- `add_subagent_to_studio`
- `remove_subagent_from_studio`
- `create_webhook` (studio), `update_webhook`, `delete_webhook`, `test_webhook`

**Studio member actions** (`:superagent_member`):
- `create_note`, `create_decision`, `create_commitment`
- `add_option`, `vote`, `add_comment`
- `join_commitment`, `confirm_read`
- `send_heartbeat`

**Resource owner actions** (`:resource_owner` or combined with superagent_member):
- `update_note`
- `update_decision_settings`
- `update_commitment_settings`
- `add_attachment`, `remove_attachment`

**User self-actions** (`[:self, :representative]`):
- `update_profile`
- `create_api_token`
- `create_subagent`
- `create_webhook` (user), `update_webhook`, `delete_webhook`, `test_webhook`

**Authenticated user actions** (`:authenticated`):
- `join_studio` (on join page, if invited)
- `mark_read`, `mark_all_read`, `dismiss` (notifications)
- `create_reminder`, `delete_reminder`

**Public actions** (`:public`):
- (Identify if any actions should be available without authentication)

## Risks and Mitigations

| Risk | Mitigation |
|------|------------|
| Breaking existing functionality | Extensive testing, gradual rollout |
| Performance impact on listings | Authorization checks are simple boolean logic, minimal impact |
| Forgetting to add authorization to new actions | Audit test fails if authorization missing; fail-closed default |
| Complex authorization logic becomes hard to read | Document patterns; prefer simple symbols over procs |
| Representative edge cases | Explicit testing of representative scenarios |

## Success Criteria

1. Non-admin users cannot see admin actions in `/actions` listing
2. Each admin level sees only actions they are authorized for
3. All actions have explicit authorization defined (enforced by test)
4. No change to existing authorized user experience
5. Representative users see appropriate actions for the users they represent
6. New actions require explicit authorization (fail-closed default)

## Future Considerations

- Could extend to generate OpenAPI/documentation that's permission-aware
- Could add per-action rate limiting using same infrastructure
- Could add action audit logging using same metadata
- Could generate permission matrices for documentation/review
