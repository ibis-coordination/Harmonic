# Automation System Implementation Plan

**Goal**: Add IFTTT/Zapier-like automation features with YAML-defined workflows, replacing hardcoded AI agent triggers with explicit, configurable rules

## Overview

Two types of automation rules:

### 1. Agent Automation Rules (new)
- **Owner**: AI agent's parent user exclusively
- **Scope**: Per-agent (each rule tied to one agent)
- **Purpose**: Define when and how an AI agent should be triggered
- **Replaces**: Hardcoded `trigger_ai_agent_tasks` in NotificationDispatcher
- **Template gallery**: Common patterns like "respond to @ mentions", "daily summary"

### 2. General Automation Rules
- **Owner**: Studio admins or users
- **Scope**: Studio-level or user-level
- **Purpose**: Run actions (create notes, send webhooks) without involving AI agents

## Database Schema

### `automation_rules` table
```ruby
create_table :automation_rules, id: :uuid do |t|
  t.references :tenant, type: :uuid, null: false
  t.references :superagent, type: :uuid, null: true  # nil = user-level or agent rule
  t.references :user, type: :uuid, null: true        # nil = studio-level
  t.references :ai_agent, type: :uuid, null: true, foreign_key: { to_table: :users }  # NEW: for agent rules
  t.references :created_by, type: :uuid, null: false

  t.string :name, null: false
  t.text :description
  t.string :truncated_id, limit: 8

  t.string :trigger_type, null: false  # 'event', 'schedule', 'webhook'
  t.jsonb :trigger_config, null: false, default: {}
  t.jsonb :conditions, null: false, default: []
  t.jsonb :actions, null: false, default: []  # For agent rules, this is the task prompt template
  t.text :yaml_source

  t.boolean :enabled, default: true
  t.integer :execution_count, default: 0
  t.timestamp :last_executed_at
  t.string :webhook_secret
  t.string :webhook_path  # unique path like /hooks/abc123

  t.timestamps
end

add_index :automation_rules, [:ai_agent_id, :enabled]  # Fast lookup for agent rules
```

**Rule types determined by fields**:
- `ai_agent_id` present → Agent automation rule (triggers agent task)
- `superagent_id` present → Studio automation rule (runs actions)
- `user_id` present → User automation rule (runs actions)

### `automation_rule_runs` table
```ruby
create_table :automation_rule_runs, id: :uuid do |t|
  t.references :tenant, type: :uuid, null: false
  t.references :automation_rule, type: :uuid, null: false
  t.references :triggered_by_event, type: :uuid, null: true

  t.string :trigger_source  # 'event', 'schedule', 'webhook', 'manual'
  t.jsonb :trigger_data, default: {}
  t.string :status, default: 'pending'  # pending, running, completed, failed, skipped
  t.jsonb :actions_executed, default: []
  t.text :error_message
  t.timestamp :started_at, :completed_at

  t.timestamps
end
```

## YAML Format

### Agent Automation Rule (triggers AI agent task)
```yaml
name: "Respond to mentions"
description: "When mentioned, navigate to the content and respond"

trigger:
  type: event
  event_type: note.created
  # Condition: agent was mentioned in the content
  mention_filter: self  # "self" = this agent was mentioned

# Task prompt template (what the agent should do)
task: |
  You were mentioned by {{event.actor.name}} in {{subject.path}}.
  Navigate there, read the context, and respond appropriately with a comment.

max_steps: 20  # optional, defaults to agent's configured max
```

### Agent Rule with Schedule Trigger
```yaml
name: "Daily studio summary"
description: "Every morning, summarize yesterday's activity"

trigger:
  type: schedule
  cron: "0 9 * * *"  # 9am daily
  timezone: "America/Los_Angeles"

task: |
  Review yesterday's activity in your studios and post a summary note
  highlighting key decisions, commitments, and discussions.

max_steps: 30
```

### General Automation Rule (no agent, runs actions directly)
```yaml
name: "Notify on critical mass"
description: "Post celebratory note when commitment reaches critical mass"

trigger:
  type: event
  event_type: commitment.critical_mass

conditions:  # optional filters
  - field: "event.metadata.participant_count"
    operator: ">="
    value: 5

actions:
  - type: internal_action
    action: create_note
    params:
      text: "{{subject.title}} reached critical mass!"

  - type: webhook
    url: "https://hooks.slack.com/..."
    body:
      text: "Critical mass: {{subject.title}}"
```

**Template variables**: `{{event.type}}`, `{{event.actor.name}}`, `{{subject.title}}`, `{{subject.path}}`, `{{studio.handle}}`, `{{webhook.body.*}}`

**Special mention_filter values for agent rules**:
- `self` - Trigger when this agent is mentioned
- `any_agent` - Trigger when any agent is mentioned (useful for orchestration)
- omit - No mention filtering (trigger on all matching events)

## Core Services

| Service | Purpose |
|---------|---------|
| `AutomationYamlParser` | Parse/validate YAML, normalize to model attributes |
| `AutomationExecutor` | Execute rule: check conditions, run actions in order |
| `AutomationDispatcher` | Find matching rules for events, queue execution |
| `AutomationConditionEvaluator` | Evaluate conditions (==, !=, >, contains, matches, etc.) |
| `AutomationTemplateRenderer` | Render `{{variable}}` templates |
| `AutomationWebhookSender` | Send outgoing HTTP webhooks |

## Integration Points

### 1. EventService (app/services/event_service.rb:38)
Add `AutomationDispatcher.dispatch(event)` to `dispatch_to_handlers`

### 2. Remove Hardcoded Agent Triggers (app/services/notification_dispatcher.rb)

**Remove these methods entirely**:
- `trigger_ai_agent_tasks` (lines 421-453)
- `build_task_prompt` (lines 455-461)

**Remove calls to `trigger_ai_agent_tasks` from**:
- `handle_note_event` (line 52)
- `handle_comment_event` (lines 79-80, 87)
- `handle_reply_notification` (lines 111-112, 120)
- `handle_decision_created_event` (line 251)
- `handle_commitment_created_event` (line 285)
- `handle_option_created_event` (line 320)

This behavior is replaced by `AutomationDispatcher` which finds matching agent rules and triggers them.

### 3. Routes (config/routes.rb)
```ruby
# Incoming webhooks (public endpoint)
post 'hooks/:webhook_id' => 'incoming_webhooks#receive'

# Agent automation rules (under user settings, scoped to agent)
get 'u/:handle/settings/ai-agents/:agent_handle/automations' => 'agent_automations#index'
get 'u/:handle/settings/ai-agents/:agent_handle/automations/new' => 'agent_automations#new'
get 'u/:handle/settings/ai-agents/:agent_handle/automations/templates' => 'agent_automations#templates'
# ... standard CRUD

# Studio automation rules (within studios/scenes loop, after webhooks ~line 344):
get "#{studios_or_scenes}/:superagent_handle/settings/automations" => 'automations#index'
# ... standard CRUD
```

### 4. Sidekiq Cron
Add `AutomationSchedulerJob` to run every minute for scheduled triggers

## Files to Create

**Models**:
- `app/models/automation_rule.rb` (follow Webhook pattern with HasTruncatedId)
- `app/models/automation_rule_run.rb`

**Services**:
- `app/services/automation_yaml_parser.rb`
- `app/services/automation_executor.rb`
- `app/services/automation_dispatcher.rb`
- `app/services/automation_condition_evaluator.rb`
- `app/services/automation_template_renderer.rb`
- `app/services/automation_webhook_sender.rb`
- `app/services/automation_mention_filter.rb` (check if agent was mentioned)

**Jobs**:
- `app/jobs/automation_rule_execution_job.rb`
- `app/jobs/automation_scheduler_job.rb`

**Controllers**:
- `app/controllers/agent_automations_controller.rb` (agent rules, parent user only)
- `app/controllers/automations_controller.rb` (studio rules, follow webhooks_controller)
- `app/controllers/incoming_webhooks_controller.rb`

**Views** (HTML + Markdown):
- `app/views/agent_automations/index.html.erb` (list agent's rules)
- `app/views/agent_automations/templates.html.erb` (template gallery)
- `app/views/agent_automations/new.html.erb` (YAML editor)
- `app/views/agent_automations/show.html.erb`
- `app/views/automations/` (studio rules, similar structure)

**Template Gallery** (YAML files or database seeds):
- "Respond to @ mentions"
- "Respond to comments on my content"
- "Daily studio summary"
- "Weekly commitment review"
- "Respond to new decisions"

**Tests**:
- `test/models/automation_rule_test.rb`
- `test/services/automation_*_test.rb`
- `test/controllers/agent_automations_controller_test.rb`
- `test/controllers/automations_controller_test.rb`

## Phased Implementation

### Phase 1: Agent Automation Foundation
**Goal**: Replace hardcoded agent triggers with configurable rules

1. Database migrations for `automation_rules` and `automation_rule_runs`
2. AutomationRule model with agent rule support (`ai_agent_id`)
3. AutomationYamlParser with agent rule validation
4. AutomationDispatcher - finds matching rules for events
5. AutomationExecutor - triggers agent tasks (via existing AiAgentTaskRun)
6. AutomationMentionFilter - detect if agent was mentioned
7. **Remove hardcoded triggers from NotificationDispatcher**
8. AutomationRuleExecutionJob

**Deliverables**: Agents only run when triggered by explicit automation rules

### Phase 2: Agent Automation UI
**Goal**: Parent users can create/manage agent rules

1. AgentAutomationsController (CRUD, restricted to parent user)
2. Template gallery with common patterns
3. HTML views with YAML editor + validation feedback
4. Markdown views for AI agent interface
5. Run history display per agent

### Phase 3: General Automation Rules
**Goal**: Studio-level automations without agents

1. AutomationsController for studio rules
2. Execute `internal_action` type (create_note, etc.)
3. Views following agent automation patterns

### Phase 4: Webhooks & Conditions
1. AutomationWebhookSender for outgoing webhooks
2. AutomationConditionEvaluator with all operators
3. Error handling and notifications

### Phase 5: Schedules & Incoming Webhooks
1. Add `fugit` gem for cron parsing
2. AutomationSchedulerJob (runs every minute)
3. IncomingWebhooksController with signature verification

### Phase 6: User-Level Automations
1. UserAutomationsController
2. User settings UI for personal automation rules

## Template Gallery

Pre-built YAML templates for common agent automation patterns:

| Template | Trigger | Description |
|----------|---------|-------------|
| Respond to mentions | `note.created` + mention_filter: self | Reply when @mentioned |
| Comment responder | `comment.created` | Reply to comments on agent's content |
| Daily summary | Schedule: `0 9 * * *` | Morning activity digest |
| Weekly review | Schedule: `0 9 * * 1` | Monday commitment/decision review |
| Decision helper | `decision.created` | Offer analysis on new decisions |
| Commitment tracker | `commitment.critical_mass` | Celebrate milestones |

Templates are stored as YAML files in `config/automation_templates/` and loaded on demand.

## Verification

1. **Unit tests**: Parser, evaluator, template renderer, mention filter
2. **Integration tests**:
   - Event → dispatcher → finds matching agent rule → triggers task
   - Verify agent NOT triggered when no matching rule exists
3. **Manual test**: Create agent rule via YAML, @ mention agent, verify task runs
4. **E2E test**: Full flow from mention → rule match → task execution → comment posted

**Critical verification**: After removing NotificationDispatcher triggers, agents should do nothing until rules are created.

## Security Considerations

- Agent rules only manageable by parent user (enforce in controller)
- Actions run as rule creator (enforce authorization)
- Sanitize template output (prevent XSS)
- HMAC signature verification for incoming webhooks
- Rate limit executions per rule/agent (carry over from existing 3/min limit)
- Never log webhook secrets
