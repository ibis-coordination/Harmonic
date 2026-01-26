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
| Multi-tenancy | Database-level tenant isolation |
| File storage | S3-compatible (DO Spaces) with signed URLs |
| Rate limiting | rack-attack on login and API endpoints |
| Container security | Non-root user, network isolation |
| Virus scanning | ClamAV for file uploads (production) |

## Security Checklist

Before going live:

- [ ] `.env` file permissions restricted (`chmod 600 .env`)
- [ ] Database SSL connection enabled (`sslmode=require` in DATABASE_URL)
- [ ] Database IP allowlist configured (if using managed DB)
- [ ] Secrets not in version control
- [ ] Backup restoration tested

## Horizontal Scaling

Harmonic is designed for horizontal scaling:

**Already stateless:**
- Sessions in secure cookies (not server memory)
- File uploads to S3-compatible storage
- Database is external (managed PostgreSQL)
- Background jobs via Redis/Sidekiq
- Cache store uses Redis

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
