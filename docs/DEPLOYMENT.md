# Deployment Guide

## Production Deployment

Production uses pre-built Docker images from GitHub Container Registry. No source code needed on the server.

### Server Setup (One-Time)

Clone the repo or copy these files to your server:

```
/opt/harmonic/
├── docker-compose.production.yml
├── .env                      # your configuration
├── config/
│   └── maintenance/
│       ├── Caddyfile.template  # maintenance mode template
│       └── maintenance.html    # maintenance page
└── scripts/
    ├── generate-caddyfile.sh # manual Caddyfile regeneration (delegates to rake task)
    └── maintenance.sh        # maintenance mode toggle script
```

After initial setup, a `Caddyfile` will also be present - it is auto-generated from tenant subdomains by `RegenerateCaddyfileJob` (see [Caddyfile Management](#caddyfile-management) below).

### Release Workflow

```bash
# On your dev machine
git push origin main
git tag v1.2.3
git push --tags
# CI builds and publishes image (~5 min)
```

### Deploy

```bash
docker compose -f docker-compose.production.yml pull
docker compose -f docker-compose.production.yml up -d
docker compose -f docker-compose.production.yml exec web bundle exec rails db:migrate  # if needed
```

### Caddyfile Management

The Caddyfile is auto-generated from tenant subdomains by the `CaddyfileGenerator` service. It produces reverse proxy entries for the bare domain (redirect), primary subdomain, auth subdomain, and each tenant subdomain.

**Automatic regeneration:** The `RegenerateCaddyfileJob` runs automatically whenever a tenant is created, destroyed, or has its subdomain changed (via `after_commit` callbacks on the `Tenant` model). The job:
1. Generates the Caddyfile content via `CaddyfileGenerator`
2. Writes it to disk at `CADDYFILE_PATH` (default: `/app/Caddyfile`, bind-mounted from host)
3. Reloads Caddy via its admin API (`POST /load` to `CADDY_ADMIN_URL`)

If Caddy is unreachable when the job runs, the file is still written to disk and a warning is logged.

**Manual regeneration** (e.g., during initial setup or after a database restore):

```bash
# Preview changes without applying
./scripts/generate-caddyfile.sh --dry-run

# Generate and apply (reloads Caddy automatically)
./scripts/generate-caddyfile.sh
```

The script is idempotent - safe to run anytime. It delegates to the `caddyfile:generate` rake task, then diffs, applies, and reloads Caddy.

### Maintenance Mode

For deployments requiring downtime (e.g., database migrations that change schema):

```bash
# Enable maintenance mode (serves static page, returns 503 on /healthcheck)
./scripts/maintenance.sh on

# Check status
./scripts/maintenance.sh status

# Disable maintenance mode
./scripts/maintenance.sh off
```

The script:
- Backs up `Caddyfile` and generates a maintenance version from `config/maintenance/Caddyfile.template`
- Automatically extracts all domain blocks from the current Caddyfile (no manual sync needed)
- Serves `config/maintenance/maintenance.html` for all requests
- Returns 503 on `/healthcheck` so load balancers know the app is down
- Works in both development (with `HOST_MODE=caddy`) and production

### Deployments with Downtime

For schema-changing migrations:

```bash
# 1. Drain Sidekiq queue
docker compose -f docker-compose.production.yml stop sidekiq
# Wait for in-flight jobs to complete

# 2. Enable maintenance mode
./scripts/maintenance.sh on

# 3. Deploy
docker compose -f docker-compose.production.yml pull
docker compose -f docker-compose.production.yml exec web bundle exec rails db:migrate
docker compose -f docker-compose.production.yml up -d web

# 4. Disable maintenance mode
./scripts/maintenance.sh off

# 5. Restart Sidekiq
docker compose -f docker-compose.production.yml up -d sidekiq
```

### Rollback

```bash
# Edit docker-compose.production.yml to pin version:
# image: ghcr.io/ibis-coordination/harmonic:v1.2.2
docker compose -f docker-compose.production.yml pull
docker compose -f docker-compose.production.yml up -d
```

## Environment Variables

See `.env.example` for all required variables. Key ones:

| Variable | Description |
|----------|-------------|
| `DATABASE_URL` | PostgreSQL connection string |
| `REDIS_URL` | Redis connection string |
| `SECRET_KEY_BASE` | Rails secret (generate with `openssl rand -hex 64`) |
| `HOSTNAME` | Your domain (e.g., `harmonic.example.com`) |
| `PRIMARY_SUBDOMAIN` | Main app subdomain (e.g., `app`) |
| `AUTH_SUBDOMAIN` | Authentication subdomain (e.g., `auth`) |
| `CADDYFILE_PATH` | Path to write generated Caddyfile (default: `/app/Caddyfile`) |
| `CADDY_ADMIN_URL` | Caddy admin API URL (default: `http://caddy:2019`) |
| `SENTRY_DSN` | Sentry error tracking DSN (optional, recommended) |
| `SLACK_WEBHOOK_URL` | Slack webhook for security alerts (optional, recommended) |
| `METRICS_AUTH_TOKEN` | Bearer token for `/metrics` endpoint (optional) |

## Post-Deployment Setup

After your first deployment, set up monitoring and alerting:

**→ See [MONITORING.md](MONITORING.md) for complete setup instructions**

Quick checklist:
- [ ] Set up [Sentry](https://sentry.io) error tracking (`SENTRY_DSN`)
- [ ] Configure Slack alerts (`SLACK_WEBHOOK_URL`)
- [ ] Set up external uptime monitoring for `/healthcheck`

## Verifying the Deployment

After deploying, verify everything is working:

```bash
# Check health endpoint
curl https://yourdomain.com/healthcheck

# Check application logs
docker compose -f docker-compose.production.yml logs web --tail 50

# Check background job processing
docker compose -f docker-compose.production.yml logs sidekiq --tail 50
```

## Troubleshooting

### Migrations Not Applied

```bash
docker compose -f docker-compose.production.yml exec web bundle exec rails db:migrate
```

### View Logs

```bash
docker compose -f docker-compose.production.yml logs web --tail 100
docker compose -f docker-compose.production.yml logs sidekiq --tail 100
```

### Health Check Failing

```bash
# Check database connectivity
docker compose -f docker-compose.production.yml exec web rails runner "ActiveRecord::Base.connection.execute('SELECT 1')"

# Check Redis connectivity
docker compose -f docker-compose.production.yml exec web rails runner "Redis.new(url: ENV['REDIS_URL']).ping"
```

### Container Won't Start

```bash
# Check for startup errors
docker compose -f docker-compose.production.yml logs web --tail 200

# Verify environment variables
docker compose -f docker-compose.production.yml exec web env | grep -E "(DATABASE|REDIS|SECRET)"
```

## Related Documentation

- [MONITORING.md](MONITORING.md) - Monitoring and alerting setup
- [SECURITY_AND_SCALING.md](SECURITY_AND_SCALING.md) - Security features and scaling guide
