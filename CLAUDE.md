# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Quick Reference

**For design philosophy and decisions**: Read [PHILOSOPHY.md](PHILOSOPHY.md)
**For architecture details**: Read [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
**For detailed AI agent context**: Read [AGENTS.md](AGENTS.md)
**For codebase patterns comparison**: Read [docs/CODEBASE_PATTERNS.md](docs/CODEBASE_PATTERNS.md)
**For UI styling patterns**: Read [docs/STYLE_GUIDE.md](docs/STYLE_GUIDE.md)

## Common Commands

All commands run inside Docker containers. The app must be running first.

```bash
# Start/stop the app
./scripts/start.sh
./scripts/stop.sh

# Run all tests
./scripts/run-tests.sh

# Run a single test file
docker compose exec web bundle exec rails test test/models/note_test.rb

# Run a specific test by line number
docker compose exec web bundle exec rails test test/models/note_test.rb:42

# Run a specific test by name
docker compose exec web bundle exec rails test test/models/note_test.rb -n test_method_name

# Run tests with coverage report
docker compose exec web env COVERAGE=true bundle exec rails test

# Rails console
./scripts/rails-c.sh

# Run RuboCop linter
docker compose exec web bundle exec rubocop

# Auto-fix RuboCop issues
docker compose exec web bundle exec rubocop -a

# Run Sorbet type checker
docker compose exec web bundle exec srb tc

# Run TypeScript type checker
docker compose exec js npm run typecheck

# Run frontend tests
docker compose exec js npm test

# Generate ERD diagram
./scripts/generate-erd.sh
```

## Code Style

### Ruby (Backend)
- **Strings**: Use double quotes (`"string"`)
- **Arrays/Hashes**: Use trailing commas in multiline literals
- **Line length**: Max 150 characters
- **Linter**: RuboCop with configuration in `.rubocop.yml`

## Architecture Overview

**Tech stack**: Rails 7.0, Ruby 3.1.7, PostgreSQL, Redis/Sidekiq, Hotwire (Turbo + Stimulus)

### Multi-Tenancy Pattern

Subdomain-based multi-tenancy using thread-local variables:
- `Tenant.current_id` and `Superagent.current_id` are set via thread-local variables
- Models use `default_scope { where(tenant_id: Tenant.current_id, superagent_id: Superagent.current_id) }` pattern in `ApplicationRecord`
- New records auto-populate `tenant_id` and `superagent_id` via `before_validation`


### Core Domain Models (OODA Loop)

| Model | Purpose | OODA Phase |
|-------|---------|------------|
| `Note` | Posts/content | Observe |
| `Decision` | Acceptance voting | Decide |
| `Commitment` | Action pledges with critical mass | Act |
| `Cycle` | Time-bounded activity windows | Orient |
| `Link` | Bidirectional references | Orient |

### Shared Model Concerns

- `HasTruncatedId` - Short 8-char IDs for URLs (e.g., `/n/a1b2c3d4`)
- `Linkable` - Bidirectional linking between content
- `Pinnable` - Content can be pinned to studio
- `Attachable` - File attachments
- `Commentable` - Comments (which are Notes)

### Key Services

- `ApiHelper` (app/services/api_helper.rb) - Central business logic for CRUD operations
- `DecisionParticipantManager` / `CommitmentParticipantManager` - Participation logic

### Dual Interface Pattern

The app serves two parallel interfaces:
1. HTML/browser UI for humans
2. Markdown + API actions for LLMs (same routes with `Accept: text/markdown`)

## Testing

### Backend (Ruby)
- Framework: Minitest
- Coverage threshold: 45% line, 25% branch (CI enforces this)
- Test helpers: `create_tenant_studio_user`, `create_note`, `create_decision`, etc. in `test/test_helper.rb`
- Integration tests use `sign_in_as(user, tenant:)` helper

### Frontend (TypeScript)
- Framework: Vitest with jsdom
- Test files: `app/javascript/**/*.test.ts`
- Run tests: `docker compose exec js npm test`
- Watch mode: `docker compose exec js npm run test:watch`

### End-to-End (Playwright)
- Framework: Playwright
- Test files: `e2e/tests/**/*.spec.ts`
- Requires: App running with `AUTH_MODE=honor_system`
- Run tests: `npm run test:e2e` or `./scripts/run-e2e.sh`
- Run with UI: `npm run test:e2e:ui`
- Run headed: `npm run test:e2e:headed`
- Run specific test: `npm run test:e2e -- e2e/tests/auth/login.spec.ts`
- Install browsers: `npm run playwright:install`

### Manual testing
- Framework: checklists
- Instruction/checklist files: `test/manual/**/*.manual_test.md`
- Run tests: use MCP server to connect to the app's markdown UI, follow instructions in test file, verify checklist items

### Playwright MCP Browser Testing
When using the Playwright MCP tools to interact with the app in a browser:
- **Base URL**: Always use `https://app.harmonic.local` as the base domain
- The app uses subdomain-based multi-tenancy, so `localhost:3000` will not work
- **Do NOT use honor_system auth mode** - the e2e tests show how to properly log in

**Setup (run once if needed):**
```bash
docker compose exec web bundle exec rake e2e:setup
```
This creates a test user with identity provider authentication.

**Login credentials:**
- Email: `e2e-test@example.com` (or `E2E_TEST_EMAIL` env var)
- Password: `e2e-test-password-14chars` (or `E2E_TEST_PASSWORD` env var)

**Login flow:**
1. Navigate to `https://app.harmonic.local/login`
2. Wait for redirect to auth subdomain
3. Fill `input[name="auth_key"]` with email
4. Fill `input[name="password"]` with password
5. Click the Log in button
6. Wait for redirect back to app subdomain

**Reference:** See `e2e/helpers/auth.ts` for the canonical login implementation and `e2e/tests/` for examples.

## Environment Variables

Key variables (see `.env.example`):
- `AUTH_MODE`: `oauth` (production) or `honor_system` (development)
- `HOSTNAME`: Base domain
- `PRIMARY_SUBDOMAIN`: Main tenant subdomain

## TODO Management

When modifying TODO comments, update `docs/TODO_INDEX.md`:
```bash
./scripts/check-todo-index.sh --list   # See all TODOs
./scripts/check-todo-index.sh --all    # Check sync status
```

## Plan Documents

When creating implementation plans, store them in `.claude/plans/` with descriptive names:
- Active plans: `.claude/plans/PLAN_NAME.md`
- Completed plans: `.claude/plans/completed/YYYY/MM/PLAN_NAME.md`
- Plans should document goals, architecture decisions, and implementation phases
- When a plan is completed, move it to the appropriate `completed/YYYY/MM/` subdirectory

## Other

Do not use the term "pre-existing" when you encounter failing tests or failing type checks. If there are failures, those failures must be addressed properly.
