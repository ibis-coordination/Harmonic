---
passing: true
last_verified: 2026-01-11
verified_by: Claude Opus 4.5
---

# Test: Admin Panel Markdown API

Verifies that the admin panel is accessible via the markdown API and that all security restrictions for subagents are properly enforced.

## Prerequisites

- Access to a tenant where you have admin privileges
- For subagent tests: A subagent user with an API token whose parent is also an admin
- For primary subdomain tests: Access to the primary subdomain tenant (for tenant management and Sidekiq)

## Test 1: Basic Admin Access (Person Admin)

### Steps

1. As a person user with admin role, navigate to `/admin`
2. Verify the admin dashboard loads with markdown content
3. Navigate to `/admin/settings`
4. Verify tenant settings are displayed
5. Navigate to `/admin/actions` and `/admin/settings/actions`
6. Verify action endpoints are listed

### Checklist

- [x] `/admin` returns markdown with tenant info, studios, and admin users
- [x] `/admin/settings` shows current tenant name, timezone, and settings
- [x] `/admin/settings` shows the `update_tenant_settings` action
- [x] Action description at `/admin/settings/actions/update_tenant_settings` shows parameter info

## Test 2: Update Tenant Settings Action

### Steps

1. Navigate to `/admin/settings`
2. Note the current tenant name
3. Execute `update_tenant_settings` action with a new name
4. Verify the response shows the updated settings
5. Restore the original name

### Checklist

- [x] `update_tenant_settings(name: "New Name")` updates the tenant name
- [x] Response is valid markdown showing updated settings
- [x] Other settings (timezone, api_enabled, etc.) can also be updated

## Test 3: Tenant Management (Primary Subdomain Only)

### Prerequisites

- Must be on the primary subdomain tenant

### Steps

1. Navigate to `/admin/tenants`
2. Verify list of all tenants is displayed
3. Navigate to `/admin/tenants/new`
4. Verify new tenant form is accessible
5. Navigate to `/admin/tenants/new/actions`
6. Verify `create_tenant` action is available

### Checklist

- [x] `/admin/tenants` lists all tenants with subdomain and name
- [x] `/admin/tenants/new` shows the create tenant form
- [x] `create_tenant(subdomain, name)` action is documented
- [x] Non-primary subdomains return 403 for these routes *(verified by code review: `is_main_tenant?` check)*

## Test 4: Sidekiq Dashboard (Primary Subdomain Only)

### Prerequisites

- Must be on the primary subdomain tenant

### Steps

1. Navigate to `/admin/sidekiq`
2. Verify queues, retries, scheduled, and dead job sections are visible
3. If any jobs exist, navigate to a job detail page `/admin/sidekiq/jobs/:jid`
4. Verify job details are displayed

### Checklist

- [x] `/admin/sidekiq` shows queue sizes and job counts
- [x] `/admin/sidekiq/queues/:name` shows queue details
- [x] `/admin/sidekiq/jobs/:jid` shows job arguments and error info (if applicable)
- [x] `retry_sidekiq_job()` action is available for retryable jobs
- [x] Non-primary subdomains return 403 for these routes *(verified by code review: `is_main_tenant?` check)*

## Test 5: Subagent Admin Access - Both Must Be Admins

**Note:** These security scenarios are fully covered by automated tests in `test/integration/markdown_ui_test.rb`. The checklist below reflects automated test coverage.

### Prerequisites

- A subagent user whose parent is an admin
- The subagent must also have admin role

### Steps

1. Authenticate as a subagent whose parent is NOT an admin
2. Attempt to access `/admin`
3. Verify 403 response with message about parent needing admin role
4. Now authenticate as a subagent whose parent IS an admin (and subagent is also admin)
5. Access `/admin`
6. Verify successful access

### Checklist

- [x] Subagent with admin role but non-admin parent gets 403 *(automated test)*
- [x] Error message mentions "both subagent and parent to be admins" *(automated test)*
- [x] Subagent with admin role AND admin parent can access `/admin` *(automated test)*
- [x] Non-admin subagent (even with admin parent) gets 403 *(automated test)*

## Test 6: Subagent Production Write Restriction

**Note:** Production environment behavior is tested via `Thread.current[:simulate_production]` in automated tests.

### Prerequisites

- A subagent user with admin role whose parent is also admin
- This test simulates production behavior (in actual production deployment)

### Steps (Development/Test Environment)

1. Authenticate as admin subagent
2. Navigate to `/admin/settings`
3. Execute `update_tenant_settings` action
4. Verify the action succeeds

### Expected Production Behavior

In production environment:
- Subagent admin can READ all admin pages
- Subagent admin CANNOT execute any write actions (POST/PUT/DELETE)
- Actions section shows "No actions available (read-only access)"

### Checklist

- [x] In dev/test: Subagent admin can execute write actions *(automated test)*
- [x] In production: Subagent admin POST requests return 403 *(automated test)*
- [x] In production: Error message mentions "Subagents cannot perform admin write operations in production" *(automated test)*
- [x] In production: Admin settings page shows "read-only access" instead of actions *(verified by code review: views check `can_perform_admin_actions?`)*
- [x] Person admins can always write (regardless of environment) *(automated test)*

## Test 7: Non-Admin User Access

**Note:** Covered by automated test `test "GET /admin returns 403 for non-admin user"`.

### Steps

1. Authenticate as a user without admin role
2. Attempt to access `/admin`
3. Verify 403 response

### Checklist

- [x] Non-admin users receive 403 for all `/admin/*` routes *(automated test)*
- [x] Error message indicates admin access required *(automated test)*
