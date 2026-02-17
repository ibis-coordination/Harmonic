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

  t.string :trigger_type, null: false  # 'event', 'schedule', 'webhook', 'manual'
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
| `WebhookDeliveryService` | Send outgoing HTTP webhooks with retries |

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

### Phase 3.5: Webhook System Consolidation
**Goal**: Unify webhook configuration under automations while preserving delivery infrastructure

The legacy `Webhook` model is redundant with `AutomationRule`. We consolidate to:
- **One way to configure** webhooks → `AutomationRule`
- **One way to deliver/track** webhooks → `WebhookDelivery` + retry infrastructure

#### Architecture

```
AutomationRule (configuration)
    ↓ triggers
AutomationRuleRun (rule execution)
    ↓ executes webhook action
WebhookDelivery (delivery tracking, retries)
    ↓ sends HTTP
WebhookDeliveryService (HTTP + HMAC signing)
```

Traceability chain: `AutomationRule` → `AutomationRuleRun` → `WebhookDelivery` → response

#### Remove (configuration layer)

| File | Reason |
|------|--------|
| `app/models/webhook.rb` | Replaced by AutomationRule |
| `app/controllers/webhooks_controller.rb` | Replaced by StudioAutomationsController |
| `app/controllers/user_webhooks_controller.rb` | Replaced by future UserAutomationsController |
| `app/views/webhooks/` | Replaced by automation views |
| `app/views/user_webhooks/` | Replaced by automation views |
| `app/services/webhook_dispatcher.rb` | Replaced by AutomationDispatcher |
| `app/services/webhook_test_service.rb` | Rebuild as AutomationTestService |
| `test/models/webhook_test.rb` | No longer needed |
| `test/controllers/webhooks_controller_test.rb` | No longer needed |
| `test/controllers/user_webhooks_controller_test.rb` | No longer needed |
| `test/services/webhook_dispatcher_test.rb` | No longer needed |

#### Keep (delivery infrastructure)

| File | Purpose |
|------|---------|
| `app/models/webhook_delivery.rb` | Track individual delivery attempts |
| `app/services/webhook_delivery_service.rb` | HTTP sending with HMAC signatures |
| `app/jobs/webhook_delivery_job.rb` | Async delivery |
| `app/jobs/webhook_retry_job.rb` | Retry failed deliveries |

#### Modify

**1. Database migration:**
```ruby
# Add automation_rule_run reference to webhook_deliveries
add_reference :webhook_deliveries, :automation_rule_run, type: :uuid, foreign_key: true

# Make webhook_id optional (was required)
change_column_null :webhook_deliveries, :webhook_id, true

# Later: drop webhooks table after migration complete
drop_table :webhooks
```

**2. WebhookDelivery model:**
- Add `belongs_to :automation_rule_run, optional: true`
- Make `belongs_to :webhook` optional
- Add validation: must have either `webhook_id` OR `automation_rule_run_id`

**3. AutomationExecutor webhook action:**
- Create `WebhookDelivery` record with `automation_rule_run_id`
- Queue `WebhookDeliveryJob` for async delivery with retries
- Store delivery result in `actions_executed` array

**4. Routes:**
- Remove `/studios/:handle/settings/webhooks` routes
- Remove `/u/:handle/settings/webhooks` routes
- Keep automation routes (already exist)

**6. Settings navigation:**
- Remove "Webhooks" link from studio settings
- Remove "Webhooks" link from user settings
- "Automations" becomes the single entry point

**7. EventService:**
- Remove `WebhookDispatcher.dispatch(event)` call
- `AutomationDispatcher.dispatch(event)` handles everything

#### Add

**1. "Simple Webhook" automation template:**
```yaml
name: "Webhook: {{event_types}}"
description: "Send HTTP POST when events occur"

trigger:
  type: event
  event_type: note.created  # User selects from dropdown

actions:
  - type: webhook
    url: "{{url}}"  # User provides
    body:
      event: "{{event.type}}"
      actor: "{{event.actor.name}}"
      subject: "{{subject.title}}"
      url: "{{subject.path}}"
```

**2. Test automation feature:**
- "Send Test" button on automation show page
- Creates synthetic event and runs automation
- Shows delivery result inline

**3. Delivery history in automation UI:**
- Show recent `WebhookDelivery` records linked to automation's runs
- Display status, response code, attempt count, timestamps

### Phase 4: Webhooks & Conditions
1. ~~AutomationWebhookSender for outgoing webhooks~~ (now uses WebhookDelivery)
2. AutomationConditionEvaluator with all operators
3. Error handling and notifications

### Phase 5: Schedules & Incoming Webhooks
1. Add `fugit` gem for cron parsing
2. AutomationSchedulerJob (runs every minute)
3. IncomingWebhooksController with signature verification

### Phase 6: User-Level Automations
1. UserAutomationsController
2. User settings UI for personal automation rules

### Phase 7: Manual Triggers & Automation Testing
**Goal**: Allow users to manually run automations and test any automation type

#### Manual Trigger Type

A new trigger type that only executes when a user explicitly clicks "Run":

```yaml
name: "Weekly Report Generator"
description: "Generate a weekly report on demand"

trigger:
  type: manual
  # Optional: default input values shown in the run dialog
  inputs:
    date_range:
      type: string
      default: "last_week"
      label: "Date Range"
      options: ["last_week", "last_month", "custom"]

actions:
  - type: internal_action
    action: create_note
    params:
      text: "Report for {{inputs.date_range}}: ..."

  - type: webhook
    url: "https://api.example.com/report"
    body:
      range: "{{inputs.date_range}}"
```

**Use cases**:
- On-demand scripts users can trigger via button click
- Reports, cleanup tasks, batch operations
- Automations that don't fit event/schedule patterns
- Testing new automations before enabling automatic triggers

**Model changes**:
- Add `'manual'` to `AutomationRule::TRIGGER_TYPES`
- `trigger_source` in runs already supports `'manual'`

**Controller additions**:
- `POST /studios/:handle/settings/automations/:id/run` - execute automation
- `POST /u/:handle/settings/ai-agents/:agent_handle/automations/:id/run` - agent version

#### AutomationTestService

A general service for testing any automation type, replacing the removed `WebhookTestService`:

```ruby
# app/services/automation_test_service.rb
class AutomationTestService
  # Run an automation with test data
  # Returns: AutomationRuleRun with detailed execution results
  def self.test!(automation_rule, options = {})
    # Build appropriate test context based on trigger type
    # Execute synchronously for immediate feedback
    # Return run with actions_executed details
  end

  # Generate sample event for event-triggered automations
  def self.build_test_event(rule)
    # Create synthetic event matching rule's event_type
  end

  # Generate sample webhook payload for webhook-triggered automations
  def self.build_test_webhook_payload(rule)
    # Create synthetic incoming webhook payload
  end
end
```

**Behavior per trigger type**:

| Trigger Type | Test Behavior |
|--------------|---------------|
| `event` | Build synthetic event matching `event_type`, execute rule |
| `schedule` | Execute immediately with current timestamp |
| `webhook` | Build synthetic webhook payload, execute rule |
| `manual` | Execute with default or provided inputs |

**UI additions**:
- "Test" button on automation show/edit page
- Shows test result inline (success/failure, actions executed)
- For webhook actions: shows delivery status, response preview
- Dry-run mode option: validate without side effects

**Controller actions**:
- `POST /studios/:handle/settings/automations/:id/test`
- `POST /u/:handle/settings/ai-agents/:agent_handle/automations/:id/test`

#### Files to Create

- `app/services/automation_test_service.rb`
- `test/services/automation_test_service_test.rb`

#### Files to Modify

- `app/models/automation_rule.rb` - add `'manual'` trigger type
- `app/services/automation_yaml_parser.rb` - validate manual trigger config
- `app/controllers/studio_automations_controller.rb` - add `run` and `test` actions
- `app/controllers/agent_automations_controller.rb` - add `run` and `test` actions
- `app/views/studio_automations/show.html.erb` - add Run/Test buttons
- `config/routes.rb` - add run/test routes

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

## Chain-Aware Execution (Cascade & Loop Prevention)

### Problem Statement

Automations can create content (via `internal_action`) that generates events, which can trigger other automations. Without safeguards, this creates risks:

1. **Infinite loops**: Automation A → creates note → triggers Automation B → creates note → triggers Automation A
2. **Cascade explosion**: One event triggers many automations, each creating content that triggers more
3. **Resource exhaustion**: Unbounded execution consuming database, queue, and API resources

### Solution: AutomationChain Context

Extend `AutomationContext` to carry **chain metadata** that flows through the entire execution:

```ruby
{
  depth: 0,                    # How deep in the chain (0 = original trigger)
  executed_rule_ids: Set[],    # Which rules have run (for loop detection)
  origin_event_id: "...",      # The event that started this chain
}
```

### Three Complementary Protections

| Protection | What It Prevents | Default | Configurable |
|------------|------------------|---------|--------------|
| **Max depth** | A→B→C→D→E→... (deep chains) | 3 | Future |
| **Loop detection** | A→B→A (same rule executing twice) | Automatic | No |
| **Max rules per chain** | Fan-out explosion (one event → many rules) | 10 | Future |

### How It Works

1. **On rule match** (`AutomationDispatcher.queue_rule_execution`):
   - Check `AutomationContext.can_execute_rule?(rule)`
   - If blocked, log and skip (don't queue the run)
   - If allowed, record execution and increment depth

2. **Through background jobs** (`AutomationRuleExecutionJob`):
   - Serialize chain metadata into job arguments
   - Restore chain context before executing
   - Child automations inherit parent's chain state

3. **On content creation** (via `AutomationInternalActionService`):
   - Events are created normally via `EventService.record!`
   - When `AutomationDispatcher.dispatch` runs, it sees the existing chain context
   - Chain limits are checked before queueing any triggered rules

### Database Changes

Add `chain_metadata` to `automation_rule_runs`:

```ruby
add_column :automation_rule_runs, :chain_metadata, :jsonb, default: {}
```

This stores:
- The chain state when this run was queued (for debugging)
- Enables tracing the full chain of executions

### Implementation

#### AutomationContext Extensions

```ruby
module AutomationContext
  MAX_CHAIN_DEPTH = 3
  MAX_RULES_PER_CHAIN = 10

  def self.current_chain
    Thread.current[:automation_chain] ||= new_chain
  end

  def self.new_chain
    { depth: 0, executed_rule_ids: Set.new, origin_event_id: nil }
  end

  def self.can_execute_rule?(rule)
    chain = current_chain
    return false if chain[:depth] >= MAX_CHAIN_DEPTH
    return false if chain[:executed_rule_ids].include?(rule.id)
    return false if chain[:executed_rule_ids].size >= MAX_RULES_PER_CHAIN
    true
  end

  def self.record_rule_execution!(rule, event)
    chain = current_chain
    chain[:depth] += 1
    chain[:executed_rule_ids] << rule.id
    chain[:origin_event_id] ||= event&.id
  end

  def self.chain_to_hash
    chain = current_chain
    {
      depth: chain[:depth],
      executed_rule_ids: chain[:executed_rule_ids].to_a,
      origin_event_id: chain[:origin_event_id],
    }
  end

  def self.restore_chain!(hash)
    return if hash.blank?
    Thread.current[:automation_chain] = {
      depth: hash["depth"] || hash[:depth] || 0,
      executed_rule_ids: Set.new(hash["executed_rule_ids"] || hash[:executed_rule_ids] || []),
      origin_event_id: hash["origin_event_id"] || hash[:origin_event_id],
    }
  end

  def self.clear_chain!
    Thread.current[:automation_chain] = nil
  end
end
```

#### AutomationDispatcher Changes

```ruby
def self.queue_rule_execution(rule, event)
  # Chain protection (applies to ALL rules)
  unless AutomationContext.can_execute_rule?(rule)
    Rails.logger.info(
      "[AutomationDispatcher] Chain limit reached for rule #{rule.id}: " \
      "depth=#{AutomationContext.current_chain[:depth]}, " \
      "rules=#{AutomationContext.current_chain[:executed_rule_ids].size}"
    )
    return
  end

  # Record this execution in the chain BEFORE rate limit check
  # (so even rate-limited rules count toward chain limits)
  AutomationContext.record_rule_execution!(rule, event)

  # Existing rate limit for agent rules...
  if rule.agent_rule?
    recent_runs = AutomationRuleRun
      .where(automation_rule: rule, tenant_id: event.tenant_id)
      .where("created_at > ?", 1.minute.ago)
      .count

    if recent_runs >= 3
      Rails.logger.info("Rate limiting automation rule #{rule.id}")
      return
    end
  end

  # Store chain metadata in the run for debugging/tracing
  run = AutomationRuleRun.create!(
    # ... existing fields ...
    chain_metadata: AutomationContext.chain_to_hash,
  )

  # Pass chain through to background job
  AutomationRuleExecutionJob.perform_later(
    automation_rule_run_id: run.id,
    tenant_id: run.tenant_id,
    chain: AutomationContext.chain_to_hash
  )
end
```

#### AutomationRuleExecutionJob Changes

```ruby
def perform(automation_rule_run_id:, tenant_id:, chain: nil)
  # Restore chain context from parent execution
  AutomationContext.restore_chain!(chain) if chain.present?

  # ... existing tenant/superagent setup ...

  # Execute with chain context in place
  # Any events created during execution will inherit this chain
  AutomationExecutor.execute(run)
ensure
  # Clear chain context when job completes
  AutomationContext.clear_chain!
end
```

### Rate Limiting Extension

In addition to chain protection, extend the existing rate limit to ALL automation rules:

```ruby
def self.queue_rule_execution(rule, event)
  # ... chain protection ...

  # Rate limit for ALL rules (not just agent rules)
  recent_runs = AutomationRuleRun
    .where(automation_rule: rule, tenant_id: event.tenant_id)
    .where("created_at > ?", 1.minute.ago)
    .count

  max_per_minute = rule.agent_rule? ? 3 : 10  # More lenient for studio rules

  if recent_runs >= max_per_minute
    Rails.logger.info("Rate limiting automation rule #{rule.id}")
    return
  end

  # ... rest of method ...
end
```

### Verification

1. **Unit tests**:
   - `AutomationContext` chain tracking methods
   - `can_execute_rule?` returns false at depth limit
   - `can_execute_rule?` returns false for repeated rules
   - Chain serialization/deserialization round-trips correctly

2. **Integration tests**:
   - Automation A creates note → triggers Automation B → chain depth = 2
   - Automation A creates note → triggers Automation A again → blocked (loop)
   - Chain at max depth → new automations not queued
   - Chain metadata stored in `automation_rule_runs`

3. **Manual test**:
   - Create two automations that would trigger each other
   - Verify chain stops at depth limit
   - Check logs show chain limit messages

### Future Enhancements

1. **User-configurable limits** (per-rule YAML):
   ```yaml
   chain:
     max_depth: 5           # Override default
     allow_self_trigger: true  # Allow this rule in chain multiple times
   ```

2. **Exclude automation-created events** (trigger filter):
   ```yaml
   trigger:
     type: event
     event_type: note.created
     exclude_automation_created: true
   ```

3. **Chain visualization**: Show chain graph in automation run details UI

4. **Tenant-level limits**: Global limits on automations per tenant per minute
