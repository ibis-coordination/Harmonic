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
    ├── deploy.sh             # pull latest images and restart
    ├── rollback.sh           # rollback to previous image version
    ├── hotfix-patch.sh       # emergency file-level patching
    ├── maintenance.sh        # maintenance mode toggle script
    └── generate-caddyfile.sh # manual Caddyfile regeneration
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

On the production server:

```bash
# Code-only changes
./scripts/deploy.sh --skip-migrations

# If the release includes database migrations
./scripts/deploy.sh --with-migrations
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

### Agent Runner

The agent-runner container handles SIGTERM gracefully: it stops accepting
new tasks and waits up to 5 minutes for in-flight tasks to complete.

Standard deploys (`docker compose up -d`) trigger this automatically.
During the drain window, new tasks queue in Redis and are processed by
the new container once it starts.

If the runner is killed before tasks finish (OOM, timeout), orphaned
tasks are automatically detected and marked failed:
- **XAUTOCLAIM** (in the runner) reclaims orphaned stream entries within
  ~2 minutes of the next startup
- **OrphanedTaskSweepJob** (Sidekiq, every 10 min) catches any tasks
  stuck in "running" for >15 minutes

Users see orphaned task failures and can retry.

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
./scripts/rollback.sh v1.11.0
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

## Security Hotfix Workflow

When a vulnerability is reported privately and needs to ship to production before the fix becomes public:

### 1. Create a Security Advisory

Go to **Settings > Security > Advisories > New draft advisory** on the GitHub repo. Describe the vulnerability and affected versions. This stays private to maintainers.

### 2. Develop the Fix in a Private Fork

From the advisory page, click **"Start a temporary private fork"**. GitHub creates a private clone where you can:

- Push branches and open PRs (visible only to advisory collaborators)
- Iterate on the fix with code review

> **Note:** GitHub Actions do not run on private advisory forks. Run the full test suite manually before deploying: `docker compose exec web bundle exec rails test --verbose 2>&1 > /tmp/test-results.txt`

Clone the private fork locally:

```bash
# GitHub provides the clone URL on the advisory page
git clone https://github.com/ibis-coordination/Harmonic-ghsa-XXXX-XXXX-XXXX.git
cd Harmonic-ghsa-XXXX-XXXX-XXXX

# Copy .env from the main repo (not checked into git)
cp ../Harmonic/.env .env
```

> **Warning:** Do NOT merge PRs on the private fork through GitHub's UI — this may push commits to the public repo before the advisory is published. Instead, merge locally and push to the private fork's main branch. The advisory publish step handles the public merge.

### 3. Deploy the Fix

There are three paths, from fastest to slowest:

#### Option A: Emergency file patch (seconds)

For single-file fixes that need to be live immediately. Run on the **production server**. The fix is temporary — the next image deploy overwrites it.

```bash
git pull origin main
./scripts/hotfix-patch.sh app/services/automation_dispatcher.rb
```

#### Option B: Tag and let CI build (~5 minutes)

Preferred when the fix is on public `main`. Run on your **dev machine**.

```bash
git tag v1.X.Y
git push origin v1.X.Y
# Wait for CI (~5 min), then on the production server:
./scripts/deploy.sh
```

#### Option C: Local cross-compile (~20 minutes)

Fallback when CI is unavailable (e.g., private fork). Run on your **dev machine**.

> **Warning:** Do NOT use `docker compose build` directly on Apple Silicon Macs — this produces ARM images that won't run on AMD64 production servers. Use `hotfix-build.sh` which enforces the correct platform.

```bash
# Authenticate: see docs/DEPLOYMENT.md "Container Registry Auth" below
./scripts/hotfix-build.sh v1.X.Y
# Then on the production server:
./scripts/deploy.sh
```

### 4. Verify the Fix in Production

Confirm the vulnerability is patched. Run any relevant smoke tests.

### 5. Publish and Release

Once production is safe:

1. **Publish the advisory** — this makes the advisory visible and credits reporters. Do NOT use the "merge to public repo" option if you've already pushed the fix to main.
2. **Tag a release** on the public repo (e.g., `v1.6.1`) if not already done in step 3.
3. **Notify affected users** if the vulnerability could have been exploited before the fix.

### Rollback

On the **production server**:

```bash
./scripts/rollback.sh v1.11.0
```

Find available tags at: https://github.com/orgs/ibis-coordination/packages/container/harmonic/versions

### Container Registry Auth

To push images manually (Option C), you need a GitHub Personal Access Token with `write:packages` scope:

```bash
# Create token at: https://github.com/settings/tokens/new?scopes=write:packages
read -rs GITHUB_TOKEN && export GITHUB_TOKEN
echo "$GITHUB_TOKEN" | docker login ghcr.io -u "$(git config user.email)" --password-stdin
```

### Notes

- The private fork is deleted automatically when the advisory is published
- CI automatically tags images with version numbers (`:v1.X.Y`) when triggered by git tags, making rollback straightforward
- See [SECURITY.md](../SECURITY.md) for the vulnerability reporting policy

## Related Documentation

- [MONITORING.md](MONITORING.md) - Monitoring and alerting setup
- [SECURITY_AND_SCALING.md](SECURITY_AND_SCALING.md) - Security features and scaling guide
