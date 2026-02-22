# Security and Scaling Guide

## Security Features

Harmonic includes the following security measures:

| Feature | Implementation |
|---------|---------------|
| HTTPS | Caddy with automatic Let's Encrypt certificates |
| Force SSL | Enabled in production (HSTS, secure cookies) |
| CSRF protection | Rails built-in CSRF tokens |
| SQL injection | ActiveRecord parameterized queries |
| XSS protection | Rails escaping + Content Security Policy headers |
| Authentication | OAuth (GitHub) or password-based |
| Multi-tenancy | Database-level tenant isolation via default_scope |
| File storage | S3-compatible (DO Spaces) with signed URLs |
| Rate limiting | rack-attack: general (300/min), writes (60/min), login (5/20min) |
| Container security | Non-root user, network isolation, resource limits |
| Virus scanning | ClamAV for file uploads (production) |
| Security audit logging | JSON logs for auth events, rate limiting, admin actions |
| Redis authentication | Password-protected in production |

### Multi-Tenant Data Isolation

Harmonic uses **subdomain-based multi-tenancy** with strict data isolation:

**Automatic scoping**: All models that belong to a tenant use `default_scope` to filter by `Tenant.current_id`. Queries automatically exclude data from other tenants.

**Banned `.unscoped` calls**: Direct `.unscoped` usage is banned to prevent accidental cross-tenant data leaks. Instead, use these safe wrapper methods (defined in `ApplicationRecord`):

| Method | Use Case | Runtime Check |
|--------|----------|---------------|
| `tenant_scoped_only(tenant_id)` | Cross-collective access within same tenant | Raises if `tenant_id` is nil (defaults to `Tenant.current_id`) |
| `unscoped_for_admin(user)` | Admin operations | Raises unless `user.app_admin?` or `user.sys_admin?` |
| `unscoped_for_system_job` | Background jobs | Raises unless `Tenant.current_id.nil?` |
| `for_user_across_tenants(user)` | User's own data across tenants | Raises if user nil or model lacks `user_id` |

**Enforcement**:
- Static analysis: `./scripts/check-tenant-safety.sh` detects banned patterns
- Pre-commit hook: Blocks commits with banned `.unscoped` usage
- CI: Fails builds with banned patterns

**Models without tenant scoping** (global data): `User`, `Tenant`, `OauthIdentity`, `OmniAuthIdentity`

### Content Security Policy

CSP headers are configured in `config/initializers/content_security_policy.rb`:
- `default-src 'self'`
- `script-src 'self'` (no inline scripts)
- `style-src 'self' 'unsafe-inline'` (inline styles allowed for Turbo/Stimulus)
- `frame-ancestors 'none'` (prevents clickjacking)

Note: `unsafe-inline` for styles is required for Turbo/Stimulus functionality. Future work may implement nonces for styles.

### Security Audit Logging

Security events are logged to `log/security_audit.log` in JSON format:
- Login success/failure
- Logout
- Password reset requests
- Password changes
- Rate limiting events
- IP blocks

In production, events are also written to Rails logger with `SECURITY_AUDIT` tag for centralized logging.

## Security Checklist

Before going live:

- [ ] `.env` file permissions restricted (`chmod 600 .env`)
- [ ] Database SSL connection enabled (`sslmode=require` in DATABASE_URL)
- [ ] Database IP allowlist configured (if using managed DB)
- [ ] Secrets not in version control
- [ ] Backup restoration tested
- [ ] `REDIS_PASSWORD` set to a strong password
- [ ] `SECRET_KEY_BASE` generated and secured
- [ ] Security audit log monitoring configured (see Logging section)

### Secret Rotation

**SECRET_KEY_BASE**: Rotating this key will invalidate all existing sessions. Plan for user re-authentication after rotation.

**REDIS_PASSWORD**: Can be rotated by:
1. Setting new password in `.env`
2. Restarting all services: `docker compose -f docker-compose.production.yml restart`

**Database credentials**: Rotate through your managed database provider's interface, then update `DATABASE_URL`.

### Dependency Scanning

GitHub Dependabot is enabled on this repository and automatically creates PRs for vulnerable dependencies. Review and merge Dependabot PRs promptly.

For manual checks:

```bash
# Ruby dependencies
bundle audit check --update

# Node dependencies
npm audit
```

## Horizontal Scaling

Harmonic is designed for horizontal scaling:

**Already stateless:**
- Sessions in secure cookies (not server memory)
- File uploads to S3-compatible storage
- Database is external (managed PostgreSQL)
- Background jobs via Redis/Sidekiq
- Cache store uses Redis

**Important**: All web instances must share the same `SECRET_KEY_BASE` environment variable. This key is used to encrypt session cookies - if instances have different keys, users will experience session issues when their requests hit different instances.

**Scaling architecture:**

```
                    ┌─────────────────┐
                    │  Load Balancer  │
                    └────────┬────────┘
                             │
            ┌────────────────┼────────────────┐
            ▼                ▼                ▼
     ┌──────────┐     ┌──────────┐     ┌──────────┐
     │  Web 1   │     │  Web 2   │     │  Web 3   │
     └────┬─────┘     └────┬─────┘     └────┬─────┘
          └────────────────┼────────────────┘
                           │
          ┌────────────────┼────────────────┐
          ▼                ▼                ▼
   ┌────────────┐   ┌────────────┐   ┌────────────┐
   │ PostgreSQL │   │   Redis    │   │ S3 Storage │
   └────────────┘   └────────────┘   └────────────┘
```

**To scale horizontally:**

1. Use a load balancer (DigitalOcean LB, Caddy, or Docker Swarm)
2. Run multiple web containers pointing to same database/Redis
3. Scale Sidekiq workers as needed

| Component | Scaling Strategy |
|-----------|-----------------|
| Web (Rails) | Horizontal - add containers |
| Sidekiq | Horizontal - add workers |
| PostgreSQL | Vertical first, then read replicas |
| Redis | Vertical, or Redis Cluster |
| File storage | S3 handles automatically |

## Self-Hosting

Self-hosters can run Harmonic with minimal setup:

```bash
# Get the files
mkdir harmonic && cd harmonic
curl -O https://raw.githubusercontent.com/ibis-coordination/harmonic/main/docker-compose.production.yml
curl -O https://raw.githubusercontent.com/ibis-coordination/harmonic/main/.env.example
mkdir -p scripts
curl -o scripts/generate-caddyfile.sh https://raw.githubusercontent.com/ibis-coordination/harmonic/main/scripts/generate-caddyfile.sh
chmod +x scripts/generate-caddyfile.sh

# Configure
cp .env.example .env
# Edit .env with your settings

# Run (Caddyfile is auto-generated from tenant subdomains after database setup)
docker compose -f docker-compose.production.yml up -d
docker compose -f docker-compose.production.yml exec web bundle exec rails db:create db:schema:load db:seed
./scripts/generate-caddyfile.sh
```

Requirements:
- Docker and Docker Compose
- PostgreSQL database (managed recommended)
- Domain name pointed to your server

## Logging and Monitoring

For comprehensive monitoring setup, see [MONITORING.md](MONITORING.md).

### Quick Reference

| Component | Purpose | Configuration |
|-----------|---------|---------------|
| Sentry | Error tracking | `SENTRY_DSN` |
| AlertService | Security alerts | `SLACK_WEBHOOK_URL` |
| Yabeda | Application metrics | `/metrics` endpoint |
| Lograge | Structured logging | Enabled in production |
| Health check | Uptime monitoring | `/healthcheck` endpoint |

### Log Locations

| Log | Location | Contents |
|-----|----------|----------|
| Rails application | stdout (Docker logs) | Application requests, errors |
| Security audit | `log/security_audit.log` | Auth events, rate limiting |
| Sidekiq | stdout (Docker logs) | Background job processing |

### Recommended Alerts

| Event | Source | Action |
|-------|--------|--------|
| `ip_blocked` | SecurityAuditLog | Automatic Slack alert via AlertService |
| `rate_limited` on auth | SecurityAuditLog | Automatic Slack alert via AlertService |
| 5xx error rate > 1% | Sentry | Configure in Sentry UI |
| Health check failure | External monitor | Configure uptime service |

### Example: Filtering Security Events

```bash
# View recent security events
docker compose -f docker-compose.production.yml exec web tail -f log/security_audit.log | jq

# Filter for login failures
docker compose -f docker-compose.production.yml exec web cat log/security_audit.log | jq 'select(.event == "login_failure")'
```
