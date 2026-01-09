# AI Agent Instructions for Harmonic

This document provides context and guidelines for AI coding assistants working on this codebase.

> **Important**: Before making design decisions, read [PHILOSOPHY.md](PHILOSOPHY.md) to understand the values and motivations behind this project.

> **For detailed architecture**: See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for system architecture, data model, and request flow.

## Project Overview

Harmonic is a Ruby on Rails social media application focused on social agency over engagement metrics. It supports multiple tenants (communities) with features for Notes (posts), Decisions (voting), Commitments (group pledges with critical mass), and Cycles (time-based content organization).

## Tech Stack

- **Framework**: Rails 7.0 with Ruby 3.1.7
- **Database**: PostgreSQL
- **Background Jobs**: Sidekiq with Redis
- **Frontend**: Hotwire (Turbo + Stimulus), TypeScript with esbuild
- **File Storage**: Active Storage (S3-compatible)
- **Authentication**: OmniAuth (GitHub), with optional "honor system" mode for development

## Architecture Concepts

### Multi-Tenancy

The app uses subdomain-based multi-tenancy. Key patterns:
- `Current.tenant` and `Current.user` are set via `Thread.current` in `ApplicationController`
- Models use `default_scope { where(tenant: Current.tenant) }` pattern in `ApplicationRecord`
- Routes are duplicated for `/studios/:studio_id/...` and `/scenes/:scene_id/...` paths
- The `Tenant` model represents a community; `Studio` can be type "studio" or "scene"

### Authentication Modes

Configured via `AUTH_MODE` environment variable:
- `oauth`: Full OAuth authentication (production)
- `honor_system`: Simplified auth for development/testing

### Core Domain Models

| Model | Purpose |
|-------|---------|
| `User` | User accounts (types: person, simulated, trustee) |
| `Tenant` | A community/instance of the app |
| `Studio` | Workspaces/groups within a tenant |
| `Note` | Posts/content items |
| `Decision` | Voting items with Options |
| `Commitment` | Group pledges with critical mass thresholds |
| `Cycle` | Time-based organization for content |

### Key Services

- `ApiHelper` (app/services/api_helper.rb) - Central business logic for API operations
- `*ParticipantManager` services - Handle participation in decisions/commitments

## File Organization

```
app/
├── controllers/
│   ├── application_controller.rb  # Auth, tenancy, resource loading (587 lines)
│   ├── api/v1/                    # JSON API controllers
│   └── ...                        # HTML controllers
├── models/
│   ├── concerns/                  # Reusable model behaviors
│   └── ...                        # 30 models
├── services/                      # Business logic services
└── views/                         # ERB templates
```

## API Structure

RESTful JSON API at `/api/v1/` with token-based authentication:
- Tokens have scopes: `read`, `write`
- See `app/controllers/api/v1/` for available endpoints

## Development Commands

```bash
# Start/stop Docker containers
./scripts/start.sh
./scripts/stop.sh

# Rails console
./scripts/rails-c.sh

# Run tests
./scripts/run-tests.sh

# Generate ERD diagram (after bundle install)
bundle exec erd

# Set up git hooks (TODO index checks)
./scripts/setup-hooks.sh
```

## Testing

- Framework: Minitest (Rails default)
- Test files: `test/` directory
- Fixtures: `test/fixtures/`
- Current coverage is low; focus on `test/models/` patterns when adding tests

## Known Patterns & Conventions

### Controllers
- Use `before_action` for authentication and resource loading
- `current_user` and `current_tenant` helpers available
- API controllers inherit from `Api::V1::BaseController`

### Models
- Include concerns from `app/models/concerns/` for shared behaviors
- Use `HasTruncatedId` for public-facing short IDs
- Soft delete via `DeletedRecordProxy` for some models

### Views
- Turbo Frames for partial page updates
- Stimulus controllers in `app/javascript/controllers/`

## Code Style

- Follow Rails conventions
- Use service objects for complex business logic
- Prefer concerns for shared model behavior
- Keep controllers thin, models focused

## Common Tasks

### Adding a new feature
1. Check existing patterns in similar features
2. Add model tests first (see `test/models/note_test.rb` for examples)
3. Use existing concerns where applicable
4. Consider multi-tenancy implications

### Working with the API
1. Check `app/controllers/api/v1/base_controller.rb` for auth patterns
2. See `app/services/api_helper.rb` for business logic
3. Test with `test/integration/api_*_test.rb` patterns

## Areas Needing Attention

- ~50 TODO comments throughout codebase
- Limited test coverage (especially controllers)
- `ApplicationController` and `ApiHelper` are large and could be refactored
- Webhook functionality is stubbed but not implemented (`app/services/webhook_services/`)
