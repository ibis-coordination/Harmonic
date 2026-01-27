# Security and Scaling Gaps Plan

## Goal

Address the security and scaling gaps identified in the review of `docs/SECURITY_AND_SCALING.md`.

## Items to Address

### Code Changes

1. **API rate limiting** - Add general API endpoint throttling to rack-attack
2. **Security audit logging** - Add logging for security-relevant events
3. **Redis authentication** - Add password protection for Redis in production
4. **Container resource limits** - Add memory/CPU limits to production docker-compose

### Documentation Updates

5. **Update SECURITY_AND_SCALING.md** with:
   - SECRET_KEY_BASE caveat for horizontal scaling
   - Secret rotation procedures
   - Dependency vulnerability scanning recommendations
   - Log monitoring/alerting recommendations
   - CSP unsafe-inline acknowledgment

### Deferred/Out of Scope

- CSP nonces for styles (requires significant view changes, acknowledged as TODO in code)
- WAF setup (infrastructure-specific, document as recommendation)

## Implementation

### Phase 1: Code Changes

#### 1.1 API Rate Limiting
Add to `config/initializers/rack_attack.rb`:
- General API throttle (e.g., 100 requests/minute per IP)
- Burst protection for all endpoints

#### 1.2 Security Audit Logging
Create `app/services/security_audit_log.rb`:
- Log failed login attempts
- Log successful logins
- Log permission changes
- Log admin actions

#### 1.3 Redis Authentication
Update `docker-compose.production.yml`:
- Add Redis password via environment variable
- Update REDIS_URL format in documentation

#### 1.4 Container Resource Limits
Update `docker-compose.production.yml`:
- Add deploy.resources.limits for web container
- Add deploy.resources.limits for sidekiq container

### Phase 2: Documentation

Update `docs/SECURITY_AND_SCALING.md` with all missing items.

## Status

- [x] 1.1 API rate limiting
- [x] 1.2 Security audit logging
- [x] 1.3 Redis authentication
- [x] 1.4 Container resource limits
- [x] 2.1 Documentation updates

## Completed

All items have been addressed. See the following files for changes:

- `config/initializers/rack_attack.rb` - General API throttling, security audit log integration
- `app/services/security_audit_log.rb` - New security audit logging service
- `app/controllers/sessions_controller.rb` - Login/logout audit logging
- `app/controllers/password_resets_controller.rb` - Password reset audit logging
- `docker-compose.production.yml` - Redis auth, container resource limits
- `docs/SECURITY_AND_SCALING.md` - Comprehensive documentation updates
- `.env.example` - REDIS_PASSWORD variable
