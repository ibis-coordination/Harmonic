# Monitoring and Alerting Implementation Plan

## Goal

Implement comprehensive monitoring and alerting for the Harmonic application to enable proactive issue detection, security event tracking, and operational visibility in production.

## Current State

The app already has:
- Health check endpoint at `/healthcheck` (DB + Redis checks)
- Security audit logging in JSON format (`app/services/security_audit_log.rb`)
- Rate limiting with event logging via Rack::Attack
- Rails logs to stdout (Docker-friendly)
- Container resource limits in production

## Implementation Phases

### Phase 1: Error Tracking with Sentry

Add Sentry for capturing unhandled exceptions with full context.

**Tasks:**
- [ ] 1.1 Add Sentry gems to Gemfile
- [ ] 1.2 Create Sentry initializer with configuration
- [ ] 1.3 Add SENTRY_DSN to environment variables
- [ ] 1.4 Configure Sentry context (user, tenant, request)
- [ ] 1.5 Add Sidekiq integration for background job errors
- [ ] 1.6 Update documentation

### Phase 2: Alert Service

Create an internal alert service for security and operational events.

**Tasks:**
- [ ] 2.1 Create AlertService with Slack webhook support
- [ ] 2.2 Add email alert fallback
- [ ] 2.3 Integrate with SecurityAuditLog for high-severity events
- [ ] 2.4 Add alert throttling to prevent spam
- [ ] 2.5 Add tests for AlertService

### Phase 3: Application Metrics

Add Prometheus-compatible metrics for application performance monitoring.

**Tasks:**
- [ ] 3.1 Add yabeda gems for Rails and Sidekiq metrics
- [ ] 3.2 Configure custom metrics (login attempts, decisions created, etc.)
- [ ] 3.3 Add /metrics endpoint (protected)
- [ ] 3.4 Document metrics available

### Phase 4: Log Aggregation Configuration

Configure structured logging for easier aggregation by external services.

**Tasks:**
- [ ] 4.1 Add lograge gem for structured request logging
- [ ] 4.2 Configure JSON log format for production
- [ ] 4.3 Add request ID tracking
- [ ] 4.4 Document log aggregation setup options

### Phase 5: Container Monitoring

Add container-level metrics and health monitoring.

**Tasks:**
- [ ] 5.1 Add cAdvisor service to docker-compose.production.yml
- [ ] 5.2 Configure container labels for monitoring
- [ ] 5.3 Document container monitoring setup

### Phase 6: Documentation

Update documentation with monitoring setup guides.

**Tasks:**
- [ ] 6.1 Create docs/MONITORING.md with setup guides
- [ ] 6.2 Update SECURITY_AND_SCALING.md with monitoring references
- [ ] 6.3 Add environment variable documentation

## Technical Details

### Phase 1: Sentry Configuration

```ruby
# Gemfile additions
gem "sentry-ruby"
gem "sentry-rails"
gem "sentry-sidekiq"

# config/initializers/sentry.rb
Sentry.init do |config|
  config.dsn = ENV["SENTRY_DSN"]
  config.breadcrumbs_logger = [:active_support_logger, :http_logger]
  config.traces_sample_rate = 0.1
  config.profiles_sample_rate = 0.1
  config.environment = Rails.env
  config.enabled_environments = %w[production staging]

  config.before_send = lambda do |event, hint|
    # Filter sensitive data
    event
  end
end
```

### Phase 2: Alert Service Design

```ruby
# app/services/alert_service.rb
class AlertService
  SEVERITY_LEVELS = %i[info warning critical].freeze

  class << self
    def notify(message, severity: :warning, context: {})
      return unless should_alert?(severity)

      payload = build_payload(message, severity, context)
      send_to_slack(payload) if slack_configured?
      send_email(payload) if email_configured? && severity == :critical
    end
  end
end
```

Alert triggers:
- `ip_blocked` events → immediate Slack alert
- 5+ `login_failure` from same IP in 5 minutes → warning
- `rate_limited` on auth endpoints → warning
- Any unhandled exception (via Sentry) → based on frequency

### Phase 3: Metrics to Track

Application metrics:
- `harmonic_requests_total` - Total HTTP requests by endpoint, status
- `harmonic_request_duration_seconds` - Request latency histogram
- `harmonic_login_attempts_total` - Login attempts by result (success/failure)
- `harmonic_decisions_total` - Decisions created
- `harmonic_commitments_total` - Commitments created
- `harmonic_active_users` - Currently active users (gauge)

Sidekiq metrics (via yabeda-sidekiq):
- Queue depth
- Job execution time
- Job success/failure rates

### Phase 4: Lograge Configuration

```ruby
# config/initializers/lograge.rb
Rails.application.configure do
  config.lograge.enabled = true
  config.lograge.formatter = Lograge::Formatters::Json.new
  config.lograge.custom_payload do |controller|
    {
      tenant_id: Tenant.current_id,
      user_id: controller.current_user&.id,
      request_id: controller.request.request_id
    }
  end
end
```

## Environment Variables

New variables to add:
- `SENTRY_DSN` - Sentry project DSN
- `SLACK_WEBHOOK_URL` - Slack incoming webhook for alerts
- `ALERT_EMAIL_RECIPIENTS` - Comma-separated email addresses for critical alerts
- `METRICS_AUTH_TOKEN` - Token for /metrics endpoint authentication

## Testing Strategy

- Unit tests for AlertService
- Integration tests for Sentry context capture
- Test alert throttling logic
- Verify metrics increment correctly

## Rollout Plan

1. Deploy Phase 1 (Sentry) first - immediate value with minimal risk
2. Deploy Phase 2 (AlertService) - enables proactive alerting
3. Deploy Phase 3-4 (Metrics/Logging) - enables dashboards
4. Deploy Phase 5 (Container monitoring) - infrastructure visibility
5. Complete Phase 6 (Documentation) throughout

## Success Criteria

- All unhandled exceptions are captured in Sentry
- Security events trigger appropriate alerts
- Request latency and error rates are visible via metrics
- Logs are structured and ready for aggregation
- Documentation enables self-service setup

## Status

- [x] Phase 1: Error Tracking with Sentry
- [x] Phase 2: Alert Service
- [x] Phase 3: Application Metrics
- [x] Phase 4: Log Aggregation Configuration
- [x] Phase 5: Container Monitoring
- [x] Phase 6: Documentation

## Implementation Summary

All phases have been implemented. Files created/modified:

**New Files:**
- `app/services/alert_service.rb` - Security event alerting to Slack/email
- `app/controllers/metrics_controller.rb` - Prometheus metrics endpoint
- `config/initializers/sentry.rb` - Sentry error tracking configuration
- `config/initializers/lograge.rb` - Structured JSON logging
- `config/initializers/yabeda.rb` - Application metrics definitions
- `docs/MONITORING.md` - Comprehensive monitoring setup guide
- `test/services/alert_service_test.rb` - AlertService tests

**Modified Files:**
- `Gemfile` - Added sentry-ruby, sentry-rails, sentry-sidekiq, lograge, yabeda gems
- `app/controllers/application_controller.rb` - Added Sentry context
- `app/services/security_audit_log.rb` - Added AlertService integration
- `config/initializers/rack_attack.rb` - Use new log_ip_blocked method
- `config/routes.rb` - Added /metrics route
- `docker-compose.production.yml` - Added optional cAdvisor service
- `docs/SECURITY_AND_SCALING.md` - Added monitoring references
- `.env.example` - Added monitoring environment variables

**Testing Note:**
Tests could not be run due to disk space constraints. Run `./scripts/run-tests.sh` after freeing disk space.
