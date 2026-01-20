# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Quick Reference

**For design philosophy and decisions**: Read [PHILOSOPHY.md](PHILOSOPHY.md)
**For architecture details**: Read [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
**For detailed AI agent context**: Read [AGENTS.md](AGENTS.md)
**For codebase patterns comparison**: Read [docs/CODEBASE_PATTERNS.md](docs/CODEBASE_PATTERNS.md)
**For UI styling patterns**: Read [docs/STYLE_GUIDE.md](docs/STYLE_GUIDE.md)
**For Storybook component development**: Read [docs/STORYBOOK.md](docs/STORYBOOK.md)

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

# V2 React Client (in client/ directory)
cd client && npm run dev          # Start Vite dev server
cd client && npm run storybook    # Start Storybook at localhost:6006
cd client && npm test             # Run Vitest tests
cd client && npm run typecheck    # TypeScript type check
cd client && npm run lint         # Run ESLint
cd client && npm run lint:fix     # Run ESLint with auto-fix
cd client && npm run check        # Run lint + typecheck together
```

## Code Style

### Ruby (Backend)
- **Strings**: Use double quotes (`"string"`)
- **Arrays/Hashes**: Use trailing commas in multiline literals
- **Line length**: Max 150 characters
- **Linter**: RuboCop with configuration in `.rubocop.yml`

### TypeScript/React (V2 Client)
- **Linter**: ESLint with strict functional programming rules
- **Functional programming**: Strictly enforced via `eslint-plugin-functional`
  - No classes (`functional/no-classes`)
  - No `let` declarations (`functional/no-let`) - use `const` only
  - No loops (`functional/no-loop-statements`) - use `map`, `filter`, `reduce`
  - No `throw` statements (`functional/no-throw-statements`) - use Effect.js `Effect.fail`
  - Immutable data (`functional/immutable-data`) - no mutations except React refs
- **Error handling**: Use Effect.js tagged unions, not classes
- **Pre-commit hooks**: Husky runs lint-staged on TypeScript files
- **Configuration**: `client/eslint.config.js`

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

### V2 React Client

A modern React frontend in `client/` using:
- **Vite** - Build tool and dev server
- **TanStack Router** - Type-safe routing
- **TanStack Query** - Data fetching and caching
- **Tailwind CSS** - Utility-first styling
- **Storybook** - Component development and documentation
- **Effect.js** - Functional error handling and effects
- **ESLint** - Strict functional programming enforcement

Component development workflow:
1. Create component in `client/src/components/`
2. Add story in `ComponentName.stories.tsx`
3. Develop in isolation with `npm run storybook`
4. Add tests in `ComponentName.test.tsx`
5. Run `npm run check` before committing

## Testing

### Backend (Ruby)
- Framework: Minitest
- Coverage threshold: 45% line, 25% branch (CI enforces this)
- Test helpers: `create_tenant_studio_user`, `create_note`, `create_decision`, etc. in `test/test_helper.rb`
- Integration tests use `sign_in_as(user, tenant:)` helper

### Frontend (TypeScript - Legacy V1)
- Framework: Vitest with jsdom
- Test files: `app/javascript/**/*.test.ts`
- Run tests: `docker compose exec js npm test`
- Watch mode: `docker compose exec js npm run test:watch`

### Frontend (TypeScript - V2 React Client)
- Framework: Vitest with jsdom and React Testing Library
- Test files: `client/src/**/*.test.ts`, `client/src/**/*.test.tsx`
- Run tests: `cd client && npm test`
- Watch mode: `cd client && npm run test:watch`
- Linting: `cd client && npm run lint`

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
- Active plans: `.claude/plans/v2-ui-implementation.md`
- Completed plans: `.claude/plans/completed/YYYY/MM/PLAN_NAME.md`
- Plans should document goals, architecture decisions, and implementation phases
- When a plan is completed, move it to the appropriate `completed/YYYY/MM/` subdirectory
