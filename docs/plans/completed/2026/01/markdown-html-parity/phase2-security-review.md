# Phase 2 Security Review: User Management Actions

This document provides a thorough security analysis of the Phase 2 markdown API actions before they are committed. Each action is evaluated for authentication, authorization, input validation, and potential attack vectors.

## Summary of Changes

Phase 2 adds the following markdown API endpoints:

1. **update_profile** - Update user name and handle
2. **create_api_token** - Create new API tokens with scopes
3. **create_subagent** - Create new subagent users with optional token generation
4. **add_subagent_to_studio** - Add a subagent to a studio
5. **remove_subagent_from_studio** - Remove a subagent from a studio

---

## 1. update_profile Action

**File:** `app/controllers/users_controller.rb:177-204`

### Authorization Check
```ruby
def execute_update_profile
  tu = current_tenant.tenant_users.find_by(handle: params[:handle])
  return render '404', status: 404 if tu.nil?
  return render plain: '403 Unauthorized', status: 403 unless tu.user == current_user
```

### Security Analysis

| Aspect | Status | Notes |
|--------|--------|-------|
| **Authentication** | ✅ GOOD | Requires `current_user` to match the target user |
| **Authorization** | ✅ GOOD | Only the user themselves can update their profile |
| **CSRF Protection** | ⚠️ CONCERN | CSRF is skipped for API requests (`skip_before_action :verify_authenticity_token, if: :api_token_present?`) |
| **Input Validation** | ⚠️ CONCERN | No validation on `name` or `new_handle` input length/format |
| **Mass Assignment** | ✅ GOOD | Only specific fields are updated, not using `update` with params |

### Potential Concerns

1. **Handle Uniqueness**: The code updates `handle` without checking if the new handle is already taken:
   ```ruby
   if params[:new_handle].present?
     current_user.handle = params[:new_handle]
     current_user.tenant_user.save!
   ```
   - **Risk**: Could potentially cause conflicts if handles aren't unique per tenant
   - **Mitigation**: Check if model validations exist for handle uniqueness

2. **Unscoped Update**: The code uses `TenantUser.unscoped.where(...)` to update all tenant_users:
   ```ruby
   TenantUser.unscoped.where(user: current_user).update_all(display_name: params[:name])
   ```
   - **Risk**: This updates the user's tenant_users across ALL tenants, not just the current one
   - **Question**: Is this intentional? Should handle changes propagate to all tenants?

3. **Input Length**: No validation on name/handle length which could cause:
   - Database overflow errors
   - UI rendering issues
   - Potential for abuse (very long names)

### Comparison with HTML Endpoint

The existing `update_profile` HTML endpoint (lines 101-121) has the same authorization pattern, so this is consistent.

### Recommendations

- [ ] Add input validation for name and handle (length, allowed characters)
- [ ] Confirm whether cross-tenant handle updates are intentional
- [ ] Consider rate limiting for profile updates

---

## 2. create_api_token Action

**File:** `app/controllers/api_tokens_controller.rb:61-73`

### Authorization Check
```ruby
# Via set_user before_action:
def set_user
  handle = params[:user_handle] || params[:handle]
  tu = current_tenant.tenant_users.find_by(handle: handle)
  tu ||= current_tenant.tenant_users.find_by(user_id: handle)
  return render status: 404, plain: '404 not user found' if tu.nil?
  return render status: 403, plain: '403 Unauthorized' unless tu.user == current_user || current_user.can_impersonate?(tu.user)
  @showing_user = tu.user
end
```

### Security Analysis

| Aspect | Status | Notes |
|--------|--------|-------|
| **Authentication** | ✅ GOOD | Requires current_user |
| **Authorization** | ✅ GOOD | Only user or their parent (impersonator) can create tokens |
| **Token Exposure** | ⚠️ HIGH CONCERN | Token is returned in markdown response |
| **Scope Control** | ⚠️ CONCERN | Only "read" or "write" options, no granular control |
| **Token Lifetime** | ✅ GOOD | Capped at 1 year maximum |

### Potential Concerns

1. **Token Exposure in Response**: The token is shown in `show.md.erb`:
   ```erb
   | Token | `<%= @token.token %>` |
   ```
   - **Risk**: Token is visible in response. If response is logged or cached, token could be exposed
   - **Mitigation**: This is intentional - tokens must be shown once to be usable. Same as HTML flow.

2. **API Token to Create API Token**: Can an API token be used to create another API token?
   - **Analysis**: The endpoint doesn't explicitly prevent this
   - **Risk**: An attacker with a compromised read-only token could escalate to write access
   - **Recommendation**: Check if scope validation prevents this (see `validate_scope` in ApplicationController)

3. **No Rate Limiting**: Users could create unlimited tokens
   - **Risk**: Token abuse, resource exhaustion
   - **Recommendation**: Consider adding per-user token limits

4. **Impersonation Path**: Parents can create tokens for subagents:
   ```ruby
   unless tu.user == current_user || current_user.can_impersonate?(tu.user)
   ```
   - **Assessment**: This is intentional and matches the HTML flow

### Comparison with HTML Endpoint

The `create` action (lines 14-22) has the same pattern via `set_user` before_action, so this is consistent.

### Recommendations

- [ ] Verify scope validation prevents token privilege escalation
- [ ] Consider adding rate limits or maximum token counts per user
- [ ] Document that tokens are visible in markdown responses (expected for MCP clients)

---

## 3. create_subagent Action

**File:** `app/controllers/subagents_controller.rb:43-58`

### Authorization Check
```ruby
def execute_create_subagent
  @subagent = api_helper.create_subagent
  if params[:generate_token] == true || params[:generate_token] == "true" || params[:generate_token] == "1"
    @token = api_helper.generate_token(@subagent)
  end
```

### Security Analysis

| Aspect | Status | Notes |
|--------|--------|-------|
| **Authentication** | ⚠️ CONCERN | Only implicit via api_helper.create_subagent |
| **Authorization** | ⚠️ CONCERN | No explicit check - relies on ApiHelper |
| **Token Generation** | ⚠️ HIGH CONCERN | Creates token alongside subagent |
| **Input Validation** | ⚠️ CONCERN | No validation on subagent name |

### Potential Concerns

1. **Missing Explicit Authorization**: Unlike other endpoints, there's no explicit authorization check:
   ```ruby
   def execute_create_subagent
     @subagent = api_helper.create_subagent  # Authorization inside api_helper?
   ```
   - **Risk**: If ApiHelper.create_subagent doesn't check authorization, anyone could create subagents
   - **Action Required**: Review ApiHelper.create_subagent implementation

2. **Automatic Token Generation**: The `generate_token` parameter creates a token:
   - **Risk**: Combined with concern #1, could allow attackers to create subagents with API access
   - **Question**: What scopes does `api_helper.generate_token` create?

3. **Token Exposure**: Same concern as create_api_token - token shown in response

4. **No User Type Check**: Doesn't verify that current_user is a "person" type (not subagent):
   - **Risk**: Could a subagent create another subagent?
   - **Assessment**: The view hides this for non-person users (`<% if @current_user.person? %>`) but the endpoint doesn't enforce it

### Comparison with HTML Endpoint

The `create` action (lines 11-18) uses `api_helper.create_subagent` with the same pattern - **also has no user type check**.

**This is a PRE-EXISTING vulnerability** affecting both HTML and markdown endpoints. However, since we're adding a new attack surface via the markdown API, we should fix it.

### ApiHelper Analysis

After reviewing `app/services/api_helper.rb`:

**create_subagent (lines 398-412):**
```ruby
def create_subagent
  user = User.create!(
    name: params[:name],
    parent_id: current_user.id,  # ✅ Sets parent correctly
    user_type: "subagent",
  )
  # ...
end
```

**FINDING**: No check that `current_user` is a "person" type. A subagent could potentially create nested subagents.

**generate_token (lines 415-422):**
```ruby
def generate_token(user)
  ApiToken.create!(
    scopes: ApiToken.read_scopes + ApiToken.write_scopes,  # Full access!
  )
end
```

**FINDING**: Creates tokens with FULL read + write scopes. This may be intentional for new subagents but should be documented.

### Recommendations

- [ ] **CRITICAL**: Add user type check in execute_create_subagent:
  ```ruby
  return render_action_error(...) unless current_user&.person?
  ```
- [ ] Verify only "person" users can create subagents (model-level validation)
- [ ] Consider whether generate_token should use configurable scopes
- [ ] Add input validation for subagent name

---

## 4. add_subagent_to_studio Action

**File:** `app/controllers/studios_controller.rb:294-352`

### Authorization Check
```ruby
def execute_add_subagent_to_studio
  return render_action_error(...) unless current_user

  subagent = User.find(params[:subagent_id])
  unless subagent.subagent? && subagent.parent_id == current_user.id
    return render_action_error({ error: 'You can only add your own subagents.' })
  end
  unless current_user.can_add_subagent_to_studio?(subagent, @current_studio)
    return render_action_error({ error: 'You do not have permission to add subagents to this studio.' })
  end
```

### Security Analysis

| Aspect | Status | Notes |
|--------|--------|-------|
| **Authentication** | ✅ GOOD | Explicit current_user check |
| **Authorization** | ✅ GOOD | Multi-layer: ownership + studio permission |
| **IDOR Protection** | ✅ GOOD | Verifies subagent belongs to current_user |
| **Error Handling** | ✅ GOOD | Proper error responses for all cases |

### Potential Concerns

1. **User.find vs scoped query**: Uses unscoped `User.find`:
   ```ruby
   subagent = User.find(params[:subagent_id])
   ```
   - **Analysis**: This is appropriate since users aren't scoped by tenant
   - **Risk**: Low - ownership is still verified

2. **Permission Leak in Action Description**: The describe action shows available subagents:
   ```ruby
   description: "ID of the subagent to add. Your available subagents: #{addable_subagents.map { |s| "#{s.id} (#{s.name})" }.join(', ')}"
   ```
   - **Assessment**: This exposes subagent IDs and names, but only to the parent user who already has access to this info

3. **Studio Permission Check**: Uses `can_add_subagent_to_studio?` which checks:
   ```ruby
   def can_add_subagent_to_studio?(subagent, studio)
     return false unless subagent.subagent? && subagent.parent_id == self.id
     su = studio_users.find_by(studio_id: studio.id)
     su&.can_invite? || false
   end
   ```
   - **Assessment**: Double-checks ownership and requires invite permission

### Comparison with HTML Endpoint

The existing `add_subagent_to_studio` in UsersController (lines 49-73) has similar authorization:
```ruby
return render status: 403, plain: "403 Unauthorized" unless subagent.subagent? && subagent.parent_id == current_user.id
return render status: 403, plain: "403 Unauthorized" unless current_user.can_add_subagent_to_studio?(subagent, studio)
```
The markdown API version is consistent.

### Recommendations

- [x] Authorization looks correct - no changes needed

---

## 5. remove_subagent_from_studio Action

**File:** `app/controllers/studios_controller.rb:354-410`

### Authorization Check
```ruby
def execute_remove_subagent_from_studio
  return render_action_error(...) unless current_user

  subagent = User.find(params[:subagent_id])
  unless subagent.subagent? && subagent.parent_id == current_user.id
    return render_action_error({ error: 'You can only remove your own subagents.' })
  end

  studio_user = StudioUser.find_by(studio: @current_studio, user: subagent)
  if studio_user.nil? || studio_user.archived?
    return render_action_error({ error: 'Subagent is not a member of this studio.' })
  end
```

### Security Analysis

| Aspect | Status | Notes |
|--------|--------|-------|
| **Authentication** | ✅ GOOD | Explicit current_user check |
| **Authorization** | ✅ GOOD | Only parent can remove their subagent |
| **IDOR Protection** | ✅ GOOD | Verifies subagent ownership |
| **State Check** | ✅ GOOD | Verifies subagent is actually in studio |

### Potential Concerns

1. **No Studio Permission Check**: Unlike add, remove doesn't check `can_invite?`:
   - **Question**: Should parents need invite permission to remove their own subagents?
   - **Assessment**: This seems intentional - you can always manage your own subagents

2. **Soft Delete via archive!**: Uses `studio_user.archive!` instead of destroy:
   - **Assessment**: This is consistent with the app's soft-delete pattern
   - **Note**: Subagent remains in system, just not active in studio

### Comparison with HTML Endpoint

The existing `remove_subagent_from_studio` in UsersController (lines 75-99) uses the same pattern:
```ruby
return render status: 403, plain: "403 Unauthorized" unless subagent.subagent? && subagent.parent_id == current_user.id
studio_user = StudioUser.find_by(studio: studio, user: subagent)
return render status: 404, plain: "404 Not Found" if studio_user.nil? || studio_user.archived?
studio_user.archive!
```
The markdown API version is consistent.

### Recommendations

- [x] Authorization looks correct - no changes needed

---

## Global Security Considerations

### 1. CSRF Protection

The app disables CSRF protection for API requests:
```ruby
skip_before_action :verify_authenticity_token, if: :api_token_present?
```

**Analysis**: This is standard for API authentication via bearer tokens. The API token itself serves as proof of authorization.

**However**: For browser-based markdown requests (Accept: text/markdown without API token), CSRF protection IS active. This is correct.

### 2. API Token Scope Validation

The `validate_scope` method in ApplicationController:
```ruby
def validate_scope
  return true if current_user && !current_token # Allow all actions for logged in users
  unless current_token.can?(request.method, current_resource_model)
    render json: { error: 'You do not have permission to perform that action' }, status: 403
  end
end
```

**Concern**: The `current_resource_model` is based on controller name:
```ruby
@current_resource_model = controller_name.classify.constantize
```

For the new actions:
- `users_controller` → `User` model
- `api_tokens_controller` → `ApiToken` model
- `subagents_controller` → `Subagent` model (if exists) or error
- `studios_controller` → `Studio` model

**Question**: Does `ApiToken.can?(method, model)` properly check scopes for these operations?

### 3. Rate Limiting

None of these endpoints have rate limiting. Potential abuse vectors:
- Creating unlimited API tokens
- Creating unlimited subagents
- Rapid profile updates

### 4. Audit Logging

These actions don't appear to create audit logs. For security-sensitive operations like token creation, audit trails may be desirable.

---

## Action Items Summary

### Critical (Review Before Merge)

1. **create_subagent**: Add explicit authorization check that:
   - Current user is logged in
   - Current user is a "person" type (not subagent)

2. **Review ApiHelper**: Verify `api_helper.create_subagent` and `api_helper.generate_token` have proper authorization

### High Priority (Should Fix)

3. **update_profile**: Add input validation for name and handle:
   - Maximum length
   - Allowed character set (for handles)
   - Uniqueness check before update

4. **Scope Validation**: Verify API tokens cannot be used to create more tokens with elevated privileges

### Medium Priority (Consider)

5. **Cross-tenant handle updates**: Confirm the unscoped update is intentional

6. **Rate limiting**: Consider adding limits for token/subagent creation

7. **Audit logging**: Consider logging security-sensitive actions

---

## Files Changed

| File | Type | Risk Level |
|------|------|------------|
| `app/controllers/users_controller.rb` | Modified | Medium |
| `app/controllers/api_tokens_controller.rb` | Modified | Medium |
| `app/controllers/subagents_controller.rb` | Modified | **High** |
| `app/controllers/studios_controller.rb` | Modified | Low |
| `config/routes.rb` | Modified | Low |
| `app/services/actions_helper.rb` | Modified | Low |
| `app/views/api_tokens/new.md.erb` | New | Low |
| `app/views/api_tokens/show.md.erb` | New | Low |
| `app/views/subagents/new.md.erb` | New | Low |
| `app/views/subagents/show.md.erb` | New | Low |
| `app/views/users/settings.md.erb` | Modified | Low |
| `app/views/studios/settings.md.erb` | Modified | Low |
| `test/integration/markdown_ui_test.rb` | Modified | N/A |

---

## Clarifications from User

1. **Subagents should NOT be able to create their own subagents** (may change in future with tenant settings, but out of scope now)
2. **Subagents should NOT be able to create new API tokens at all**
3. **Subagents should NOT be able to add/remove other subagents from studios** (actions should not be visible to subagents)
4. **Cross-tenant handle updates ARE intentional** - no fix needed

---

## Planned Fixes

Based on the security analysis and user clarifications, the following fixes will be implemented:

### Fix 1: Block subagents from creating subagents

**File:** `app/controllers/subagents_controller.rb`

Add user type check to both `create` and `execute_create_subagent`:

```ruby
def create
  return render status: 403, plain: '403 Unauthorized' unless current_user&.person?
  # ... existing code
end

def execute_create_subagent
  unless current_user&.person?
    return render_action_error({
      action_name: 'create_subagent',
      resource: @current_user,
      error: 'Only person accounts can create subagents.',
    })
  end
  # ... existing code
end
```

### Fix 2: Block subagents from creating API tokens

**File:** `app/controllers/api_tokens_controller.rb`

Add user type check to `create`, `execute_create_api_token`, and the `new` action:

```ruby
def new
  return render status: 403, plain: '403 Unauthorized' unless current_user&.person? || @showing_user != current_user
  # ... existing code
end

def create
  return render status: 403, plain: '403 Unauthorized' unless current_user&.person? || @showing_user != current_user
  # ... existing code
end

def execute_create_api_token
  unless current_user&.person? || @showing_user != current_user
    return render_action_error({
      action_name: 'create_api_token',
      resource: @showing_user,
      error: 'Subagents cannot create their own API tokens.',
    })
  end
  # ... existing code
end
```

**Note:** The condition `current_user&.person? || @showing_user != current_user` allows:
- Person users to create tokens for themselves or their subagents
- But prevents subagents from creating tokens for themselves (parent can still create tokens for subagents via impersonation)

### Fix 3: Hide subagent management actions from subagents in Studio Settings

**File:** `app/views/studios/settings.md.erb`

Update the conditionals to also check that the current user is a person:

```erb
<% if @current_tenant.api_enabled? && @current_user.person? && @addable_subagents.present? %>
* [`add_subagent_to_studio(subagent_id)`](...) - Add one of your subagents to this studio
<% end %>
<% if @current_tenant.api_enabled? && @current_user.person? && @studio_subagents.present? && @studio_subagents.any? { |s| s.parent_id == @current_user.id } %>
* [`remove_subagent_from_studio(subagent_id)`](...) - Remove a subagent from this studio
<% end %>
```

### Fix 4: Block subagents from executing subagent management actions

**File:** `app/controllers/studios_controller.rb`

Add user type check to `execute_add_subagent_to_studio` and `execute_remove_subagent_from_studio`:

```ruby
def execute_add_subagent_to_studio
  return render_action_error({ ... error: 'You must be logged in.' }) unless current_user
  return render_action_error({ ... error: 'Only person accounts can manage subagents.' }) unless current_user.person?
  # ... existing code
end

def execute_remove_subagent_from_studio
  return render_action_error({ ... error: 'You must be logged in.' }) unless current_user
  return render_action_error({ ... error: 'Only person accounts can manage subagents.' }) unless current_user.person?
  # ... existing code
end
```

### Summary of Changes

| File | Fix |
|------|-----|
| `app/controllers/subagents_controller.rb` | Add `person?` check to `create` and `execute_create_subagent` |
| `app/controllers/api_tokens_controller.rb` | Add check to prevent subagents from creating their own tokens |
| `app/views/studios/settings.md.erb` | Hide subagent actions from subagent users |
| `app/controllers/studios_controller.rb` | Add `person?` check to subagent management actions |

---

## Reviewer Notes

Please verify:
1. [x] ~~ApiHelper.create_subagent authorization logic~~ - Will add check in controller
2. [x] ~~ApiHelper.generate_token scope settings~~ - Acceptable (full scopes for new subagents)
3. [ ] ApiToken.can? method for proper scope enforcement (future consideration)
4. [x] ~~Whether cross-tenant handle updates are intentional~~ - Confirmed intentional
5. [ ] User model validations for handle uniqueness (future consideration)
