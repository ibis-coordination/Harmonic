# Server-Side AI Agent Feature - Architecture Design

## Overview

Enable users to create AI-powered subagents that run server-side, eliminating the need for users to set up their own API integration. The agent reuses Harmonic's existing markdown API interface.

## Design Principles

1. **Reuse existing infrastructure** - Subagent user type, markdown API, Sidekiq
2. **BYOK (Bring Your Own Key)** - Users provide their Anthropic API key
3. **Same interface as external agents** - Server-side agents use the same markdown API that MCP clients use
4. **Clear ownership** - Agents are subagents with parent person relationships

---

## Data Model

### New Tables

#### `agent_configurations`
Stores AI-specific settings for subagent users. **Studio-owned agents** are the primary use case.

| Column | Type | Purpose |
|--------|------|---------|
| `user_id` | uuid | Links to subagent user |
| `studio_id` | uuid | **Studio that owns this agent** (nullable for personal agents) |
| `provider` | string | 'anthropic' (only supported provider for now) |
| `model` | string | e.g., 'claude-sonnet-4-20250514' |
| `system_prompt` | text | Custom instructions |
| `capabilities` | jsonb | `['create_note', 'vote', 'commit', 'comment']` |
| `requires_approval` | jsonb | **Actions needing human approval** `['vote', 'commit']` |
| `trigger_on_mention` | boolean | Respond to @mentions |
| `trigger_on_subscription` | boolean | Watch content changes |
| `max_actions_per_hour` | integer | Rate limit |
| `max_tokens_per_day` | integer | Cost control |
| `cooldown_seconds` | integer | Min time between responses |
| `enabled` | boolean | On/off switch |
| `paused_at` / `paused_reason` | timestamp/text | Auto-pause on issues |

#### `agent_api_keys`
Securely stores encrypted user API keys (BYOK).

| Column | Type | Purpose |
|--------|------|---------|
| `owner_id` | uuid | Person who owns the key |
| `provider` | string | 'anthropic', 'openai' |
| `encrypted_key` | bytea | Encrypted API key |
| `key_hint` | string | Last 4 chars for display |
| `total_tokens_used` | bigint | Usage tracking |
| `total_cost_usd` | decimal | Cost tracking |

#### `agent_executions`
Audit trail for every agent invocation.

| Column | Type | Purpose |
|--------|------|---------|
| `agent_user_id` | uuid | Which agent ran |
| `trigger_type` | string | 'mention', 'subscription', 'manual' |
| `trigger_source_type/id` | string/uuid | What triggered it |
| `status` | string | pending, running, completed, failed, rate_limited |
| `actions_taken` | jsonb | Log of actions |
| `input_tokens` / `output_tokens` | integer | Token usage |
| `estimated_cost_usd` | decimal | Cost tracking |

#### `agent_subscriptions`
What content agents are watching.

| Column | Type | Purpose |
|--------|------|---------|
| `subscribable_type/id` | string/uuid | Studio, Note, Decision, etc. |
| `events` | jsonb | `['create', 'update']` |
| `enabled` | boolean | On/off |

#### `agent_pending_actions`
Queue for actions awaiting human approval.

| Column | Type | Purpose |
|--------|------|---------|
| `agent_execution_id` | uuid | Links to the execution |
| `action_name` | string | e.g., 'vote', 'commit' |
| `action_params` | jsonb | Parameters for the action |
| `context_summary` | text | What the agent was responding to |
| `status` | string | pending, approved, rejected, expired |
| `reviewed_by_id` | uuid | User who approved/rejected |
| `reviewed_at` | timestamp | When reviewed |
| `expires_at` | timestamp | Auto-expire if not reviewed |

---

## Event Flow

```
Content Created/Updated
        │
        ▼
┌─────────────────────────┐
│ AgentTriggerable        │  (ActiveRecord callback concern)
│ (after_commit)          │
└───────────┬─────────────┘
            │
            ▼
┌─────────────────────────┐
│ AgentTriggerJob         │  (Sidekiq - quick, fans out)
│ - Parse @mentions       │
│ - Check subscriptions   │
│ - Rate limit check      │
└───────────┬─────────────┘
            │
            ▼
┌─────────────────────────┐
│ AgentExecutionJob       │  (Sidekiq - separate queue)
│ - Build context         │
│ - Call Anthropic API    │
│ - Execute actions       │
│ - Log results           │
└─────────────────────────┘
```

---

## Trigger Mechanisms

### 1. @Mentions
- `MentionParser` scans text for `@handle` patterns
- Looks up handles in `tenant_users` table
- Filters to enabled agent configurations
- Enqueues execution for each mentioned agent

### 2. Subscriptions
- Agents can subscribe to Studios, Notes, Decisions, etc.
- When subscribed content changes, agent is triggered
- Configurable events: create, update

### 3. Manual Invocation
- UI button or markdown API action to invoke agent
- User explicitly asks agent to respond to specific content

---

## Agent Execution

The `AgentExecutor` service runs an agentic loop:

1. **Build context** - Fetch markdown view of trigger content
2. **System prompt** - Include capabilities, custom instructions
3. **Call AI** - Send to Anthropic API with tools
4. **Process tool calls** - Execute navigate/execute_action
5. **Loop** - Up to MAX_TURNS (10) or until agent stops
6. **Record** - Log actions, tokens, cost

### Tools Available to Agent

```
navigate(path)
  - Navigate to a Harmonic page
  - Returns markdown content + available actions

execute_action(action, params)
  - Execute an action on current page
  - Filtered by agent's configured capabilities
```

### Key Insight: Internal Rendering

Instead of making HTTP requests, the agent uses:
- `InternalMarkdownRenderer` - Renders `.md.erb` templates directly
- `InternalActionExecutor` - Calls `ApiHelper` methods directly

This avoids network overhead while maintaining the same interface.

---

## Approval Workflow

When an agent attempts an action that requires approval:

```
Agent decides to take action (e.g., vote)
        │
        ▼
┌─────────────────────────┐
│ Check requires_approval │
│ config for this action  │
└───────────┬─────────────┘
            │
    ┌───────┴───────┐
    │               │
    ▼               ▼
 Allowed        Needs Approval
    │               │
    ▼               ▼
 Execute      Create PendingAction
 immediately  + Send Notification
                    │
                    ▼
              Wait for human review
                    │
         ┌──────────┴──────────┐
         ▼                     ▼
      Approved              Rejected
         │                     │
         ▼                     ▼
   Execute action         Log rejection
   + Notify agent         + Notify agent
```

### Approval UI
- Studio admins see pending actions in a queue
- Each pending action shows: agent name, action, context, timestamp
- Approve/Reject buttons with optional feedback
- Bulk approve/reject for efficiency

---

## Safety & Limits

### Rate Limiting (Redis-based)
- `max_actions_per_hour` - Hourly execution cap
- `max_tokens_per_day` - Daily token budget
- `cooldown_seconds` - Minimum gap between executions

### Infinite Loop Prevention
- Agents cannot trigger themselves
- Turn limit per execution (MAX_TURNS = 10)
- Cooldown enforced between executions

### Capability Restrictions
- Each agent has explicit capability list
- Actions checked against capabilities before execution
- Unknown actions rejected
- **Approval check** - Some actions queue for human review instead of executing

### Cost Controls
- Token usage tracked per execution
- Cost calculated and stored
- Alert thresholds: $1, $5, $10, $50
- Auto-pause at $100 (configurable)
- **Notifications** sent at each threshold

---

## User Interface

### Agent Creation (extends existing subagent flow)
```
/u/:handle/settings/subagents/new
  [x] Enable as AI Agent
  [ ] Provider: Anthropic / OpenAI
  [ ] Model: claude-sonnet-4-20250514
  [ ] System Prompt: ...
  [ ] Capabilities: [create_note] [comment] [vote] [commit]
```

### API Key Management
```
/u/:handle/settings/api-keys
  Add AI Provider Key
  - Provider: Anthropic
  - API Key: sk-ant-... (encrypted)
```

### Agent Activity Dashboard
```
/u/:handle/settings/agents/:id/activity
  - Recent executions (status, trigger, actions)
  - Token usage graph
  - Cost tracking
  - Error logs
```

---

## Key Files to Modify/Create

### Models
- `app/models/agent_configuration.rb` (new)
- `app/models/agent_api_key.rb` (new)
- `app/models/agent_execution.rb` (new)
- `app/models/agent_subscription.rb` (new)
- `app/models/user.rb` - Add `has_one :agent_configuration`
- `app/models/concerns/agent_triggerable.rb` (new)

### Services
- `app/services/agent_executor.rb` (new) - Core execution engine
- `app/services/mention_parser.rb` (new) - @mention detection
- `app/services/rate_limiter.rb` (new) - Redis-based limits
- `app/services/internal_markdown_renderer.rb` (new)
- `app/services/internal_action_executor.rb` (new)
- `app/services/anthropic_client.rb` (new) - API wrapper

### Jobs
- `app/jobs/agent_trigger_job.rb` (new)
- `app/jobs/agent_execution_job.rb` (new)

### Controllers
- `app/controllers/agent_configurations_controller.rb` (new)
- `app/controllers/agent_api_keys_controller.rb` (new)

---

## Prerequisites

### Notification System (MUST BUILD FIRST)
The AI agent feature depends on a notification system to:
- Notify users when agents take actions
- Alert users when actions need approval
- Send cost alerts and rate limit warnings

This should be implemented before the agent feature.

---

## Implementation Phases

### Phase 0: Notification System (Prerequisite)
- Design notification data model
- Build notification delivery (in-app, email)
- Add notification preferences per user
- Create notification UI

### Phase 1: Foundation
- Database migrations for agent tables
- Models with validations
- API key encryption (Rails credentials or separate encryption)

### Phase 2: Event System
- MentionParser service
- AgentTriggerable concern (add to Note, Decision, Commitment)
- AgentTriggerJob

### Phase 3: Execution Engine
- AnthropicClient wrapper
- AgentExecutor with tool handling
- InternalMarkdownRenderer
- InternalActionExecutor
- Rate limiting (Redis-based)

### Phase 4: Approval Workflow
- AgentPendingAction model and queue
- Approval UI (list pending, approve/reject buttons)
- Notification integration for approval requests
- Expiration job for stale approvals

### Phase 5: UI & Polish
- Studio agent configuration pages
- API key management UI
- Activity dashboard
- Cost alerts

---

## Design Decisions

1. **Provider** - Anthropic only for now (can extend later)
2. **Conversation memory** - No special memory; agents access history through the app like any user
3. **Studio-level agents** - Studios can have shared agents (primary use case); studio-owned like trustee users
4. **Notification system** - PREREQUISITE: Must implement notification system first
5. **Approval workflow** - Configurable per agent; owner chooses which actions need approval

---

## Architectural Decision: Why This Approach?

### Reusing Markdown API
- **Consistency**: Agents see exactly what external MCP clients see
- **Security**: Existing permission checks apply automatically
- **Simplicity**: No parallel action system needed
- **Audit trail**: All actions go through same logging

### BYOK Model
- **No billing complexity**: Users pay their own AI costs
- **Privacy**: Harmonic never processes content through its own AI
- **Flexibility**: Users choose models/providers
- **Scalability**: No Harmonic infrastructure cost concerns

### Subagent Foundation
- **Existing infrastructure**: `user_type: "subagent"` already exists
- **Clear ownership**: Studio-owned agents (like trustees) are primary use case
- **Permission model**: Uses existing studio membership
- **Audit trail**: Actions attributed to specific agent user

### Studio-Owned Agents
- Similar to how each studio has a trustee user, studios can have AI agent users
- Studio admins can configure the agent
- Any studio admin can approve pending actions
- API key can be at studio level (shared) or provided by individual users
