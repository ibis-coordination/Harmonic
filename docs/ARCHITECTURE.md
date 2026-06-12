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
└────────┬────────────────────────────────────────────────────────────┘
         │
         ▼
┌─────────────────────────────────────────────────────────────────────┐
│  agent-runner (Node.js/Effect.js)                                    │
│  ├── Consumes tasks from Redis Stream                               │
│  ├── Executes agent LLM loop (navigate, execute, reason)            │
│  └── Reports results back to Rails via internal API                 │
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
| `Collective` | Group within tenant. Can be private or public |
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
- `StripeCustomer` - Billing record; attached to the human user, not a tenant (a single subscription spans all billing-enabled tenants)

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
├── belongs_to :tenant, :collective, :created_by, :updated_by
├── has_many :note_history_events  # read confirmations, edits
├── includes Linkable, Pinnable, Attachable, Commentable
└── has truncated_id for short URLs (e.g., /n/a1b2c3d4)
```

#### Decision
Group decisions via acceptance voting. Maps to "Decide" in OODA.

```ruby
Decision
├── belongs_to :tenant, :collective, :created_by, :updated_by
├── has_many :options              # choices to vote on
├── has_many :decision_participants
├── has_many :votes                # votes (through participants/options)
├── has_many :decision_audit_entries  # tamper-evident audit chain
└── includes Linkable, Pinnable, Attachable, Commentable
```

**Audit chain:** All vote/option mutations go through `DecisionActionService`, which wraps each mutation + audit entry in a single transaction. `DecisionAuditService` computes SHA-256 hash chains. `DecisionAuditVerifier` validates chain integrity. DB triggers prevent audit entry updates and vote mutations after close.

#### Commitment
Action pledges with critical mass thresholds. Maps to "Act" in OODA.

```ruby
Commitment
├── belongs_to :tenant, :collective, :created_by, :updated_by
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
└── scoped to collective tempo setting
```

#### Link
Bidirectional references between content. Maps to "Orient" in OODA.

```ruby
Link
├── belongs_to :from_linkable, polymorphic: true
├── belongs_to :to_linkable, polymorphic: true
├── created automatically when content references other content
└── scoped to same tenant and collective
```

#### UserList
User-curated groups of users, served at `/lists`. Each user has a primary list built by **tuning in** to other users (displayed as "tuned in"; its attributes are immutable and it strictly belongs to its owner), plus optional named custom lists.

```ruby
UserList
├── belongs_to :tenant, :collective, :creator, :owner
├── has_many :user_list_members → :members (User)
├── visibility: public | private
├── add_policy: owner_only | self_add | members_add | anyone_add
├── is_primary: boolean            # the tune-in list; one per owner per tenant
└── includes HasTruncatedId, SoftDeletable
```

Member additions emit `user_list_member.created` events, which drive tune-in notifications. Search supports a `list:` filter (list id, or `mutuals` / `tuned_in` shorthands).

### Supporting Entities

| Entity | Purpose |
|--------|---------|
| `User` | User account (types: human, ai_agent, collective_identity) |
| `Heartbeat` | Periodic presence signal for collective access |
| `RepresentationSession` | When user acts on behalf of a collective |
| `ApiToken` | Token for API authentication |
| `Attachment` | File attached to notes/decisions/commitments |
| `Invite` | Invitation to join a collective |

### Model Concerns

Shared behaviors extracted into concerns:

| Concern | Purpose | Used By |
|---------|---------|---------|
| `HasTruncatedId` | Short 8-char IDs for URLs | Note, Decision, Commitment, UserList, others |
| `Linkable` | Bidirectional linking | Note, Decision, Commitment |
| `Pinnable` | Can be pinned to collective | Note, Decision, Commitment |
| `Attachable` | File attachments | Note, Decision, Commitment |
| `Commentable` | Comments (which are Notes) | Note, Decision, Commitment |
| `Tracked` | Emits `<model>.created/updated/deleted` events feeding notifications and automations | Note, Decision, Commitment, Option, Vote, ChatMessage, UserListMember |
| `SoftDeletable` | Grace-period soft delete before hard delete | Note, Decision, Commitment, UserList |
| `Searchable` | Maintains search index entries | Note, Decision, Commitment |
| `InvalidatesSearchIndex` | Reindexes the parent item when child records change | Option, Vote, Link, CommitmentParticipant, NoteHistoryEvent, Note |
| `TracksUserItemStatus` | Per-user participation/read status on items | Note, Decision, Commitment, Vote, CommitmentParticipant, NoteHistoryEvent |
| `HasRepresentationSessionEvents` | Records actions taken during representation sessions | Note, Decision, Commitment, Option, Vote, participants, Heartbeat |
| `Statementable` | Generated statements | Decision, Commitment, RepresentationSession |
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
1. Request: GET /collectives/myteam/n/a1b2c3d4
2. ApplicationController before_actions:
   ├── current_tenant (set Thread.current[:tenant_id])
   ├── current_collective (set Thread.current[:collective_id])
   ├── current_user (authenticate)
   └── current_resource (load note)
3. NotesController#show
4. Render ERB view
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
1. Request: GET /collectives/myteam/n/a1b2c3d4
   Headers: Authorization: Bearer <token>, Accept: text/markdown
2. Same flow as HTML, but renders .md.erb template
3. Response includes available API actions
```

## Services Layer

### ApiHelper
Central business logic for creating/updating resources.

```ruby
ApiHelper.new(
  current_user:, current_collective:, current_tenant:,
  current_resource_model:, params:, request:
)
```

Methods:
- `create` - creates Note, Decision, or Commitment
- `create_collective`
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
result = service.navigate("/collectives/team")
result = service.execute_action("create_note", { text: "Hello" })
```

Components:
- `MarkdownUiService` - main service with `navigate`, `set_path`, `execute_action`
- `ViewContext` - provides template instance variables
- `ResourceLoader` - loads resources based on routes
- `ActionExecutor` - executes actions via ApiHelper

See [guides/MARKDOWN_UI_SERVICE_USAGE.md](guides/MARKDOWN_UI_SERVICE_USAGE.md) for usage examples.

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
│  └── AgentRunnerDispatchService → Redis Stream "agent_tasks"        │
└────────┬────────────────────────────────────────────────────────────┘
         │ Redis Streams
         ▼
┌─────────────────────────────────────────────────────────────────────┐
│  agent-runner (Node.js)                                              │
│  Consumes agent_tasks; calls LiteLLM; reports results back to Rails │
└────────┬────────────────────────────────────────────────────────────┘
         │ HTTP (OpenAI-compatible API)
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

User-created AI agents and the built-in **Trio** assistant (a system ai_agent
User with `system_role: "trio"`) all flow through the same path. Trio is
provisioned **per collective** that opted in: a collective admin enables the
`trio` feature flag in collective settings, which calls `TrioActivator` to
seed a trio User (via `TrioSeeder`), add it as a `CollectiveMember`, and
seed three default mention-driven automation rules (note/decision/commitment
created with `mention_filter: "self"`). For private workspaces, the opt-in
toggle lives on the user-settings page; the same `TrioActivator` runs.

`@trio` mentions resolve via `MentionParser.parse(..., collective:)`: the
parser checks `collective.trio_user` when the text contains `@trio`. The
main collective's trio claims the literal handle `"trio"` so its profile
lives at `/u/trio` via the normal handle index; non-main collective trios
get hex-suffixed handles to avoid the tenant-wide `(tenant_id, handle)`
uniqueness collision.

### Key Components

| Component | Location | Purpose |
|-----------|----------|---------|
| `AgentRunnerDispatchService` | `app/services/agent_runner_dispatch_service.rb` | Publishes tasks to Redis Stream |
| `TrioActivator` | `app/services/trio_activator.rb` | Turns Trio on/off for one collective; seeds defaults or restores prior state |
| `TrioSeeder` | `app/services/trio_seeder.rb` | Creates the per-collective Trio User and CollectiveMember |
| `Trio::SystemPrompt` | `app/services/trio/system_prompt.rb` | Static identity prompt for trio (resolved dynamically per request) |
| agent-runner | `agent-runner/` | Node.js consumer that executes tasks |
| LiteLLM config | `config/litellm_config.yaml` | Model routing configuration |

### Starting LLM Services

```bash
# Start LLM services
docker compose --profile llm up -d

# Pull required Ollama models
docker compose exec ollama ollama pull llama3.2:1b
```

### Environment Variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `ANTHROPIC_API_KEY` | - | For Claude models via LiteLLM |
| `OPENAI_API_KEY` | - | For OpenAI models via LiteLLM |

## Frontend Architecture

### Hotwire (Turbo + Stimulus)

**Turbo** is imported in [`app/javascript/application.ts`](../app/javascript/application.ts).
Only Turbo Drive is in use today — intercepting link clicks and form submissions
so navigations swap the document body instead of full-reloading. Turbo Frames
and Turbo Streams are not used anywhere yet; if you reach for one, it's a new
pattern in this codebase.

**Stimulus controllers** live in [`app/javascript/controllers/`](../app/javascript/controllers/),
registered in `index.ts`. Every browser-side behavior should be a Stimulus
controller — no inline event handlers (see [SECURITY_AND_SCALING.md](SECURITY_AND_SCALING.md#no-inline-event-handlers)).

Reusable utility controllers — reach for these before writing a new one:

| Controller | When to use |
|---|---|
| `card-navigate` | Whole element clickable, navigates to a URL on click. Honors cmd/ctrl/middle-click → new tab, text-selection drag, Enter/Space, interactive-child short-circuit |
| `card-expand` | CSS-clamped content with a "Show more" toggle |
| `hide-on-error` | Hide an `<img>` (or other element) when the `error` event fires — used for avatar fallbacks |
| `remove-parent` | Click to remove the element's parent (× dismiss buttons) |
| `history-back` | Click to call `window.history.back()` (replaces `href="javascript:history.back()"`) |
| `radio-toggle` | Show/hide a section based on which radio in a group is checked |
| `handle-availability` | Live-validate a slug/handle field against an availability endpoint |

#### Forms and Turbo

When Turbo intercepts a form submission, the response must be one of:

1. **A redirect** — Rails 7+ uses 303 (`:see_other`) by default for `redirect_to`
   after a non-GET request, which is what Turbo wants. Don't override the status.
2. **A re-render of the same form with status 422 (`:unprocessable_entity`)** —
   this is the canonical "show validation errors" pattern. The 200 default does
   NOT work: Turbo leaves the URL on the POST endpoint, so back/refresh re-POSTs.

   ```ruby
   def create
     @model = Model.create!(model_params)
     redirect_to @model
   rescue ActiveRecord::RecordInvalid
     @model = Model.new(model_params)
     render :new, status: :unprocessable_entity   # not bare `render :new`
   end
   ```

When the response can't be either (e.g., the controller renders a
different template, or `redirect_to` goes to a cross-origin URL like a
Stripe Checkout page that Turbo can't fetch via XHR), opt the form out of
Turbo with `data: { turbo: false }`:

```erb
<%= form_with url: billing_setup_path, method: :post, data: { turbo: false } do |form| %>
```

Same rule applies to links to a cross-origin redirect:

```erb
<%= link_to "Manage payment", billing_portal_path, data: { turbo: false } %>
```

For scripts that initialize page state on load, listen for `turbo:load`
(fires on initial load AND every Turbo navigation), not `DOMContentLoaded`
(fires once, never again on Turbo navs). Stimulus controllers handle this
automatically via `connect()`.

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
│  ├── Agent rules → Create AiAgentTaskRun + dispatch via Redis stream│
│  └── Collective rules → Execute actions array                       │
│      ├── webhook → Create WebhookDelivery + queue job               │
│      ├── trigger_agent → Create AiAgentTaskRun + dispatch via stream│
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
| Collective | `collective_id` | Collective-wide workflows |
| User | `user_id` | Personal automations (future) |

### Integration Points

- **EventService** dispatches events to `AutomationDispatcher` alongside `NotificationDispatcher`
- **Agent rules** create `AiAgentTaskRun` records dispatched to the agent-runner service via Redis Streams (see [AGENT_RUNNER.md](AGENT_RUNNER.md))
- **Webhook actions** create `WebhookDelivery` records processed by `WebhookDeliveryJob`

## Background Jobs

**Sidekiq** for background processing:
- Config: `config/sidekiq.yml`
- Jobs: `app/jobs/`
- Redis required for queue storage

Used for: automation rule execution (`AutomationRuleExecutionJob`), webhook delivery (`WebhookDeliveryJob`), scheduled/cron triggers (`AutomationSchedulerJob`), reminder delivery, and similar I/O-light work. AI agent task execution runs in the separate **agent-runner** Node.js service — see [AGENT_RUNNER.md](AGENT_RUNNER.md) — because the LLM call patterns are not a good fit for thread-per-task Sidekiq concurrency.

## File Storage

**Active Storage** with S3-compatible backend:
- Config: `config/storage.yml`
- Used for: user avatars, collective images, attachments
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
- `collective_id` on content tables
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

Content routes use prefixes:
- `/collectives/:collective_handle/n/:id` - Notes
- `/collectives/:collective_handle/d/:id` - Decisions
- `/collectives/:collective_handle/c/:id` - Commitments

API routes:
- `/api/v1/` - Top-level API
- `/collectives/:collective_handle/api/v1/` - Collective-scoped API

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

1. **Large files**: `ApplicationController` and `ApiHelper` are large and could be refactored
2. **Cycle model**: Not a database table, computed on-the-fly - could benefit from caching

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
