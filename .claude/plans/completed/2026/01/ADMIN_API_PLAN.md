# Admin API Plan

## Overview

Expose an authenticated API for external services (like the billing app) to manage tenants. This is separate from the existing `/admin/*` UI routes which use session-based auth.

---

## Admin Hierarchy

There are four distinct levels of admin access:

| Level | Scope | Access Method | Examples |
|-------|-------|---------------|----------|
| **Sys Admin** | Infrastructure | Rails console, database access | DB migrations, server config, emergency fixes |
| **App Admin** | All tenants | Admin API (API key) | Create/suspend tenants, manage billing integration |
| **Tenant Admin** | Single tenant | UI + API (session/token) | Create superagents, manage tenant settings, invite users |
| **Superagent Admin** | Single superagent | UI + API (session/token) | Manage superagent settings, roles, webhooks |

**This plan covers the App Admin layer** - the API that external services use to manage tenants across the entire application.

The primary consumer of this API is the **Harmonic Admin App** (private repo), which handles:
- Billing and subscription management (Stripe)
- Customer support tooling
- Operational dashboards
- Other business concerns that don't belong in the open-source product

This separation keeps the open-source Harmonic app focused on the core product. We don't want Harmonic to become a CRM.

---

## Existing Admin Functionality

The `AdminController` already handles tenant management via UI:
- `POST /admin/tenants` - Creates tenant with subdomain, name, main superagent, and adds current user as admin
- `GET /admin/tenants/:subdomain` - View tenant details
- Restricted to admins on the primary subdomain (`is_main_tenant?` check)
- Uses session-based authentication

## Admin API Design

Three separate API namespaces with explicit boundaries. Each has its own controller and auth checks.

### Authentication

All use existing Bearer token authentication:

```
Authorization: Bearer <API_TOKEN>
```

### Admin Flags on API Tokens

| Flag | Purpose | API Namespace |
|------|---------|---------------|
| `sys_admin` | Infrastructure monitoring, healthchecks, metrics | `/api/sys_admin/*` |
| `app_admin` | Cross-tenant management | `/api/app_admin/*` |
| `tenant_admin` | Single tenant automation | `/api/tenant_admin/*` |

Each flag grants access to **only** its corresponding namespace. No crossover.

### Redundant Authorization Checks

Access to each namespace requires **both** conditions:

1. **Token flag** - Token must have the corresponding flag set
2. **User role** - User associated with the token must have the corresponding role

```ruby
# For /api/app_admin/* endpoints
token.app_admin? && token.user.app_admin?
```

This redundancy is a security feature. Flags and roles are set via Rails console only.

---

## API Namespaces

### `/api/sys_admin/*` (Infrastructure)

For monitoring and alerting systems. Read-only metrics and healthchecks.

```
GET /api/sys_admin/health           # Detailed health check
GET /api/sys_admin/metrics          # Application metrics
```

### `/api/app_admin/*` (Cross-Tenant) ← This plan focuses here

For the Admin App to manage tenants.

```
GET    /api/app_admin/tenants              # List tenants
POST   /api/app_admin/tenants              # Create tenant
GET    /api/app_admin/tenants/:id          # Get tenant
PATCH  /api/app_admin/tenants/:id          # Update tenant
DELETE /api/app_admin/tenants/:id          # Delete tenant

POST   /api/app_admin/tenants/:id/suspend  # Suspend tenant
POST   /api/app_admin/tenants/:id/activate # Activate tenant
```

### `/api/tenant_admin/*` (Single Tenant)

For tenant-scoped automation. Scoped to the token's tenant.

```
GET    /api/tenant_admin/superagents       # List superagents
POST   /api/tenant_admin/superagents       # Create superagent
# etc.
```

### Request/Response Examples

#### List Tenants

```
GET /api/app_admin/tenants
Authorization: Bearer <API_TOKEN>
```

Response:
```json
{
  "tenants": [
    {
      "id": "abc123",
      "subdomain": "acme",
      "name": "Acme Corp",
      "suspended_at": null,
      "created_at": "2026-01-16T..."
    }
  ]
}
```

#### Create Tenant

```
POST /api/app_admin/tenants
Authorization: Bearer <API_TOKEN>
Content-Type: application/json

{
  "subdomain": "acme",
  "name": "Acme Corp"
}
```

Response:
```json
{
  "id": "abc123",
  "subdomain": "acme",
  "name": "Acme Corp",
  "suspended_at": null,
  "created_at": "2026-01-16T..."
}
```

#### Suspend Tenant

```
POST /api/app_admin/tenants/abc123/suspend
Authorization: Bearer <API_TOKEN>
Content-Type: application/json

{
  "reason": "payment_failed"
}
```

#### Activate Tenant

```
POST /api/app_admin/tenants/abc123/activate
Authorization: Bearer <API_TOKEN>
```

---

## Data Model Changes

Add to `tenants` table:

| Column | Type | Description |
|--------|------|-------------|
| `suspended_at` | datetime | When tenant was suspended (null = active) |
| `suspended_reason` | string | Why suspended (e.g., "payment_failed") |

---

## Implementation

### Phase 0: Test Infrastructure (TDD)

Write tests first given the security-sensitive nature of this feature.

**Token/role authorization tests:**
- [ ] Test that `app_admin` token + `app_admin` user can access `/api/app_admin/*`
- [ ] Test that `app_admin` token without `app_admin` user role returns 403
- [ ] Test that `app_admin` user without `app_admin` token flag returns 403
- [ ] Test that `sys_admin` token cannot access `/api/app_admin/*`
- [ ] Test that `tenant_admin` token cannot access `/api/app_admin/*`
- [ ] Test that regular token (no admin flags) returns 403
- [ ] Test that expired token returns 401
- [ ] Test that missing token returns 401

**Tenant endpoint tests:**
- [ ] Test list tenants returns all tenants
- [ ] Test create tenant with valid params
- [ ] Test create tenant with duplicate subdomain returns error
- [ ] Test get tenant by ID
- [ ] Test get tenant by subdomain
- [ ] Test update tenant name
- [ ] Test update tenant feature flags
- [ ] Test delete tenant

**Suspend/activate tests:**
- [ ] Test suspend sets `suspended_at` and `suspended_reason`
- [ ] Test activate clears `suspended_at`
- [ ] Test suspended tenant users see suspension page
- [ ] Test suspended tenant API requests return 403

### Phase 1: Admin Flags and Roles

**Token flags:**
- [ ] Add `sys_admin`, `app_admin`, `tenant_admin` boolean columns to `api_tokens` table
- [ ] Add `sys_admin?`, `app_admin?`, `tenant_admin?` methods to `ApiToken` model

**User roles:**
- [ ] Add `app_admin` boolean column to `users` table (global role, not tenant-scoped)
- [ ] Add `app_admin?` method to `User` model

**Authorization:**
- [ ] Add `can_access_admin_api?` method that checks both token flag AND user role

### Phase 2: Tenant Endpoints

- [ ] `GET /api/app_admin/tenants` - List tenants
- [ ] `POST /api/app_admin/tenants` - Create tenant (adapt from existing `create_tenant`)
- [ ] `GET /api/app_admin/tenants/:id` - Get tenant details
- [ ] `PATCH /api/app_admin/tenants/:id` - Update tenant (name, feature flags)
- [ ] `DELETE /api/app_admin/tenants/:id` - Delete tenant

### Phase 3: Suspend/Activate

- [ ] Add `suspended_at` and `suspended_reason` columns to tenants
- [ ] `POST /api/app_admin/tenants/:id/suspend` - Set suspended_at and reason
- [ ] `POST /api/app_admin/tenants/:id/activate` - Clear suspended_at
- [ ] Update `ApplicationController` to check suspension and render error page

---

## Files to Create

- `app/controllers/api/app_admin_controller.rb` - Base controller for app_admin namespace
- `app/controllers/api/app_admin/tenants_controller.rb` - Tenant CRUD + suspend/activate
- `app/controllers/api/sys_admin_controller.rb` - Base controller for sys_admin namespace (future)
- `app/controllers/api/tenant_admin_controller.rb` - Base controller for tenant_admin namespace (future)
- `db/migrate/*_add_admin_flags_to_api_tokens.rb` - Add admin flag columns to tokens
- `db/migrate/*_add_admin_roles_to_users.rb` - Add admin role columns to users
- `db/migrate/*_add_suspended_to_tenants.rb` - Add suspension columns

## Files to Modify

- `app/models/api_token.rb` - Add admin flag methods
- `app/models/user.rb` - Add admin role methods (`app_admin?`, `sys_admin?`, `tenant_admin?`)
- `config/routes.rb` - Add `/api/app_admin/*`, `/api/sys_admin/*`, `/api/tenant_admin/*` namespaces
- `app/controllers/application_controller.rb` - Check tenant suspension
- `app/views/layouts/` - Add suspended tenant error page

---

## Security Considerations

1. **Token provisioning** - Admin tokens are created via Rails console only, not UI
2. **Token rotation** - Admin tokens can be deleted and recreated via console
3. **Rate limiting** - Consider adding rate limits (future)
4. **Audit logging** - Log all admin API calls (future)
5. **IP allowlisting** - Optional restriction to admin app IPs (future)

---

## Open Questions

1. **Tenant lookup** - By ID or subdomain? (Recommend: support both via `id` param that accepts either)
2. **User creation** - Should `POST /api/app_admin/tenants` also create an initial admin user, or is that separate?
3. **Soft vs hard delete** - Should `DELETE` soft-delete (suspend) or hard-delete?
