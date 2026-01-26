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
curl -O https://raw.githubusercontent.com/ibis-coordination/harmonic/main/Caddyfile.example
curl -O https://raw.githubusercontent.com/ibis-coordination/harmonic/main/.env.example

# Configure
cp .env.example .env
cp Caddyfile.example Caddyfile
# Edit .env and Caddyfile with your settings

# Run
docker compose -f docker-compose.production.yml up -d
```

Requirements:
- Docker and Docker Compose
- PostgreSQL database (managed recommended)
- Domain name pointed to your server

## Logging and Monitoring

### Log Locations

| Log | Location | Contents |
|-----|----------|----------|
| Rails application | stdout (Docker logs) | Application requests, errors |
| Security audit | `log/security_audit.log` | Auth events, rate limiting |
| Sidekiq | stdout (Docker logs) | Background job processing |

### Recommended Monitoring

1. **Log aggregation**: Ship logs to a centralized service (Datadog, Papertrail, ELK stack)
2. **Alert on**:
   - Multiple `login_failure` events from same IP
   - `rate_limited` events
   - `ip_blocked` events
   - Application errors (5xx responses)
3. **Uptime monitoring**: Monitor `/healthcheck` endpoint
4. **Resource monitoring**: Track container memory/CPU usage

### Example: Filtering Security Events

```bash
# View recent security events
docker compose -f docker-compose.production.yml exec web tail -f log/security_audit.log | jq

# Filter for login failures
docker compose -f docker-compose.production.yml exec web cat log/security_audit.log | jq 'select(.event == "login_failure")'
```
