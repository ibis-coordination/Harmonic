# Admin Role Separation Plan

## Overview

This plan separates the current monolithic `/admin` routes into three distinct admin types with clear authorization boundaries. Currently, all admin types share the same routes with conditional view logic, which is error-prone and unmaintainable.

## Migration Strategy

**Safe migration approach**:
1. **Create fresh**: Build all new controllers, views, and routes from scratch
2. **Leave existing**: Current `AdminController` and `/admin/*` routes remain fully functional (deprecated)
3. **Use temporary route**: New tenant admin uses `/tenant-admin` initially (not `/admin`)
4. **Verify**: Test all new functionality works correctly
5. **Swap later**: After verification, change `/tenant-admin` → `/admin` and remove old `AdminController`

This approach ensures zero disruption to existing functionality during development.

---

## Admin Types

### 1. System Admin (`/system-admin`)

**Purpose**: System-level operations for infrastructure and monitoring.

**Access**: Only accessible from the **primary tenant** (`PRIMARY_SUBDOMAIN`).

**Features**:
- Sidekiq queue management (view queues, jobs, retry failed jobs)
- System monitoring metrics (future scope)
- Health checks (future scope)

**Who can access**: Users with `system_admin` role on their User record (not TenantUser).

### 2. App Admin (`/app-admin`)

**Purpose**: Application-level management of all tenants and users.

**Access**: Only accessible from the **primary tenant** (`PRIMARY_SUBDOMAIN`).

**Features**:
- Tenant management (create, list, view, suspend/unsuspend)
- User management across ALL tenants (unscoped queries)
- User suspension/unsuspension
- Cross-tenant user viewing (show which tenants a user belongs to)
- Security audit dashboard

**Who can access**: Users with `app_admin` role on their User record (not TenantUser).

### 3. Tenant Admin (`/tenant-admin` → later `/admin`)

**Purpose**: Tenant-level administration for a single tenant.

**Access**: Accessible from **any tenant** by that tenant's admins.

**Features**:
- Tenant settings (name, timezone, require_login, feature flags)
- User list for THIS tenant only (scoped queries)
- View user details for users in THIS tenant only
- Studio/scene management for this tenant
- Admin user list for this tenant

**What Tenant Admin CANNOT do**:
- Suspend or unsuspend users (app-level action)
- View users from other tenants
- Access Sidekiq or system monitoring
- Create or manage other tenants

**Who can access**: Users with `admin` role on their TenantUser record for the current tenant.

---

## Current State Analysis

### Routes (all under `/admin` - will be deprecated)

| Route | Current Level | Target Route | Target Level |
|-------|---------------|--------------|--------------|
| `/admin` | Mixed | `/tenant-admin` | Tenant |
| `/admin/settings` | Tenant | `/tenant-admin/settings` | Tenant |
| `/admin/users` | Mixed | `/tenant-admin/users` (scoped) | Tenant |
| `/admin/users/:handle` | Mixed | `/tenant-admin/users/:handle` | Tenant (view only) |
| `/admin/users/:handle/actions/suspend_user` | App | `/app-admin/users/:id/actions/suspend_user` | App |
| `/admin/users/:handle/actions/unsuspend_user` | App | `/app-admin/users/:id/actions/unsuspend_user` | App |
| `/admin/tenants` | System/App | `/app-admin/tenants` | App |
| `/admin/tenants/new` | System/App | `/app-admin/tenants/new` | App |
| `/admin/tenants/:subdomain` | System/App | `/app-admin/tenants/:subdomain` | App |
| `/admin/sidekiq` | System | `/system-admin/sidekiq` | System |
| `/admin/sidekiq/queues/:name` | System | `/system-admin/sidekiq/queues/:name` | System |
| `/admin/sidekiq/jobs/:jid` | System | `/system-admin/sidekiq/jobs/:jid` | System |
| `/admin/security` | System/App | `/app-admin/security` | App |

### Current Authorization Checks (in old AdminController)

1. `ensure_admin_user` - Checks `@current_tenant.is_admin?(@current_user)` (TenantUser role)
2. `is_main_tenant?` - Checks `@current_tenant.subdomain == ENV['PRIMARY_SUBDOMAIN']`
3. `can_perform_admin_actions?` - Composite check for view logic

### Problems with Current Approach

1. **Mixed authorization**: Same controller handles tenant-level and system-level actions
2. **Conditional view logic**: Templates check `is_main_tenant?` to show/hide features
3. **Unclear boundaries**: Easy to accidentally expose system features to tenant admins
4. **User scoping confusion**: Users page shows tenant users but suspension is global
5. **No clear role separation**: `app_admin` role exists on User model but isn't used for web UI

---

## Target Architecture

### New Controller Structure

```
app/controllers/
├── admin_controller.rb              # OLD - deprecated, keep untouched
├── system_admin_controller.rb       # NEW - System Admin
├── app_admin_controller.rb          # NEW - App Admin
└── tenant_admin_controller.rb       # NEW - Tenant Admin (later replaces admin_controller.rb)
```

### New Routes Structure

```ruby
# config/routes.rb

# ============================================================
# NEW ROUTES (fresh implementation)
# ============================================================

# System Admin (primary tenant only, system_admin role on User)
scope '/system-admin' do
  get '/', to: 'system_admin#dashboard', as: :system_admin_dashboard
  get '/sidekiq', to: 'system_admin#sidekiq'
  get '/sidekiq/queues/:name', to: 'system_admin#sidekiq_show_queue'
  get '/sidekiq/jobs/:jid', to: 'system_admin#sidekiq_show_job'
  post '/sidekiq/jobs/:jid/retry', to: 'system_admin#sidekiq_retry_job'
  get '/sidekiq/jobs/:jid/actions', to: 'system_admin#sidekiq_job_actions_index'
  get '/sidekiq/jobs/:jid/actions/retry_sidekiq_job', to: 'system_admin#describe_retry_sidekiq_job'
  post '/sidekiq/jobs/:jid/actions/retry_sidekiq_job', to: 'system_admin#execute_retry_sidekiq_job'
end

# App Admin (primary tenant only, app_admin role on User)
scope '/app-admin' do
  get '/', to: 'app_admin#dashboard', as: :app_admin_dashboard

  # Tenant management
  get '/tenants', to: 'app_admin#tenants'
  get '/tenants/new', to: 'app_admin#new_tenant'
  post '/tenants', to: 'app_admin#create_tenant'
  get '/tenants/new/actions', to: 'app_admin#actions_index_new_tenant'
  get '/tenants/new/actions/create_tenant', to: 'app_admin#describe_create_tenant'
  post '/tenants/new/actions/create_tenant', to: 'app_admin#execute_create_tenant'
  get '/tenants/:subdomain/complete', to: 'app_admin#complete_tenant_creation'
  get '/tenants/:subdomain', to: 'app_admin#show_tenant'
  # Future: suspend/unsuspend tenant actions

  # User management (unscoped - all users across all tenants)
  # Note: Uses user ID, not handle (handles are tenant-specific)
  get '/users', to: 'app_admin#users'
  get '/users/:id', to: 'app_admin#show_user'
  get '/users/:id/actions', to: 'app_admin#user_actions_index'
  get '/users/:id/actions/suspend_user', to: 'app_admin#describe_suspend_user'
  post '/users/:id/actions/suspend_user', to: 'app_admin#execute_suspend_user'
  get '/users/:id/actions/unsuspend_user', to: 'app_admin#describe_unsuspend_user'
  post '/users/:id/actions/unsuspend_user', to: 'app_admin#execute_unsuspend_user'

  # Security audit
  get '/security', to: 'app_admin#security_dashboard'
  get '/security/events/:line_number', to: 'app_admin#security_event'
end

# Tenant Admin (any tenant, admin role on TenantUser)
# Uses /tenant-admin temporarily; will become /admin after verification
scope '/tenant-admin' do
  get '/', to: 'tenant_admin#dashboard', as: :tenant_admin_dashboard
  get '/actions', to: 'tenant_admin#actions_index'

  # Tenant settings (for current tenant only)
  get '/settings', to: 'tenant_admin#settings'
  post '/settings', to: 'tenant_admin#update_settings'
  get '/settings/actions', to: 'tenant_admin#actions_index_settings'
  get '/settings/actions/update_tenant_settings', to: 'tenant_admin#describe_update_settings'
  post '/settings/actions/update_tenant_settings', to: 'tenant_admin#execute_update_settings'

  # Users (scoped to current tenant only, NO suspension actions)
  get '/users', to: 'tenant_admin#users'
  get '/users/:handle', to: 'tenant_admin#show_user'
  # Note: No suspend/unsuspend actions - that's app-level
end

# ============================================================
# OLD ROUTES (deprecated, keep untouched until removal)
# ============================================================
scope '/admin' do
  # ... existing routes remain unchanged ...
end
```

### New Authorization Logic

#### User Model Additions

```ruby
# app/models/user.rb

# These roles are stored on the User record itself (not TenantUser)
# and grant access to primary-tenant-only admin features

sig { returns(T::Boolean) }
def system_admin?
  settings.dig('roles', 'system_admin') == true
end

sig { returns(T::Boolean) }
def app_admin?
  # This already exists but may need adjustment
  settings.dig('roles', 'app_admin') == true
end
```

#### System Admin Controller

```ruby
# app/controllers/system_admin_controller.rb

class SystemAdminController < ApplicationController
  before_action :ensure_primary_tenant
  before_action :ensure_system_admin
  before_action :set_sidebar_mode

  private

  def ensure_primary_tenant
    unless @current_tenant&.subdomain == ENV['PRIMARY_SUBDOMAIN']
      render_not_found
    end
  end

  def ensure_system_admin
    unless @current_user&.system_admin?
      @sidebar_mode = 'none'
      render status: :forbidden, template: 'system_admin/403_not_system_admin'
    end
  end

  def set_sidebar_mode
    @sidebar_mode = 'system_admin'
  end
end
```

#### App Admin Controller

```ruby
# app/controllers/app_admin_controller.rb

class AppAdminController < ApplicationController
  before_action :ensure_primary_tenant
  before_action :ensure_app_admin
  before_action :set_sidebar_mode

  private

  def ensure_primary_tenant
    unless @current_tenant&.subdomain == ENV['PRIMARY_SUBDOMAIN']
      render_not_found
    end
  end

  def ensure_app_admin
    unless @current_user&.app_admin?
      @sidebar_mode = 'none'
      render status: :forbidden, template: 'app_admin/403_not_app_admin'
    end
  end

  def set_sidebar_mode
    @sidebar_mode = 'app_admin'
  end
end
```

#### Tenant Admin Controller

```ruby
# app/controllers/tenant_admin_controller.rb

class TenantAdminController < ApplicationController
  before_action :ensure_tenant_admin
  before_action :set_sidebar_mode

  private

  def ensure_tenant_admin
    unless @current_tenant&.is_admin?(@current_user)
      @sidebar_mode = 'none'
      render status: :forbidden, template: 'tenant_admin/403_not_tenant_admin'
    end
  end

  def set_sidebar_mode
    @sidebar_mode = 'tenant_admin'
  end
end
```

---

## Implementation Phases

### Phase 1: Create System Admin Controller and Routes

**Goal**: Implement `/system-admin` routes with Sidekiq management.

**New files**:
- `app/controllers/system_admin_controller.rb`
- `app/views/system_admin/dashboard.html.erb`
- `app/views/system_admin/dashboard.md.erb`
- `app/views/system_admin/sidekiq.html.erb`
- `app/views/system_admin/sidekiq.md.erb`
- `app/views/system_admin/sidekiq_show_queue.html.erb`
- `app/views/system_admin/sidekiq_show_queue.md.erb`
- `app/views/system_admin/sidekiq_show_job.html.erb`
- `app/views/system_admin/sidekiq_show_job.md.erb`
- `app/views/system_admin/403_not_system_admin.html.erb`
- `app/views/pulse/_sidebar_system_admin.html.erb`
- `test/controllers/system_admin_controller_test.rb`

**Modified files**:
- `config/routes.rb` (add system-admin routes)
- `app/models/user.rb` (add `system_admin?` method if not present)
- `app/views/layouts/application.html.erb` (or sidebar partial - render correct sidebar)

### Phase 2: Create App Admin Controller and Routes

**Goal**: Implement `/app-admin` routes with tenant and user management.

**New files**:
- `app/controllers/app_admin_controller.rb`
- `app/views/app_admin/dashboard.html.erb`
- `app/views/app_admin/dashboard.md.erb`
- `app/views/app_admin/tenants.html.erb`
- `app/views/app_admin/tenants.md.erb`
- `app/views/app_admin/new_tenant.html.erb`
- `app/views/app_admin/new_tenant.md.erb`
- `app/views/app_admin/show_tenant.html.erb`
- `app/views/app_admin/show_tenant.md.erb`
- `app/views/app_admin/complete_tenant_creation.html.erb`
- `app/views/app_admin/complete_tenant_creation.md.erb`
- `app/views/app_admin/users.html.erb`
- `app/views/app_admin/users.md.erb`
- `app/views/app_admin/show_user.html.erb`
- `app/views/app_admin/show_user.md.erb`
- `app/views/app_admin/security_dashboard.html.erb`
- `app/views/app_admin/security_dashboard.md.erb`
- `app/views/app_admin/security_event.html.erb`
- `app/views/app_admin/security_event.md.erb`
- `app/views/app_admin/403_not_app_admin.html.erb`
- `app/views/pulse/_sidebar_app_admin.html.erb`
- `test/controllers/app_admin_controller_test.rb`

**Modified files**:
- `config/routes.rb` (add app-admin routes)

**Key differences from old AdminController**:
- Users are identified by **User ID** (not tenant-specific handle)
- User queries are **unscoped** (show all users across all tenants)
- User detail page shows **all tenants** the user belongs to
- Suspension actions are available here

### Phase 3: Create Tenant Admin Controller and Routes

**Goal**: Implement `/tenant-admin` routes with tenant-scoped user management.

**New files**:
- `app/controllers/tenant_admin_controller.rb`
- `app/views/tenant_admin/dashboard.html.erb`
- `app/views/tenant_admin/dashboard.md.erb`
- `app/views/tenant_admin/settings.html.erb`
- `app/views/tenant_admin/settings.md.erb`
- `app/views/tenant_admin/users.html.erb`
- `app/views/tenant_admin/users.md.erb`
- `app/views/tenant_admin/show_user.html.erb`
- `app/views/tenant_admin/show_user.md.erb`
- `app/views/tenant_admin/403_not_tenant_admin.html.erb`
- `app/views/pulse/_sidebar_tenant_admin.html.erb`
- `test/controllers/tenant_admin_controller_test.rb`

**Modified files**:
- `config/routes.rb` (add tenant-admin routes)

**Key differences from old AdminController**:
- Users are identified by **handle** (tenant-specific)
- User queries are **scoped** to current tenant only
- User detail page shows only info relevant to current tenant
- **NO suspension actions** - only app admins can suspend

### Phase 4: Update Sidebar Navigation

**Goal**: Render correct sidebar based on `@sidebar_mode`.

**Changes**:
1. Update sidebar rendering logic to handle new modes:
   - `system_admin` → render `_sidebar_system_admin.html.erb`
   - `app_admin` → render `_sidebar_app_admin.html.erb`
   - `tenant_admin` → render `_sidebar_tenant_admin.html.erb`
   - `admin` → render existing `_sidebar_admin.html.erb` (deprecated)

2. Sidebar contents:
   - **System Admin**: Dashboard, Sidekiq
   - **App Admin**: Dashboard, Tenants, Users, Security
   - **Tenant Admin**: Dashboard, Settings, Users

### Phase 5: Verification and Testing

**Goal**: Ensure all new functionality works correctly.

1. Run all new controller tests
2. Manual testing of all new routes
3. Verify authorization is correct:
   - Non-primary tenant cannot access `/system-admin` or `/app-admin`
   - Non-system-admin cannot access `/system-admin`
   - Non-app-admin cannot access `/app-admin`
   - Non-tenant-admin cannot access `/tenant-admin`
4. Verify user scoping:
   - `/app-admin/users` shows ALL users
   - `/tenant-admin/users` shows only current tenant's users
5. Verify suspension:
   - Only available in `/app-admin`
   - Not available in `/tenant-admin`

### Phase 6: Swap and Cleanup (Future)

**Goal**: Replace old `/admin` with new `/tenant-admin`.

**Not to be done until Phase 5 verification is complete.**

1. Update routes:
   - Change `/tenant-admin` routes to `/admin`
   - Remove old `/admin` routes

2. Rename controller:
   - Rename `TenantAdminController` to `AdminController`
   - Or keep `TenantAdminController` and update routes

3. Rename views:
   - Move `app/views/tenant_admin/` to `app/views/admin/`
   - Or update routes to use `tenant_admin` views

4. Update sidebar:
   - Update `@sidebar_mode = 'admin'` to use new sidebar
   - Remove old `_sidebar_admin.html.erb`

5. Remove deprecated code:
   - Remove old `AdminController` actions
   - Remove old admin views with `is_main_tenant?` conditionals
   - Update old tests or remove them

---

## Database Changes

None required. The `system_admin` and `app_admin` roles are already stored in the User model's `settings` JSON field.

---

## Testing Strategy

### New Tests Required

1. **System Admin Controller Tests** (`test/controllers/system_admin_controller_test.rb`):
   - Access denied for non-system-admins (403)
   - Access denied from non-primary tenants (404)
   - Dashboard renders correctly
   - Sidekiq overview shows queues
   - Sidekiq queue detail shows jobs
   - Sidekiq job detail shows job info
   - Retry job works correctly

2. **App Admin Controller Tests** (`test/controllers/app_admin_controller_test.rb`):
   - Access denied for non-app-admins (403)
   - Access denied from non-primary tenants (404)
   - Dashboard renders correctly
   - Tenant list shows all tenants
   - Create tenant works correctly
   - User list shows ALL users (unscoped)
   - User detail shows all tenants user belongs to
   - Suspend user works correctly
   - Unsuspend user works correctly
   - Security dashboard renders correctly

3. **Tenant Admin Controller Tests** (`test/controllers/tenant_admin_controller_test.rb`):
   - Access denied for non-tenant-admins (403)
   - Dashboard renders correctly
   - Settings page shows current tenant settings
   - Update settings works correctly
   - User list shows only current tenant's users (scoped)
   - User detail shows user info
   - NO suspend/unsuspend routes exist (404)

### Existing Tests

Old `test/controllers/admin_controller_test.rb` remains unchanged - it tests the deprecated functionality until Phase 6.

---

## Rollback Plan

If issues arise:
1. Old `/admin` routes remain fully functional
2. New routes can be disabled by commenting out in routes.rb
3. New controllers/views can be deleted without affecting old functionality

---

## Success Criteria

1. **Clear separation**: Each admin type has its own controller, routes, and views
2. **No conditional view logic**: New views don't check `is_main_tenant?`
3. **Proper scoping**: Tenant admins see only their tenant's users
4. **Secure by default**: System/app features inaccessible from non-primary tenants
5. **All tests pass**: New tests pass, old tests still pass
6. **No user disruption**: Old `/admin` routes continue to work during transition

---

## Open Questions (Resolved)

1. **Backwards compatibility**: ✅ Old routes remain functional until Phase 6
2. **Route naming**: ✅ Use `/tenant-admin` initially, swap to `/admin` in Phase 6
3. **User identification**: App admin uses User ID (global), Tenant admin uses handle (tenant-specific)
4. **Role assignment**: Currently Rails console only (out of scope for now)
5. **Audit logging**: Security audit remains in App Admin (already implemented)

---

## File Summary

### New Files to Create

| Phase | File | Purpose |
|-------|------|---------|
| 1 | `app/controllers/system_admin_controller.rb` | System admin controller |
| 1 | `app/views/system_admin/*.erb` | System admin views (5 HTML + 5 MD) |
| 1 | `app/views/pulse/_sidebar_system_admin.html.erb` | System admin sidebar |
| 1 | `test/controllers/system_admin_controller_test.rb` | System admin tests |
| 2 | `app/controllers/app_admin_controller.rb` | App admin controller |
| 2 | `app/views/app_admin/*.erb` | App admin views (9 HTML + 9 MD) |
| 2 | `app/views/pulse/_sidebar_app_admin.html.erb` | App admin sidebar |
| 2 | `test/controllers/app_admin_controller_test.rb` | App admin tests |
| 3 | `app/controllers/tenant_admin_controller.rb` | Tenant admin controller |
| 3 | `app/views/tenant_admin/*.erb` | Tenant admin views (5 HTML + 5 MD) |
| 3 | `app/views/pulse/_sidebar_tenant_admin.html.erb` | Tenant admin sidebar |
| 3 | `test/controllers/tenant_admin_controller_test.rb` | Tenant admin tests |

### Files to Modify

| Phase | File | Change |
|-------|------|--------|
| 1 | `config/routes.rb` | Add system-admin routes |
| 1 | `app/models/user.rb` | Add `system_admin?` method |
| 2 | `config/routes.rb` | Add app-admin routes |
| 3 | `config/routes.rb` | Add tenant-admin routes |
| 4 | `app/views/layouts/application.html.erb` | Update sidebar rendering |

### Files NOT to Modify (Until Phase 6)

- `app/controllers/admin_controller.rb` - Keep as-is (deprecated)
- `app/views/admin/*` - Keep as-is (deprecated)
- `app/views/pulse/_sidebar_admin.html.erb` - Keep as-is (deprecated)
- `test/controllers/admin_controller_test.rb` - Keep as-is (tests deprecated routes)
