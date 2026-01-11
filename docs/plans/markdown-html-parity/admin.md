# Admin Panel - Functional Gaps

**Status: COMPLETED**

The admin panel has **no markdown views at all**. All admin functionality is HTML-only.

[← Back to Index](INDEX.md)

---

## Completion Summary

Phase 3 (Admin Panel) has been completed with the following:

### Implemented Features

1. **Markdown views for all admin pages:**
   - `/admin` - Admin dashboard
   - `/admin/settings` - Tenant settings
   - `/admin/tenants` - Tenant list (primary subdomain only)
   - `/admin/tenants/new` - New tenant form (primary subdomain only)
   - `/admin/tenants/:subdomain` - Tenant details
   - `/admin/sidekiq` - Sidekiq dashboard (primary subdomain only)
   - `/admin/sidekiq/queues/:name` - Queue details
   - `/admin/sidekiq/jobs/:jid` - Job details

2. **Markdown API actions:**
   - `update_tenant_settings(name, timezone, api_enabled, require_login, allow_file_uploads)`
   - `create_tenant(subdomain, name)`
   - `retry_sidekiq_job()`

3. **Security implementations:**
   - Subagents require BOTH subagent AND parent to be admins
   - Subagents cannot perform write operations in production
   - `can_perform_admin_actions?` helper shows/hides actions based on permissions

4. **Tests:**
   - 12 new tests covering admin markdown API
   - Tests for subagent access restrictions
   - Tests using production environment simulation via `Thread.current[:simulate_production]`

---

## Use Case

The markdown admin UI is for **AI agents doing admin tasks**: ops, monitoring, debugging, investigation. This includes full visibility into Sidekiq job queues, tenant settings, and system state.

### Future: Readonly Admin Permission

We anticipate a future `readonly_admin` permission type for subagents that can:
- View all admin pages (investigation, monitoring)
- NOT perform admin actions (no mutations)

**Implementation note:** Structure markdown templates so actions are shown conditionally based on permission level. This prepares for the readonly admin feature without implementing it now.

```erb
<% if can_perform_admin_actions?(@current_user) %>
## Actions
- update_tenant_settings(name, timezone, ...)
<% end %>
```

---

## Overview

The admin panel provides tenant-level administration. Access requires admin role.
Some features only available on primary subdomain (system-wide administration).

**Current State:** 10 HTML templates, 0 markdown templates.

---

## Missing Actions

### Tenant Settings (`/admin/settings`)

| Action | HTML Capability | Markdown Status |
|--------|-----------------|-----------------|
| `update_tenant_settings()` | Edit tenant name | Missing |
| `update_tenant_settings()` | Set timezone | Missing |
| `update_tenant_settings()` | Toggle require_login | Missing |
| `update_tenant_settings()` | Toggle allow_file_uploads | Missing |
| `update_tenant_settings()` | Toggle api_enabled | Missing |

### Tenant Management (Primary Subdomain Only)

| Action | HTML Capability | Markdown Status |
|--------|-----------------|-----------------|
| `create_tenant()` | New tenant form | Missing |

### Sidekiq Dashboard (Primary Subdomain Only)

| Action | HTML Capability | Markdown Status |
|--------|-----------------|-----------------|
| `retry_sidekiq_job()` | Retry failed job button | Missing |
| `delete_sidekiq_job()` | Delete job from queue | Missing (if exists in HTML) |

---

## Missing Pages

| Page | Purpose | Priority |
|------|---------|----------|
| `/admin` | Admin dashboard - tenant info, settings, studios, admin users | High |
| `/admin/settings` | View/edit tenant settings | High |
| `/admin/tenants` | List all tenants (primary only) | High |
| `/admin/tenants/new` | Create new tenant (primary only) | High |
| `/admin/tenants/:subdomain` | View tenant details | High |
| `/admin/sidekiq` | View job queues, retries, scheduled, dead | High |
| `/admin/sidekiq/queues/:name` | View queue details | High |
| `/admin/sidekiq/jobs/:jid` | View job details, retry/delete | High |

---

## Page Content Specifications

### `/admin` - Admin Dashboard

**Content (always shown):**
- Tenant name, subdomain, created/updated dates
- Tenant settings (JSON or formatted)
- Main studio info (ID, name, content counts)
- List of other studios
- List of admin users
- (Primary only) List of other tenants
- (Primary only) List of all person users across tenants

**Actions (conditional on full admin):**
- Link to edit settings

### `/admin/settings` - Tenant Settings

**Content (always shown):**
- Current tenant name
- Current timezone
- Current require_login setting
- Current allow_file_uploads setting
- Current api_enabled setting

**Actions (conditional on full admin):**
- `update_tenant_settings(name, timezone, require_login, allow_file_uploads, api_enabled)`

### `/admin/tenants` - Tenants List (Primary Only)

**Content (always shown):**
- List of all tenants with subdomain and name

**Actions (conditional on full admin):**
- Link to create new tenant

### `/admin/tenants/new` - New Tenant (Primary Only)

**Content (always shown):**
- Form description

**Actions (conditional on full admin):**
- `create_tenant(subdomain, name)`

### `/admin/tenants/:subdomain` - Tenant Details

**Content (always shown):**
- Tenant name, subdomain
- Tenant settings (if current user is admin of that tenant)

**Actions (conditional on full admin):**
- Link to tenant's admin settings (if admin of that tenant)

### `/admin/sidekiq` - Sidekiq Dashboard (Primary Only)

**Content (always shown):**
- List of queues with sizes
- List of retries with retry counts
- List of scheduled jobs with scheduled times
- List of dead jobs with failure times

**Actions (conditional on full admin):**
- Links to queue/job details

### `/admin/sidekiq/queues/:name` - Queue Details

**Content (always shown):**
- Queue name
- List of jobs with JIDs and enqueued times

**Actions (conditional on full admin):**
- Links to job details

### `/admin/sidekiq/jobs/:jid` - Job Details

**Content (always shown):**
- Job JID
- Job arguments (JSON)
- Error class and message (if failed)

**Actions (conditional on full admin):**
- `retry_sidekiq_job(jid)` - if job is in retry/dead set
- `delete_sidekiq_job(jid)` - remove from queue

---

## Security Concerns (Phase 3)

### 1. Subagent Admin Access Restrictions

**Requirement:** Subagents can only access admin pages if BOTH conditions are met:
- The subagent user has admin role
- The subagent's parent user ALSO has admin role

**Rationale:** Prevents privilege escalation where a non-admin person creates a subagent and somehow the subagent gets admin access.

**Implementation:**
```ruby
def ensure_subagent_admin_access
  return true unless current_user.subagent?
  # Subagent must be admin AND parent must be admin
  unless current_user.admin? && current_user.parent&.admin?
    render status: 403, plain: '403 Unauthorized - Subagent admin access requires both subagent and parent to be admins'
    return false
  end
  true
end
```

### 2. Subagent Write Operations - Production Restriction

**Requirement:** Subagents cannot perform any write operations in the admin panel in production. They can only perform write operations in development and test environments.

**Rationale:** Safety measure to prevent AI agents from accidentally making destructive admin changes in production.

**Implementation:**
```ruby
def block_subagent_admin_writes_in_production
  return true unless current_user.subagent?
  return true unless Rails.env.production?
  # In production, subagents can only read admin pages, not write
  if request.method != 'GET'
    render status: 403, plain: '403 Unauthorized - Subagents cannot perform admin write operations in production'
    return false
  end
  true
end
```

**Tests Required:**
- Mock production environment (`Rails.env.stub(:production?) { true }`)
- Verify subagent GET requests succeed (with proper admin access)
- Verify subagent POST/PUT/DELETE requests return 403

### 3. Combined Authorization Flow for Admin Actions

For any admin action, the authorization checks should be:

1. **Is user authenticated?** → 401 if not
2. **Is user an admin?** → 403 if not
3. **If subagent: Is parent also admin?** → 403 if not
4. **If subagent in production: Is this a read-only operation?** → 403 if write

```ruby
before_action :ensure_admin_user
before_action :ensure_subagent_admin_access
before_action :block_subagent_admin_writes_in_production
```

---

## Implementation Notes

### Authentication
- All admin routes require `ensure_admin_user` before_action
- Markdown views must respect same authorization
- Return 403 for non-admin users
- **NEW:** Subagents require parent to also be admin
- **NEW:** Subagents cannot write in production

### Primary Subdomain Check
- Tenant management and Sidekiq only on primary subdomain
- Check: `@current_tenant.subdomain == ENV['PRIMARY_SUBDOMAIN']`
- Return 403 for non-primary subdomains on these routes

### Conditional Actions Pattern
```erb
## Tenant Settings

| Setting | Value |
|---------|-------|
| Name | <%= @current_tenant.name %> |
| Timezone | <%= @current_tenant.timezone %> |
...

<% if can_perform_admin_actions?(@current_user) %>
## Actions

- update_tenant_settings(name, timezone, require_login, allow_file_uploads, api_enabled)
<% end %>
```

### Helper Method (Future)
```ruby
def can_perform_admin_actions?(user)
  # For now, all admins can perform actions
  # Future: check for readonly_admin role
  @current_tenant.is_admin?(user)
end
```
