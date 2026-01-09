# Production Deployment Guide Plan

This document outlines the plan for creating a comprehensive production deployment guide.

## Goal

Create end-to-end documentation for deploying Harmonic to production, covering all aspects from initial setup to ongoing maintenance.

## Sections to Document

### 1. Prerequisites
- [ ] Required accounts (hosting provider, DNS, email service, etc.)
- [ ] Required environment variables (document all ENV vars from .env.example)
- [ ] Domain and subdomain setup (multi-tenant architecture requires wildcard DNS)
- [ ] SSL certificate requirements

### 2. Infrastructure Setup
- [ ] Docker-based deployment option
- [ ] Non-Docker deployment option (if applicable)
- [ ] Database setup (PostgreSQL)
- [ ] Redis setup (for Sidekiq background jobs)
- [ ] File storage setup (DigitalOcean Spaces or S3-compatible)

### 3. Asset Pipeline

**JavaScript/TypeScript Build** (already documented):
- Node.js 20 required
- Build process: `npm install && npm run build`
- Output: `app/assets/builds/application.js` (with sourcemap)
- jsbundling-rails hooks `npm run build` into `rails assets:precompile`
- Dockerfile already handles this (lines 39-49)

**CSS Assets**:
- [ ] Document CSS build process
- [ ] Sprockets configuration

**Asset Precompilation**:
- [ ] Full precompilation command sequence
- [ ] Verify assets are served correctly

### 4. Database Migrations
- [ ] Migration strategy for zero-downtime deploys
- [ ] Rollback procedures
- [ ] Data backup before migrations

### 5. Environment Configuration
- [ ] AUTH_MODE: oauth vs honor_system
- [ ] HOSTNAME and subdomain configuration
- [ ] Email/SMTP setup (SMTP_SERVER, SMTP_PORT, etc.)
- [ ] OAuth provider setup (if using oauth mode)
- [ ] Rails master key / credentials

### 6. Deployment Process
- [ ] Step-by-step deployment commands
- [ ] Health checks to verify successful deployment
- [ ] Rollback procedure if deployment fails

### 7. Background Jobs
- [ ] Sidekiq configuration
- [ ] Monitoring job queues
- [ ] Handling failed jobs

### 8. Monitoring & Logging
- [ ] Log configuration (RAILS_LOG_TO_STDOUT)
- [ ] Error tracking recommendations
- [ ] Performance monitoring recommendations

### 9. Maintenance
- [ ] Routine maintenance tasks
- [ ] Database backups
- [ ] Log rotation
- [ ] Security updates

### 10. Troubleshooting
- [ ] Common deployment issues and solutions
- [ ] How to access Rails console in production
- [ ] How to view logs

## Research Required

Before writing the guide, investigate:
1. Current production hosting setup (DigitalOcean? Other?)
2. Current deployment method (manual? CI/CD? Platform-specific?)
3. Any existing deployment scripts or documentation
4. Production-specific configurations not in the repo

## Output

Single markdown file: `docs/DEPLOYMENT.md`

## Success Criteria

- [ ] Complete guide covering all sections above
- [ ] Tested by following the guide on a fresh deployment
- [ ] No tribal knowledge required - guide is self-contained
