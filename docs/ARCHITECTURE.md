# Harmonic Architecture

This document describes the technical architecture of Harmonic. For design philosophy and motivations, see [PHILOSOPHY.md](../PHILOSOPHY.md).

## System Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                           Client Layer                               │
├─────────────────┬─────────────────────┬─────────────────────────────┤
│  Browser (HTML) │  LLM (Markdown+API) │     REST API (JSON)         │
└────────┬────────┴──────────┬──────────┴──────────────┬──────────────┘
         │                   │                         │
         ▼                   ▼                         ▼
┌─────────────────────────────────────────────────────────────────────┐
│                      Rails Application                               │
├─────────────────────────────────────────────────────────────────────┤
│  ApplicationController (auth, tenancy, resource loading)            │
│  ├── HTML Controllers (Turbo/Stimulus)                              │
│  └── Api::V1::BaseController (JSON/Markdown API)                    │
├─────────────────────────────────────────────────────────────────────┤
│  Services Layer                                                      │
│  ├── ApiHelper (business logic)                                     │
│  ├── MarkdownUiService (internal markdown UI for AI agents)         │
│  ├── *ParticipantManager (participation logic)                      │
│  └── LinkParser, MarkdownRenderer, etc.                             │
├─────────────────────────────────────────────────────────────────────┤
│  Models (ActiveRecord)                                               │
│  └── Scoped by Tenant + Collective via Thread.current               │
└────────┬────────────────────────────────────────────────────────────┘
         │
         ▼
┌─────────────────────────────────────────────────────────────────────┐
│  PostgreSQL                │  Redis (Sidekiq)  │  S3 (Active Storage)│
└─────────────────────────────────────────────────────────────────────┘
```

## Multi-Tenancy Architecture

Harmonic uses **subdomain-based multi-tenancy**. Each tenant is an independent community with its own data.

### How It Works

1. **Request arrives** with subdomain (e.g., `acme.harmonic.example.com`)
2. **`ApplicationController#current_tenant`** calls `Collective.scope_thread_to_collective`
3. **Thread-local variables** are set:
   - `Thread.current[:tenant_id]`
   - `Thread.current[:collective_id]`
4. **`ApplicationRecord` default_scope** filters all queries:
   ```ruby
   default_scope do
     if belongs_to_tenant? && Tenant.current_id
       where(tenant_id: Tenant.current_id)
     end
   end
   ```
5. **New records** automatically get `tenant_id` and `collective_id` via `before_validation`

### Key Classes

| Class | Responsibility |
|-------|---------------|
| `Tenant` | Community/instance. Has subdomain, settings, users |
| `Collective` | Group within tenant. Can be "studio" (private) or "scene" (public) |
| `TenantUser` | User membership in a tenant |
| `CollectiveMember` | User membership in a collective (with roles) |

### Thread Safety

Tenant/collective context is stored in `Thread.current`. This works because:
- Each Rails request runs in its own thread
- Context is set at the start of each request in `ApplicationController`
- Context is cleared after request completes

### Tenant Safety: Banned `.unscoped` Usage

Direct `.unscoped` calls are **banned** to prevent accidental cross-tenant data leaks. Instead, use these safe wrapper methods defined in `ApplicationRecord`:

```ruby
# Cross-collective access within the same tenant
Model.tenant_scoped_only(tenant_id)
# Runtime check: raises if tenant_id is nil (defaults to Tenant.current_id)

# Admin operations (app_admin or sys_admin users only)
Model.unscoped_for_admin(current_user)
# Runtime check: raises unless user.app_admin? || user.sys_admin?

# Background jobs running outside request context
Model.unscoped_for_system_job
# Runtime check: raises unless Tenant.current_id.nil?

# User's own data across all tenants (e.g., viewing own memberships)
Model.for_user_across_tenants(user)
# Runtime check: raises if user is nil or model lacks user_id column
```

**Models without tenant scoping** (no restrictions apply):
- `User` - Global user accounts
- `Tenant` - Tenants themselves
- `OauthIdentity` - OAuth provider identities
- `OmniAuthIdentity` - OmniAuth provider identities

**Enforcement**:
- Static analysis: `./scripts/check-tenant-safety.sh` detects banned `.unscoped` usage
- Pre-commit hook: Blocks commits with banned patterns
- CI: Fails builds with banned patterns

## Data Model

### Core Entities (OODA Loop Mapping)

```
┌─────────────┐     ┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│   Note      │     │   Cycle     │     │  Decision   │     │ Commitment  │
│  (Observe)  │     │  (Orient)   │     │  (Decide)   │     │   (Act)     │
└──────┬──────┘     └──────┬──────┘     └──────┬──────┘     └──────┬──────┘
       │                   │                   │                   │
       │                   │                   │                   │
       └───────────────────┴───────────────────┴───────────────────┘
                                    │
                                    ▼
                              ┌───────────┐
                              │   Link    │
                              │ (Orient)  │
                              └───────────┘
```

### Entity Details

#### Note
Posts/content items. Maps to "Observe" in OODA.

```ruby
Note
├── belongs_to :tenant, :studio, :created_by, :updated_by
├── has_many :note_history_events  # read confirmations, edits
├── includes Linkable, Pinnable, Attachable, Commentable
└── has truncated_id for short URLs (e.g., /n/a1b2c3d4)
```

#### Decision
Group decisions via acceptance voting. Maps to "Decide" in OODA.

```ruby
Decision
├── belongs_to :tenant, :studio, :created_by, :updated_by
├── has_many :options              # choices to vote on
├── has_many :decision_participants
├── has_many :votes                # votes (through participants/options)
└── includes Linkable, Pinnable, Attachable, Commentable
```

#### Commitment
Action pledges with critical mass thresholds. Maps to "Act" in OODA.

```ruby
Commitment
├── belongs_to :tenant, :studio, :created_by, :updated_by
├── has_many :participants (CommitmentParticipant)
├── critical_mass: integer         # threshold to activate
├── limit: integer                 # optional max participants
└── includes Linkable, Pinnable, Attachable, Commentable
```

#### Cycle
Time-bounded activity windows. Maps to "Orient" in OODA.

```ruby
Cycle  # Not a database table - computed from dates
├── name: string (e.g., "today", "this-week", "this-month")
├── start_date, end_date
├── computed notes, decisions, commitments within window
└── scoped to studio tempo setting
```

#### Link
Bidirectional references between content. Maps to "Orient" in OODA.

```ruby
Link
├── belongs_to :from_linkable, polymorphic: true
├── belongs_to :to_linkable, polymorphic: true
├── created automatically when content references other content
└── scoped to same tenant and studio
```

### Supporting Entities

| Entity | Purpose |
|--------|---------|
| `User` | User account (types: human, ai_agent, collective_proxy) |
| `Heartbeat` | Periodic presence signal for collective access |
| `RepresentationSession` | When user acts on behalf of a collective |
| `ApiToken` | Token for API authentication |
| `Attachment` | File attached to notes/decisions/commitments |
| `Invite` | Invitation to join a collective |

### Model Concerns

Shared behaviors extracted into concerns:

| Concern | Purpose | Used By |
|---------|---------|---------|
| `HasTruncatedId` | Short 8-char IDs for URLs | Note, Decision, Commitment |
| `Linkable` | Bidirectional linking | Note, Decision, Commitment |
| `Pinnable` | Can be pinned to collective | Note, Decision, Commitment |
| `Attachable` | File attachments | Note, Decision, Commitment |
| `Commentable` | Comments (which are Notes) | Note, Decision, Commitment |
| `Tracked` | Webhook tracking (stubbed) | Note, Decision, Commitment |
| `HasImage` | Profile/collective images | User, Collective |
| `CanPin` | Can pin other items | Collective |

## Authentication

Configured via `AUTH_MODE` environment variable:

### OAuth Mode (`AUTH_MODE=oauth`)
Production authentication:
1. User clicks login → redirected to OAuth provider (GitHub)
2. Provider redirects back with auth code
3. `SessionsController#oauth_callback` creates/finds user
4. Session stored in cookie

### Honor System Mode (`AUTH_MODE=honor_system`)
Development/testing authentication:
1. User enters email on login form
2. `HonorSystemSessionsController` finds/creates user by email
3. Session stored in cookie

### API Token Authentication
For programmatic access:
1. Token passed in `Authorization: Bearer <token>` header
2. `ApplicationController#current_token` validates token
3. Token has scopes: `read`, `write`
4. Token scoped to tenant

## Request Flow

### HTML Request
```
1. Request: GET /studios/myteam/n/a1b2c3d4
2. ApplicationController before_actions:
   ├── current_tenant (set Thread.current[:tenant_id])
   ├── current_studio (set Thread.current[:studio_id])
   ├── current_user (authenticate)
   └── current_resource (load note)
3. NotesController#show
4. Render ERB view with Turbo Frame
```

### API Request
```
1. Request: GET /api/v1/notes/a1b2c3d4
   Headers: Authorization: Bearer <token>, Accept: application/json
2. ApplicationController before_actions (same as HTML)
3. Api::V1::BaseController#api_authorize!
4. Api::V1::NotesController#show
5. Render JSON response
```

### Markdown/LLM Request
```
1. Request: GET /studios/myteam/n/a1b2c3d4
   Headers: Authorization: Bearer <token>, Accept: text/markdown
2. Same flow as HTML, but renders .md.erb template
3. Response includes available API actions
```

## Services Layer

### ApiHelper
Central business logic for creating/updating resources.

```ruby
ApiHelper.new(
  current_user:, current_studio:, current_tenant:,
  current_resource_model:, params:, request:
)
```

Methods:
- `create` - creates Note, Decision, or Commitment
- `create_studio`, `create_scene`
- `create_heartbeat`
- `confirm_read!` (for notes)
- `join_commitment!`
- `vote!` (for decisions)

### Participant Managers
Handle participation logic:
- `DecisionParticipantManager` - voting
- `CommitmentParticipantManager` - joining commitments

### MarkdownUiService
Renders the markdown UI without requiring a controller/HTTP request context.
Enables AI agents to navigate the app internally from chat sessions.

```ruby
service = MarkdownUiService.new(tenant: tenant, collective: collective, user: user)
result = service.navigate("/studios/team")
result = service.execute_action("create_note", { text: "Hello" })
```

Components:
- `MarkdownUiService` - main service with `navigate`, `set_path`, `execute_action`
- `ViewContext` - provides template instance variables
- `ResourceLoader` - loads resources based on routes
- `ActionExecutor` - executes actions via ApiHelper

See [docs/plans/MARKDOWN_UI_SERVICE_PLAN.md](plans/MARKDOWN_UI_SERVICE_PLAN.md) for full documentation.

### Other Services
- `LinkParser` - parses content for links to other content
- `MarkdownRenderer` - renders markdown to HTML
- `DataMarkdownSerializer` - serializes data for markdown views
- `DataDeletionManager` - handles data deletion
- `ActionsHelper` - describes available API actions for LLM interface

## LLM Services (Optional)

Harmonic includes optional LLM-powered features. These run as separate Docker services under the `llm` profile.

### Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│  Rails Application                                                   │
│  ├── TrioController (/trio)                                           │
│  └── TrioClient (app/services/trio_client.rb)                       │
└────────┬────────────────────────────────────────────────────────────┘
         │ HTTP (OpenAI-compatible API)
         ▼
┌─────────────────────────────────────────────────────────────────────┐
│  Trio (port 8000)                                                    │
│  Voting ensemble service - queries multiple models, picks best      │
└────────┬────────────────────────────────────────────────────────────┘
         │
         ▼
┌─────────────────────────────────────────────────────────────────────┐
│  LiteLLM (port 4000)                                                 │
│  Unified gateway - routes to Ollama, Claude, OpenAI, etc.           │
└────────┬────────────────────────────────────────────────────────────┘
         │
         ▼
┌─────────────────────────────────────────────────────────────────────┐
│  Ollama (port 11434)          │  Claude API  │  OpenAI API          │
│  Local models (llama, etc.)   │  (optional)  │  (optional)          │
└─────────────────────────────────────────────────────────────────────┘
```

### Key Components

| Component | Location | Purpose |
|-----------|----------|---------|
| `TrioClient` | `app/services/trio_client.rb` | Ruby client for Trio API |
| `HarmonicAssistant` | `app/services/concerns/harmonic_assistant.rb` | System prompt and response processing |
| Trio | `trio/` | Python voting ensemble service |
| LiteLLM config | `config/litellm_config.yaml` | Model routing configuration |

### Starting LLM Services

```bash
# Start LLM services
docker compose --profile llm up -d

# Pull required Ollama models
docker compose exec ollama ollama pull llama3.2:1b

# Verify Trio is running
curl http://localhost:8000/health
```

### Environment Variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `TRIO_BASE_URL` | `http://trio:8000` | Trio service URL |
| `TRIO_TIMEOUT` | `120` | Request timeout in seconds |
| `TRIO_MODELS` | `default,default,default` | Comma-separated model list for ensemble |
| `ANTHROPIC_API_KEY` | - | For Claude models via LiteLLM |
| `OPENAI_API_KEY` | - | For OpenAI models via LiteLLM |

See [trio/README.md](../trio/README.md) for full Trio documentation.

## Frontend Architecture

### Hotwire (Turbo + Stimulus)

Turbo handles:
- Page navigation (Turbo Drive)
- Partial updates (Turbo Frames)
- Real-time updates (Turbo Streams via WebSocket - limited use)

Stimulus controllers (`app/javascript/controllers/`):
- Form interactions
- Image cropping
- Polling for updates

### Asset Pipeline

Using **jsbundling-rails** with esbuild and **TypeScript**:
- TypeScript source in `app/javascript/`
- Compiled JS output to `app/assets/builds/`
- CSS in `app/assets/stylesheets/`
- Build commands: `npm run build`, `npm run typecheck`

## Automation System

Harmonic includes an IFTTT/Zapier-style automation system for triggering actions based on events, schedules, or webhooks.

See [AUTOMATIONS.md](AUTOMATIONS.md) for full user documentation.

### Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│  Triggers                                                            │
│  ├── Events (note.created, decision.created, etc.)                  │
│  ├── Schedules (cron expressions)                                   │
│  ├── Webhooks (external HTTP requests)                              │
│  └── Manual (user-initiated via UI)                                 │
└────────┬────────────────────────────────────────────────────────────┘
         │
         ▼
┌─────────────────────────────────────────────────────────────────────┐
│  AutomationDispatcher                                                │
│  ├── Finds matching rules (event type, mention filter, conditions)  │
│  ├── Rate limits agent rules (3/min)                                │
│  └── Queues AutomationRuleExecutionJob                              │
└────────┬────────────────────────────────────────────────────────────┘
         │
         ▼
┌─────────────────────────────────────────────────────────────────────┐
│  AutomationExecutor                                                  │
│  ├── Agent rules → Create AiAgentTaskRun                            │
│  └── Studio rules → Execute actions array                           │
│      ├── webhook → Create WebhookDelivery + queue job               │
│      ├── trigger_agent → Create AiAgentTaskRun + queue job          │
│      └── internal_action → (not yet implemented)                    │
└─────────────────────────────────────────────────────────────────────┘
```

### Key Components

| Component | Location | Purpose |
|-----------|----------|---------|
| `AutomationRule` | `app/models/` | Rule definition with trigger, conditions, actions |
| `AutomationRuleRun` | `app/models/` | Execution instance with status, results |
| `AutomationDispatcher` | `app/services/` | Routes events to matching rules |
| `AutomationExecutor` | `app/services/` | Executes rules and actions |
| `AutomationConditionEvaluator` | `app/services/` | Evaluates conditional logic |
| `AutomationTemplateRenderer` | `app/services/` | Renders `{{variable}}` templates |
| `AutomationMentionFilter` | `app/services/` | Checks @mentions in content |
| `AutomationYamlParser` | `app/services/` | Parses and validates YAML rules |
| `AutomationSchedulerJob` | `app/jobs/` | Runs every minute for cron triggers |

### Automation Rule Scoping

Rules can be scoped to different levels:

| Scope | Field Set | Use Case |
|-------|-----------|----------|
| Agent | `ai_agent_id` | AI agent behaviors (respond to @mentions) |
| Studio | `collective_id` | Studio-wide workflows |
| User | `user_id` | Personal automations (future) |

### Integration Points

- **EventService** dispatches events to `AutomationDispatcher` alongside `NotificationDispatcher`
- **Agent rules** create `AiAgentTaskRun` records processed by `AgentQueueProcessorJob`
- **Webhook actions** create `WebhookDelivery` records processed by `WebhookDeliveryJob`

## Background Jobs

**Sidekiq** for background processing:
- Config: `config/sidekiq.yml`
- Jobs: `app/jobs/`
- Redis required for queue storage

Currently minimal job usage. Webhook delivery (stubbed) would use jobs.

## File Storage

**Active Storage** with S3-compatible backend:
- Config: `config/storage.yml`
- Used for: user avatars, studio images, attachments
- Local storage in development (`storage/`)

## Database

**PostgreSQL** with:
- UUIDs as primary keys (via `pgcrypto` extension)
- Generated columns for truncated IDs
- JSON columns for settings/activity logs
- Views for cycle data aggregation

Key patterns:
- All IDs are UUIDs
- `tenant_id` on most tables (except users, oauth_identities)
- `studio_id` on content tables
- `created_by_id`, `updated_by_id` for audit trail

## Directory Structure

```
app/
├── controllers/
│   ├── application_controller.rb  # Auth, tenancy, resource loading
│   ├── api/v1/                    # JSON/Markdown API controllers
│   │   └── base_controller.rb     # API authentication
│   └── [feature]_controller.rb    # HTML controllers
├── models/
│   ├── application_record.rb      # Base class with tenant scoping
│   ├── concerns/                  # Shared model behaviors
│   └── [model].rb
├── services/
│   ├── api_helper.rb              # Business logic
│   └── [service].rb
├── views/
│   ├── layouts/
│   ├── [controller]/
│   │   ├── show.html.erb          # HTML view
│   │   └── show.md.erb            # Markdown view (for LLM)
│   └── shared/
└── javascript/
    └── controllers/               # Stimulus controllers

config/
├── routes.rb                      # Route definitions
├── database.yml
├── storage.yml
└── initializers/

db/
├── structure.sql                  # Database schema
├── seeds.rb
└── migrate/                       # Migrations
```

## Routes Structure

Routes are duplicated for studios and scenes:

```ruby
['studios','scenes'].each do |studios_or_scenes|
  get "#{studios_or_scenes}/:studio_handle" => "#{studios_or_scenes}#show"
  # ... more routes
end
```

Content routes use prefixes:
- `/studios/:studio_handle/n/:id` - Notes
- `/studios/:studio_handle/d/:id` - Decisions
- `/studios/:studio_handle/c/:id` - Commitments

API routes:
- `/api/v1/` - Top-level API
- `/studios/:collective_handle/api/v1/` - Collective-scoped API

## Environment Variables

| Variable | Purpose |
|----------|---------|
| `AUTH_MODE` | `oauth` or `honor_system` |
| `AUTH_SUBDOMAIN` | Subdomain for auth pages |
| `HOSTNAME` | Base domain |
| `PRIMARY_SUBDOMAIN` | Main tenant subdomain |
| `OTHER_PUBLIC_TENANTS` | Comma-separated public subdomains |
| `DATABASE_URL` | PostgreSQL connection |
| `REDIS_URL` | Redis connection for Sidekiq |
| `SECRET_KEY_BASE` | Rails secret key |

## Development Setup

See [README.md](../README.md) for setup instructions.

```bash
# Start services
./scripts/start.sh

# Run tests
./scripts/run-tests.sh

# Rails console
./scripts/rails-c.sh

# Generate ERD
./scripts/generate-erd.sh
```

## Known Technical Debt

1. **Large files**: `ApplicationController` (587 lines) and `ApiHelper` (421 lines) should be refactored
2. **Limited test coverage**: Many controllers untested
3. **Webhook system**: Stubbed but not implemented (`app/services/webhook_services/`)
4. **~50 TODO comments** throughout codebase
5. **Cycle model**: Not a database table, computed on-the-fly - could benefit from caching

## Extension Points

When adding new features:

1. **New content type**: Follow Note/Decision/Commitment pattern
   - Include `Linkable`, `Pinnable`, `HasTruncatedId`
   - Add to `ApiHelper#create` switch
   - Add routes, controller, views

2. **New model concern**: Add to `app/models/concerns/`

3. **New API endpoint**: Add to `app/controllers/api/v1/`
   - Inherit from `BaseController`
   - Follow existing patterns for authorization

4. **New background job**: Add to `app/jobs/`
   - Follow Sidekiq patterns
