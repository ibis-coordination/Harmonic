# Monitoring and Alerting Setup Guide

This guide walks you through setting up monitoring and alerting for Harmonic in production.

## Overview

| Component | Purpose | Required | Setup Time |
|-----------|---------|----------|------------|
| Sentry | Error tracking | Recommended | 5 min |
| Slack Alerts | Security notifications | Recommended | 5 min |
| Uptime Monitoring | Health checks | Recommended | 5 min |
| Prometheus Metrics | Application metrics | Optional | 15 min |
| cAdvisor | Container metrics | Optional | 5 min |
| Lograge | Structured logging | Automatic | None |

## Post-Deployment Checklist

After deploying Harmonic, complete these steps:

- [ ] Set up Sentry error tracking
- [ ] Configure Slack webhook for security alerts
- [ ] Set up external uptime monitoring
- [ ] (Optional) Configure Prometheus metrics scraping
- [ ] (Optional) Enable cAdvisor for container metrics

---

## 1. Sentry Error Tracking

Sentry aggregates application errors with full context for debugging. Free tier includes 5,000 errors/month.

### Setup Steps

1. **Create a Sentry account**
   - Go to [sentry.io](https://sentry.io) and sign up

2. **Create a new project**
   - Click "Create Project"
   - Select **Rails** as the platform
   - Name it (e.g., "harmonic-production")

3. **Copy the DSN**
   - Go to Settings → Projects → [Your Project] → Client Keys (DSN)
   - Copy the DSN (looks like `https://abc123@o456.ingest.sentry.io/789`)

4. **Add to your production `.env`**
   ```bash
   SENTRY_DSN=https://your-dsn-here@o123.ingest.sentry.io/456
   ```

5. **Restart the application**
   ```bash
   docker compose restart web sidekiq
   ```

6. **Verify setup**
   - Check Sentry dashboard for initialization events
   - Or test manually via Rails console:
     ```ruby
     Sentry.capture_message("Test event from Harmonic")
     ```

### What Gets Tracked

- All unhandled exceptions with full stack traces
- User context (user ID, email, tenant)
- Request breadcrumbs for debugging
- Performance monitoring (10% of requests sampled)

---

## 2. Slack Security Alerts

Receive Slack notifications for security events like rate limiting and IP blocks.

### Setup Steps

1. **Create a Slack App**
   - Go to [api.slack.com/apps](https://api.slack.com/apps)
   - Click "Create New App" → "From scratch"
   - Name it (e.g., "Harmonic Alerts")
   - Select your workspace

2. **Enable Incoming Webhooks**
   - In your app settings, click "Incoming Webhooks"
   - Toggle "Activate Incoming Webhooks" to **On**

3. **Create a Webhook**
   - Click "Add New Webhook to Workspace"
   - Select the channel for alerts (e.g., #ops-alerts)
   - Click "Allow"

4. **Copy the Webhook URL**
   - Copy the URL (looks like `https://hooks.slack.com/services/T00.../B00.../xxx`)

5. **Add to your production `.env`**
   ```bash
   SLACK_WEBHOOK_URL=https://hooks.slack.com/services/T00.../B00.../xxx
   ```

6. **Restart the application**
   ```bash
   docker compose restart web
   ```

### What Triggers Alerts

- IP addresses blocked by rate limiting
- Rate limiting on authentication endpoints (`/login`, `/password`)
- Any critical severity security events

Alerts include throttling (max 3 identical alerts per 5 minutes) to prevent spam.

---

## 3. Uptime Monitoring

Monitor the `/healthcheck` endpoint to get alerted when the app goes down.

### Setup Steps (UptimeRobot - Free)

1. **Create an account**
   - Go to [uptimerobot.com](https://uptimerobot.com) and sign up (free tier: 50 monitors)

2. **Add a new monitor**
   - Click "Add New Monitor"
   - Type: **HTTP(s)**
   - Friendly Name: "Harmonic Production"
   - URL: `https://yourdomain.com/healthcheck`
   - Monitoring Interval: **5 minutes** (or 1 minute on paid plans)

3. **Configure alerts**
   - Add alert contacts (email, Slack webhook, SMS)
   - Set up a Slack integration for instant notifications

4. **Verify**
   - Check that the monitor shows "Up" status
   - Test by temporarily stopping your app

### What the Healthcheck Monitors

The `/healthcheck` endpoint verifies:
- Database connectivity (runs `SELECT 1`)
- Redis connectivity (runs `PING`)

Returns `200 OK` if healthy, `503 Service Unavailable` if either fails.

### Alternative Services

| Service | Free Tier | Notes |
|---------|-----------|-------|
| [UptimeRobot](https://uptimerobot.com) | 50 monitors, 5-min intervals | Simple, reliable |
| [Better Uptime](https://betterstack.com/uptime) | 10 monitors | Nice Slack integration |
| [Pingdom](https://www.pingdom.com) | None | More features, paid only |

---

## 4. Prometheus Metrics (Optional)

Expose application metrics for scraping by Prometheus or compatible services.

### Setup Steps

1. **Set a metrics auth token**
   ```bash
   # Generate a secure token
   openssl rand -hex 32
   ```

2. **Add to your production `.env`**
   ```bash
   METRICS_AUTH_TOKEN=your-generated-token-here
   ```

3. **Restart the application**
   ```bash
   docker compose restart web
   ```

4. **Verify the endpoint**
   ```bash
   curl -H "Authorization: Bearer your-token" https://yourdomain.com/metrics
   ```

5. **Configure Prometheus to scrape**
   ```yaml
   # prometheus.yml
   scrape_configs:
     - job_name: 'harmonic'
       scheme: https
       bearer_token: 'your-token'
       static_configs:
         - targets: ['yourdomain.com']
   ```

### Available Metrics

**Rails (via yabeda-rails):**
- `rails_requests_total` - Total HTTP requests
- `rails_request_duration_seconds` - Request latency histogram
- `rails_view_runtime_seconds` - View rendering time
- `rails_db_runtime_seconds` - Database query time

**Sidekiq (via yabeda-sidekiq):**
- `sidekiq_jobs_executed_total` - Total jobs executed
- `sidekiq_jobs_failed_total` - Total failed jobs
- `sidekiq_job_runtime_seconds` - Job execution time
- `sidekiq_queue_size` - Current queue depth

**Custom Application Metrics:**
- `harmonic_auth_login_attempts_total` - Login attempts by result
- `harmonic_content_notes_created_total` - Notes created
- `harmonic_security_rate_limited_total` - Rate limited requests
- `harmonic_security_ip_blocked_total` - Blocked IPs

---

## 5. Container Metrics with cAdvisor (Optional)

Monitor container resource usage (CPU, memory, network, disk).

### Setup Steps

1. **Enable the monitoring profile**
   ```bash
   docker compose -f docker-compose.production.yml --profile monitoring up -d
   ```

2. **Access the cAdvisor UI**
   - Open `http://your-server-ip:8080` in your browser
   - Note: Consider restricting access via firewall or reverse proxy

### What cAdvisor Provides

- Real-time CPU usage per container
- Memory usage and limits
- Network I/O statistics
- Disk I/O statistics

---

## 6. Structured Logging (Automatic)

Lograge is automatically enabled in production, outputting JSON-formatted logs.

### Log Format

Each request produces a single JSON line:

```json
{
  "method": "GET",
  "path": "/notes/abc123",
  "status": 200,
  "duration": 45.23,
  "view": 12.34,
  "db": 5.67,
  "request_id": "uuid",
  "tenant_id": "tenant-id",
  "user_id": "user-id",
  "remote_ip": "1.2.3.4"
}
```

### Log Aggregation Services

For centralized log management, consider:

| Service | Setup | Cost |
|---------|-------|------|
| [Papertrail](https://papertrailapp.com) | Easy | $7+/month |
| [Datadog](https://www.datadoghq.com) | Medium | $15+/host/month |
| [Loki + Grafana](https://grafana.com/oss/loki/) | Complex | Self-hosted |

### Security Audit Logs

Security events are logged separately to `log/security_audit.log`:

- `login_success` / `login_failure`
- `password_reset_requested` / `password_changed`
- `rate_limited` / `ip_blocked`
- `admin_action`

View security logs:
```bash
docker compose exec web tail -f log/security_audit.log | jq
```

---

## Environment Variables Reference

| Variable | Required | Description |
|----------|----------|-------------|
| `SENTRY_DSN` | For error tracking | Sentry project DSN |
| `SENTRY_TRACES_SAMPLE_RATE` | No | Performance sampling rate (0.0-1.0, default 0.1) |
| `SLACK_WEBHOOK_URL` | For Slack alerts | Slack incoming webhook URL |
| `ALERT_EMAIL_RECIPIENTS` | For email alerts | Comma-separated email addresses |
| `METRICS_AUTH_TOKEN` | For metrics endpoint | Bearer token for `/metrics` |

---

## Troubleshooting

### Sentry not receiving events

1. Verify `SENTRY_DSN` is set correctly in `.env`
2. Confirm environment is `production` or `staging`
3. Check Rails logs for Sentry initialization errors
4. Test manually: `Sentry.capture_message("Test")`

### Slack alerts not being sent

1. Verify `SLACK_WEBHOOK_URL` is valid
2. Test the webhook directly:
   ```bash
   curl -X POST -H 'Content-type: application/json' \
     --data '{"text":"Test message"}' \
     YOUR_WEBHOOK_URL
   ```
3. Check for throttling (max 3 identical alerts per 5 min)
4. Check Rails logs for `[AlertService]` entries

### Metrics endpoint returns 401/503

1. Ensure `METRICS_AUTH_TOKEN` is set in `.env`
2. Include the token in requests: `Authorization: Bearer <token>`
3. In production without a token, endpoint returns 503

### Health check failing

1. Check database connectivity: `docker compose exec web rails runner "ActiveRecord::Base.connection.execute('SELECT 1')"`
2. Check Redis connectivity: `docker compose exec web rails runner "Redis.new(url: ENV['REDIS_URL']).ping"`
3. Review logs: `docker compose logs web --tail 50`
