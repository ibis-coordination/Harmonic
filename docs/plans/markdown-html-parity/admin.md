# Admin Panel - Functional Gaps

The admin panel has **no markdown views at all**. All admin functionality is HTML-only.

[← Back to Index](INDEX.md)

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

## Implementation Notes

### Authentication
- All admin routes require `ensure_admin_user` before_action
- Markdown views must respect same authorization
- Return 403 for non-admin users

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
