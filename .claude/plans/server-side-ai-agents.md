# Server-Side AI Agent Feature

## Overview

Enable users to create AI-powered subagents that run server-side, eliminating the need for users to set up their own API integration. The agent reuses Harmonic's existing markdown API interface.

---

## Current Implementation Status

### ✅ Implemented

#### Data Model
- **`users.agent_configuration`** (jsonb) - Stores per-agent config including `identity_prompt`
- **`subagent_task_runs`** - Tracks each agent execution with status, steps, timing
- **`subagent_task_run_resources`** - Tracks resources created by each task run

#### Core Agent Loop
- **`AgentNavigator`** - Agentic loop: navigate → think → execute → repeat
- **`MarkdownUiService`** - Internal rendering of markdown templates and action execution
- **`LLMClient`** - OpenAI-compatible client using LiteLLM proxy

#### Triggering
- **@Mentions** - `MentionParser` extracts handles, `NotificationDispatcher.trigger_subagent_tasks` creates task runs
- **Conversation replies** - When someone replies to agent-created content, agent is triggered
- **Manual invocation** - `/subagents/:handle/run` form to run arbitrary tasks

#### Rate Limiting
- 3 task triggers per minute per subagent (in `NotificationDispatcher`)
- Max steps per run (default 30, max 50)

#### UI
- `/subagents` - List subagents owned by current user
- `/subagents/:handle/run` - Task submission form
- `/subagents/:handle/runs` - Task run history
- `/subagents/:handle/runs/:id` - Task run detail with steps and created resources
- User settings - Identity prompt, capabilities, and model editing for subagents

#### Identity/Context
- Identity prompt stored in `users.agent_configuration["identity_prompt"]`
- Shown on `/whoami` page (agents navigate here first)
- Agents see which studios they belong to, upcoming reminders, etc.
- Capability restrictions shown on `/whoami` if configured

#### Capability Restrictions
- **`CapabilityCheck`** service - Enforces capability-based authorization
- Always-allowed actions: `send_heartbeat`, `dismiss`, `dismiss_all`, `search`, `update_scratchpad`
- Always-blocked actions: `create_studio`, `create_subagent`, `update_tenant_settings`, etc.
- Grantable actions: `create_note`, `vote`, `join_commitment`, etc. (configurable per agent)
- UI in user settings - Checkbox list to configure allowed capabilities
- If `capabilities` key is absent, all grantable actions allowed (backwards compatible)

#### Per-Agent Model Selection
- Model stored in `users.agent_configuration["model"]`
- Pulled from agent config when creating `SubagentTaskRun`
- UI dropdown in subagent settings

### ❌ Not Yet Implemented

| Feature | Description | Priority |
|---------|-------------|----------|
| Approval workflow | Queue risky actions for human approval | High |
| BYOK API Keys | Users provide their own Anthropic/OpenAI keys | Medium |
| Cost tracking | Track tokens/cost per execution | Medium |
| Cost alerts | Notify at $1, $5, $10 thresholds | Low |
| Auto-pause | Pause agent at cost limit | Low |
| Subscriptions | Watch content for changes (not just @mentions) | Low |
| Studio-owned agents | Agents owned by studio, not person | Low |

---

## Design Principles

1. **Reuse existing infrastructure** - Subagent user type, markdown API, Sidekiq
2. **Same interface as external agents** - Server-side agents use the same markdown API that MCP clients use
3. **Clear ownership** - Agents are subagents with parent person relationships
4. **Audit trail** - All actions tracked via SubagentTaskRunResource

---

## Architecture

### Event Flow (Current)

```
Content Created/Updated
        │
        ▼
┌─────────────────────────┐
│ Event.emit!             │  (ActiveRecord callback)
│ - note.created          │
│ - decision.created      │
│ - comment.created       │
└───────────┬─────────────┘
            │
            ▼
┌─────────────────────────┐
│ NotificationDispatcher  │  (Sidekiq job)
│ - Parse @mentions       │
│ - Find subagent replies │
│ - Rate limit check      │
│ - Create SubagentTaskRun│
└───────────┬─────────────┘
            │
            ▼
┌─────────────────────────┐
│ AgentQueueProcessorJob  │  (Sidekiq - claims & runs)
│ - Claim next queued run │
│ - Set thread context    │
│ - Run AgentNavigator    │
│ - Record results        │
│ - Schedule next task    │
└─────────────────────────┘
```

### Agent Execution Loop

```
┌──────────────────────────────────────────────────────────┐
│  AgentNavigator.run(task:)                               │
├──────────────────────────────────────────────────────────┤
│  1. Navigate to /whoami (get identity, context)          │
│                                                          │
│  2. Loop until done or max_steps:                        │
│     a. Build prompt with current page + available actions│
│     b. Send to LLM via LLMClient                         │
│     c. Parse JSON response: navigate/execute/done/error  │
│     d. Execute action via MarkdownUiService              │
│     e. Record step                                       │
│                                                          │
│  3. Return Result with success, steps, final_message     │
└──────────────────────────────────────────────────────────┘
```

### Key Files

| File | Purpose |
|------|---------|
| `app/services/agent_navigator.rb` | Core agentic loop |
| `app/services/llm_client.rb` | LLM API client (LiteLLM proxy) |
| `app/services/markdown_ui_service.rb` | Internal markdown rendering |
| `app/services/notification_dispatcher.rb` | Trigger routing including subagent tasks |
| `app/services/mention_parser.rb` | @handle extraction |
| `app/jobs/agent_queue_processor_job.rb` | Task execution job |
| `app/models/subagent_task_run.rb` | Task run record |
| `app/models/subagent_task_run_resource.rb` | Resource tracking |
| `app/controllers/subagents_controller.rb` | UI and manual task submission |

---

## Planned Features

### Phase 1: Approval Workflow (High Priority)

Queue certain actions for human approval before execution.

#### Data Model

New table: `agent_pending_actions`

| Column | Type | Purpose |
|--------|------|---------|
| `id` | uuid | Primary key |
| `tenant_id` | uuid | Tenant |
| `subagent_task_run_id` | uuid | Links to the execution |
| `subagent_id` | uuid | The agent |
| `action_name` | string | e.g., 'vote', 'commit' |
| `action_params` | jsonb | Parameters for the action |
| `context_summary` | text | What the agent was responding to |
| `status` | string | pending, approved, rejected, expired |
| `reviewed_by_id` | uuid | User who approved/rejected |
| `reviewed_at` | timestamp | When reviewed |
| `expires_at` | timestamp | Auto-expire if not reviewed |

Extend `users.agent_configuration`:
```json
{
  "identity_prompt": "...",
  "capabilities": ["create_note", "vote", "commit"],
  "requires_approval": ["vote", "commit"]
}
```

#### Workflow

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
 immediately  + Notify parent user
                    │
                    ▼
              Wait for review
                    │
         ┌──────────┴──────────┐
         ▼                     ▼
      Approved              Rejected
         │                     │
         ▼                     ▼
   Execute action         Log rejection
```

#### Implementation

1. **Check before execute** - `MarkdownUiService.execute_action` checks if action requires approval
2. **Queue action** - Create `AgentPendingAction` record instead of executing
3. **Agent response** - Agent receives "action queued for approval" message
4. **Notification** - Notify parent user of pending approval
5. **Approval UI** - `/subagents/:handle/pending` - list pending actions with approve/reject
6. **Execute on approval** - Background job executes approved actions
7. **Expiration** - Auto-reject after 24 hours (configurable)

### Phase 2: BYOK API Keys (Medium Priority)

Allow users to provide their own API keys instead of using the shared LiteLLM proxy.

#### Data Model

New table: `agent_api_keys`

| Column | Type | Purpose |
|--------|------|---------|
| `id` | uuid | Primary key |
| `tenant_id` | uuid | Tenant |
| `owner_id` | uuid | Person who owns the key |
| `provider` | string | 'anthropic', 'openai' |
| `encrypted_key` | bytea | Encrypted API key |
| `key_hint` | string | Last 4 chars for display |
| `total_tokens_used` | bigint | Usage tracking |
| `total_cost_usd` | decimal | Cost tracking |
| `created_at` | timestamp | |

Extend `users.agent_configuration`:
```json
{
  "identity_prompt": "...",
  "api_key_id": "uuid-of-key-to-use",
  "model": "claude-sonnet-4-20250514"
}
```

#### Implementation

1. **Key management UI** - `/u/:handle/settings/api-keys`
2. **Encryption** - Use Rails ActiveRecord Encryption
3. **Key selection** - Agent config specifies which key to use
4. **Direct API calls** - When key specified, bypass LiteLLM, call provider directly
5. **Usage tracking** - Log tokens/cost per execution to the key record
6. **Fallback** - If no key specified, use shared LiteLLM proxy (current behavior)

### Phase 3: Cost Tracking & Alerts (Medium Priority)

Track usage and alert users when costs reach thresholds.

#### Data Model

Add columns to `subagent_task_runs`:
- `input_tokens` (integer)
- `output_tokens` (integer)
- `estimated_cost_usd` (decimal)

Extend `users.agent_configuration`:
```json
{
  "cost_limit_usd": 100,
  "alert_thresholds_usd": [1, 5, 10, 50],
  "paused_at": null,
  "paused_reason": null
}
```

#### Implementation

1. **Track tokens** - `LLMClient` returns usage, store on task run
2. **Calculate cost** - Use per-model pricing tables
3. **Aggregate** - Sum costs per agent per day/month
4. **Alerts** - Notify parent when crossing thresholds
5. **Auto-pause** - Disable agent when limit reached
6. **Dashboard** - Show cost graphs in `/subagents/:handle/usage`

### Phase 4: Subscriptions (Low Priority)

Allow agents to watch content and respond to changes (not just @mentions).

#### Data Model

New table: `agent_subscriptions`

| Column | Type | Purpose |
|--------|------|---------|
| `id` | uuid | Primary key |
| `tenant_id` | uuid | Tenant |
| `subagent_id` | uuid | The watching agent |
| `subscribable_type` | string | 'Superagent', 'Note', 'Decision', etc. |
| `subscribable_id` | uuid | What to watch |
| `events` | jsonb | `['create', 'update', 'comment']` |
| `enabled` | boolean | On/off |

#### Implementation

1. **Subscribe action** - Markdown action to subscribe agent to content
2. **Event routing** - `NotificationDispatcher` checks subscriptions
3. **Trigger task** - Create task run when subscribed event fires
4. **Unsubscribe action** - Remove subscription
5. **Subscription list** - Show what agent is watching in settings

---

## Safety & Limits

### Current Safeguards
- Rate limiting: 3 triggers per minute per agent
- Max steps: 30 default, 50 max per task run
- Agents cannot trigger themselves (cooldown)
- All actions go through normal permission checks

### Planned Safeguards
- Capability restrictions (Phase 1)
- Approval workflow for risky actions (Phase 2)
- Cost limits and auto-pause (Phase 4)

### Infinite Loop Prevention
- Turn limit per execution (MAX_STEPS)
- Rate limit on triggers
- Agents excluded from triggering themselves via @mention

---

## UI Routes

### Current
- `GET /subagents` - List owned subagents
- `GET /subagents/:handle/run` - Task submission form
- `POST /subagents/:handle/run` - Execute task
- `GET /subagents/:handle/runs` - Task run history
- `GET /subagents/:handle/runs/:id` - Task run detail
- `GET /u/:handle/settings` - Edit identity prompt (for subagents)

### Planned
- `GET /subagents/:handle/settings` - Agent configuration (capabilities, approvals)
- `GET /subagents/:handle/pending` - Pending approval queue
- `POST /subagents/:handle/pending/:id/approve` - Approve action
- `POST /subagents/:handle/pending/:id/reject` - Reject action
- `GET /u/:handle/settings/api-keys` - API key management
- `GET /subagents/:handle/usage` - Cost/usage dashboard

---

## Implementation Order

1. ~~**Capability Restrictions** - Essential safety feature, relatively simple~~ ✅ **DONE**
2. ~~**Per-agent Model Selection** - Choose model per agent~~ ✅ **DONE**
3. **Approval Workflow** - Important for high-stakes actions
4. **BYOK API Keys** - Enables user cost control
5. **Cost Tracking** - Visibility into usage
6. **Subscriptions** - Nice to have, lower priority

---

## Architectural Decisions

### Why LiteLLM Proxy (Current)
- **Simplicity** - Single point of configuration
- **Flexibility** - Can route to different providers/models
- **No key management** - Server handles API keys centrally

### Why BYOK (Planned)
- **User cost control** - Users pay their own AI costs directly
- **Privacy option** - Users can use their own accounts
- **Flexibility** - Users choose models/providers
- **Scalability** - Distributes infrastructure cost

### Why Capability Restrictions
- **Safety** - Prevent agents from taking unintended actions
- **Trust building** - Users can start restrictive, loosen over time
- **Compliance** - Some orgs may require certain actions be human-only

### Why Approval Workflow
- **Human oversight** - Critical for high-stakes decisions
- **Reversibility** - Catch mistakes before they happen
- **Audit** - Clear record of what was approved and by whom
