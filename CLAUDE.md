# CLAUDE.md

This file provides guidance to Claude Code when working with code in this repository.

## Related Docs

- [PHILOSOPHY.md](PHILOSOPHY.md) — Design philosophy and decisions
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — Architecture details
- [docs/STYLE_GUIDE.md](docs/STYLE_GUIDE.md) — UI styling patterns (live reference at `/dev/styleguide`)
- [docs/AGENT_RUNNER.md](docs/AGENT_RUNNER.md) — Agent-runner service
- [docs/AUTOMATIONS.md](docs/AUTOMATIONS.md) — Automation system

## Common Commands

All commands run inside Docker containers. The app must be running first (`./scripts/start.sh` / `./scripts/stop.sh`).

```bash
# Tests
./scripts/run-tests.sh                                                    # All tests
docker compose exec web bundle exec rails test test/models/note_test.rb   # Single file
docker compose exec web bundle exec rails test test/models/note_test.rb:42  # Specific test
docker compose exec js npm test                                           # Frontend tests

# Code quality
docker compose exec web bundle exec rubocop          # Linter (rubocop -a to auto-fix)
docker compose exec web bundle exec srb tc            # Sorbet type checker
docker compose exec js npm run typecheck              # TypeScript type checker

# Utilities
./scripts/rails-c.sh                                  # Rails console
./scripts/generate-erd.sh                             # ERD diagram

# Agent-runner (from agent-runner/ directory)
cd agent-runner && npm test && npm run typecheck && npm run build
```

## Code Style (Ruby)

- Double quotes, trailing commas in multiline literals, max 150 char lines
- RuboCop config in `.rubocop.yml`

## Architecture

**Tech stack**: Rails 7.2, Ruby 3.3.7, PostgreSQL, Redis/Sidekiq, Hotwire (Turbo + Stimulus)

### Multi-Tenancy

Subdomain-based multi-tenancy via thread-local `Tenant.current_id` and `Collective.current_id`. Models auto-scope queries and auto-populate IDs on new records via `ApplicationRecord`.

**Direct `.unscoped` calls are banned.** Use safe alternatives:

| Method | Use Case |
|--------|----------|
| `Model.tenant_scoped_only(tenant_id)` | Cross-collective access within a tenant |
| `Model.unscoped_for_admin(user)` | Admin operations (requires admin role) |
| `Model.unscoped_for_system_job` | Background jobs (requires nil tenant) |
| `Model.for_user_across_tenants(user)` | User's own data across tenants |

Models without tenant scoping: `User`, `Tenant`, `OauthIdentity`, `OmniAuthIdentity`, `StripeCustomer`

### Authentication

Configured via `AUTH_MODE` env var: `oauth` (production) or `honor_system` (development only — blocked in production). Session timeouts: 24-hour absolute, 2-hour idle (configurable via `SESSION_ABSOLUTE_TIMEOUT`, `SESSION_IDLE_TIMEOUT`). TOTP 2FA available for email/password users. User types: `human`, `ai_agent`, `collective_identity` (see [docs/USER_TYPES.md](docs/USER_TYPES.md)).

### Core Domain Models

| Model | Purpose | | Model | Purpose |
|-------|---------|--|-------|---------|
| `Note` | Posts/content | | `Cycle` | Time-bounded activity windows |
| `Decision` | Acceptance voting | | `Link` | Bidirectional references |
| `Commitment` | Action pledges with critical mass | | | |

Shared concerns: `HasTruncatedId`, `Linkable`, `Pinnable`, `Attachable`, `Commentable`

### Dual Interface

The app serves HTML for humans and Markdown + API actions for LLMs (same routes, `Accept: text/markdown`). RESTful JSON API at `/api/v1/` with token-based auth (scopes: `read`, `write`).

## Testing

- **Backend**: Minitest. Helpers in `test/test_helper.rb` (`create_tenant_collective_user`, `sign_in_as`, etc.). Coverage: 45% line / 25% branch minimum.
- **Frontend**: Vitest with jsdom. Files: `app/javascript/**/*.test.ts`
- **E2E**: Playwright. Files: `e2e/tests/**/*.spec.ts`. Run: `./scripts/run-e2e.sh`
- **Manual**: Checklists in `test/manual/**/*.manual_test.md`

### Playwright MCP Browser Testing

Base URL: `https://app.harmonic.local` (not localhost — subdomain-based tenancy).

**Setup:** `docker compose exec web bundle exec rake e2e:setup`

**Login:** Navigate to `/login`, fill `input[name="auth_key"]` with `e2e-test@example.com`, `input[name="password"]` with `e2e-test-password-14chars`, click Log in. See `e2e/helpers/auth.ts` for reference.

## Static Analysis

These run in pre-commit hooks and CI:

```bash
./scripts/check-tenant-safety.sh    # Banned .unscoped usage
./scripts/check-debug-code.sh       # Debug code (binding.pry, console.log, etc.)
./scripts/check-secrets.sh          # Potential secrets/API keys
./scripts/check-style-guide.sh      # Hardcoded colors / naming in Pulse CSS
./scripts/check-job-inheritance.sh  # Job base class inheritance
```

## Environment Variables

See `.env.example`. Key vars: `AUTH_MODE` (oauth/honor_system), `HOSTNAME`, `PRIMARY_SUBDOMAIN`.

## Plan Documents

Store in `.claude/plans/`. Move completed plans to `.claude/plans/completed/YYYY/MM/`.

## Destructive Operations

**NEVER delete the database or Docker volumes without explicit user confirmation.** This includes `docker compose down -v`, `docker volume rm` on database volumes, and `rails db:drop`. Target specific volumes when fixing issues (e.g., `docker volume rm harmonicteam_gem_cache`).

## Other

Do not use the term "pre-existing" when you encounter failing tests or failing type checks. If there are failures, those failures must be addressed properly.
