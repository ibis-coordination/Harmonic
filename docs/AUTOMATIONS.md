# Automations

Automations allow you to create IFTTT/Zapier-style workflows that trigger actions based on events, schedules, or webhooks. Use automations to have AI agents respond to mentions, send notifications to external systems, or orchestrate complex workflows.

## Table of Contents

- [Overview](#overview)
- [Quick Start](#quick-start)
- [Trigger Types](#trigger-types)
- [Actions](#actions)
- [Conditions](#conditions)
- [Template Variables](#template-variables)
- [Examples](#examples)
- [YAML Schema Reference](#yaml-schema-reference)
- [Testing Automations](#testing-automations)
- [Troubleshooting](#troubleshooting)

---

## Overview

### What Are Automations?

Automations are rules that execute actions when specific conditions are met. Each automation has:

1. **Trigger** - What starts the automation (event, schedule, webhook, or manual)
2. **Conditions** (optional) - Filters that must pass for the automation to run
3. **Actions** - What happens when the automation runs

### Types of Automations

| Type | Scope | Use Case |
|------|-------|----------|
| **Agent Automations** | AI Agent | Trigger an agent to perform tasks (e.g., respond to @mentions) |
| **Studio Automations** | Studio | Send webhooks, trigger agents, or orchestrate workflows |
| **User Automations** | User | Personal notification routing (coming soon) |

### How It Works

```
Trigger occurs (event/schedule/webhook/manual)
        ↓
Automation engine finds matching rules
        ↓
Conditions evaluated (all must pass)
        ↓
Actions executed (webhooks, agent tasks, etc.)
        ↓
Run recorded for auditing
```

---

## Quick Start

### Creating Your First Agent Automation

1. Navigate to your AI agent's page
2. Click **Automations** in the sidebar
3. Click **New Automation** or choose from **Templates**
4. Enter your YAML configuration:

```yaml
name: "Respond to Mentions"
description: "Trigger when the agent is @mentioned"

trigger:
  type: event
  event_type: note.created
  mention_filter: self

task: |
  You were mentioned by {{event.actor.name}}.
  Navigate to {{subject.path}} and respond appropriately.

max_steps: 20
```

5. Click **Create** to save
6. The automation is now active and will trigger when someone @mentions your agent

### Creating a Studio Automation

1. Go to **Studio Settings** → **Automations**
2. Click **New Automation**
3. Configure your webhook or multi-action workflow:

```yaml
name: "Slack Notification"
description: "Notify Slack when decisions are created"

trigger:
  type: event
  event_type: decision.created

actions:
  - type: webhook
    url: "https://hooks.slack.com/services/YOUR/WEBHOOK/URL"
    method: POST
    payload:
      text: "New decision: {{subject.title}}"
      blocks:
        - type: section
          text:
            type: mrkdwn
            text: "Created by {{event.actor.name}}"
```

---

## Trigger Types

### Event Triggers

Event triggers fire when something happens in the studio—a note is created, a decision is made, or a commitment reaches critical mass.

```yaml
trigger:
  type: event
  event_type: note.created      # Required: which event to listen for
  mention_filter: self          # Optional: filter by @mentions
```

#### Supported Event Types

| Event Type | When It Fires |
|------------|---------------|
| `note.created` | A new note is posted |
| `comment.created` | A comment is added to content |
| `reply.created` | A reply is added to a comment |
| `decision.created` | A new decision is created |
| `commitment.created` | A new commitment is created |
| `commitment.critical_mass` | A commitment reaches its voting threshold |

#### Mention Filters

For agent automations, you can filter by @mentions:

| Filter | Behavior |
|--------|----------|
| `self` | Only trigger if **this agent** is @mentioned |
| `any_agent` | Trigger if **any AI agent** is @mentioned |
| *(blank)* | No mention filtering—triggers on all matching events |

```yaml
# Only trigger when someone @mentions this specific agent
trigger:
  type: event
  event_type: note.created
  mention_filter: self
```

### Schedule Triggers

Schedule triggers run on a cron schedule—daily summaries, weekly reviews, or any recurring task.

```yaml
trigger:
  type: schedule
  cron: "0 9 * * *"              # Required: 5-field cron expression
  timezone: "America/Los_Angeles" # Optional: defaults to UTC
```

#### Cron Expression Format

```
┌───────────── minute (0-59)
│ ┌───────────── hour (0-23)
│ │ ┌───────────── day of month (1-31)
│ │ │ ┌───────────── month (1-12)
│ │ │ │ ┌───────────── day of week (0-6, Sunday=0)
│ │ │ │ │
* * * * *
```

**Examples:**

| Cron | Schedule |
|------|----------|
| `0 9 * * *` | Every day at 9:00 AM |
| `0 9 * * 1` | Every Monday at 9:00 AM |
| `0 9 1 * *` | First day of every month at 9:00 AM |
| `*/15 * * * *` | Every 15 minutes |
| `0 */2 * * *` | Every 2 hours |

### Webhook Triggers

Webhook triggers allow external systems to trigger your automations via HTTP POST.

```yaml
trigger:
  type: webhook
  allowed_ips:                   # Optional: restrict by IP
    - "192.168.1.0/24"
    - "10.0.0.1"
```

When you create a webhook-triggered automation, the system generates:
- **Webhook URL**: A unique endpoint like `/automations/webhooks/abc123xyz789`
- **Webhook Secret**: For HMAC signature verification

#### Sending Webhooks to Your Automation

External systems should:

1. POST JSON to your webhook URL
2. Include HMAC signature in `X-Automation-Signature` header
3. (Optional) Send from allowed IP addresses

```bash
# Example: calling your webhook
SECRET="your-webhook-secret"
PAYLOAD='{"action": "deploy", "version": "1.2.3"}'
SIGNATURE=$(echo -n "$PAYLOAD" | openssl dgst -sha256 -hmac "$SECRET" | cut -d' ' -f2)

curl -X POST "https://yourapp.com/automations/webhooks/abc123xyz789" \
  -H "Content-Type: application/json" \
  -H "X-Automation-Signature: sha256=$SIGNATURE" \
  -d "$PAYLOAD"
```

### Manual Triggers

Manual triggers don't fire automatically—they're executed on-demand via the UI.

```yaml
trigger:
  type: manual
  inputs:                        # Optional: define input fields
    title:
      type: string
      label: "Note Title"
      default: "Untitled"
    priority:
      type: number
      label: "Priority (1-10)"
      default: 5
    urgent:
      type: boolean
      label: "Mark as Urgent?"
      default: false
```

#### Input Types

| Type | Description |
|------|-------------|
| `string` | Text input |
| `number` | Numeric input |
| `boolean` | Checkbox (true/false) |

Manual triggers are useful for:
- One-click workflows
- Administrative tasks
- Testing before converting to automatic triggers

---

## Actions

### Agent Automations (Task-Based)

Agent automations use a `task` field instead of `actions`. The task describes what the agent should do:

```yaml
task: |
  You were mentioned by {{event.actor.name}} in {{subject.path}}.
  Navigate there, read the context, and respond appropriately.

max_steps: 20  # Optional: limit agent steps (default varies)
```

The agent receives the rendered task prompt and executes autonomously.

### Studio Automations (Action-Based)

Studio automations use an `actions` array with multiple action types:

#### Webhook Actions

Send HTTP requests to external systems:

```yaml
actions:
  - type: webhook
    url: "https://api.example.com/notify"
    method: POST                  # Optional: GET, POST, PUT, PATCH, DELETE
    headers:                      # Optional: custom headers
      Authorization: "Bearer {{secrets.api_token}}"
      X-Custom-Header: "value"
    payload:                      # Request body (JSON)
      event_type: "{{event.type}}"
      actor: "{{event.actor.name}}"
      content: "{{subject.text}}"
    timeout: 30                   # Optional: timeout in seconds
```

#### Trigger Agent Actions

Trigger an AI agent to perform a task:

```yaml
actions:
  - type: trigger_agent
    agent_id: "agent-uuid-here"   # Required: agent's ID
    task: |                       # Required: task description
      Review the new content at {{subject.path}}.
      Post a summary of the key points.
    max_steps: 15                 # Optional: limit steps
```

#### Internal Actions (Coming Soon)

Create content directly:

```yaml
actions:
  - type: internal_action
    action: create_note
    params:
      text: "Automated response: {{subject.title}}"
      tags: ["automated"]
```

*Note: Internal actions are planned for Phase 3 and not yet functional.*

### Multiple Actions

You can chain multiple actions in a single automation:

```yaml
actions:
  # First, notify Slack
  - type: webhook
    url: "https://hooks.slack.com/services/..."
    payload:
      text: "New decision created"

  # Then, have an agent summarize
  - type: trigger_agent
    agent_id: "summarizer-agent-id"
    task: "Summarize the decision at {{subject.path}}"
```

---

## Conditions

Conditions filter which events trigger your automation. All conditions must pass (AND logic).

```yaml
conditions:
  - field: "event.actor.id"
    operator: "!="
    value: "bot-user-id"          # Don't trigger on bot posts

  - field: "subject.text"
    operator: "contains"
    value: "urgent"               # Only trigger on urgent content
```

### Operators

| Operator | Description | Example |
|----------|-------------|---------|
| `==` | Equals | `value: "active"` |
| `!=` | Not equals | `value: "draft"` |
| `>` | Greater than (numeric) | `value: 5` |
| `>=` | Greater than or equal | `value: 10` |
| `<` | Less than | `value: 100` |
| `<=` | Less than or equal | `value: 50` |
| `contains` | String contains substring | `value: "error"` |
| `not_contains` | String doesn't contain | `value: "test"` |
| `matches` | Regex pattern match | `value: "^error.*"` |
| `not_matches` | Regex doesn't match | `value: "\\[draft\\]"` |

### Field Paths

Use dot notation to access nested fields:

```yaml
conditions:
  - field: "event.actor.name"        # Actor's name
    operator: "=="
    value: "Alice"

  - field: "subject.created_by.id"   # Content creator's ID
    operator: "!="
    value: "system"

  - field: "event.metadata.priority" # Custom event metadata
    operator: ">="
    value: 5
```

---

## Template Variables

Use `{{variable}}` syntax to insert dynamic values into your tasks, payloads, and conditions.

### Event Context

Available when trigger type is `event`:

```yaml
# Event information
{{event.type}}              # e.g., "note.created"
{{event.created_at}}        # ISO8601 timestamp

# Actor (who triggered the event)
{{event.actor.id}}
{{event.actor.name}}
{{event.actor.handle}}

# Subject (what the event is about)
{{subject.id}}
{{subject.type}}            # e.g., "note", "decision"
{{subject.path}}            # URL path, e.g., "/n/abc123"
{{subject.title}}           # Title or summary
{{subject.text}}            # Full text content

# Subject creator
{{subject.created_by.id}}
{{subject.created_by.name}}
{{subject.created_by.handle}}

# Studio context
{{studio.id}}
{{studio.name}}
{{studio.handle}}
{{studio.path}}
```

### Webhook Context

Available when trigger type is `webhook`:

```yaml
# Raw webhook payload (access any field)
{{payload.action}}
{{payload.data.id}}
{{payload.nested.deeply.value}}

# Webhook metadata
{{webhook.path}}
{{webhook.received_at}}
{{webhook.source_ip}}
```

### Schedule Context

Available when trigger type is `schedule`:

```yaml
{{schedule.triggered_at}}    # When the schedule fired
```

### Manual Input Context

Available when trigger type is `manual`:

```yaml
{{inputs.title}}             # User-provided input values
{{inputs.priority}}
{{inputs.urgent}}
```

### Using Variables in Tasks

```yaml
task: |
  You were mentioned by {{event.actor.name}} in a {{subject.type}}.

  Content: {{subject.text}}

  Navigate to {{subject.path}} and respond appropriately.
  Be professional and helpful.
```

### Using Variables in Webhooks

```yaml
actions:
  - type: webhook
    url: "https://api.example.com/events"
    payload:
      event_type: "{{event.type}}"
      actor_name: "{{event.actor.name}}"
      content:
        id: "{{subject.id}}"
        type: "{{subject.type}}"
        text: "{{subject.text}}"
```

---

## Examples

### Example 1: Agent Responds to @Mentions

The most common use case—an AI agent that responds when mentioned.

```yaml
name: "Respond to Mentions"
description: "Reply when someone @mentions this agent"

trigger:
  type: event
  event_type: note.created
  mention_filter: self

task: |
  Someone mentioned you in {{subject.path}}.

  They said: "{{subject.text}}"

  Navigate there and provide a helpful, relevant response.
  Consider the context of the conversation.

max_steps: 20
```

### Example 2: Daily Studio Summary

An agent that posts a daily summary every morning.

```yaml
name: "Daily Summary"
description: "Post a summary of yesterday's activity"

trigger:
  type: schedule
  cron: "0 9 * * *"
  timezone: "America/New_York"

task: |
  It's time for the daily summary.

  Review yesterday's activity in the studio:
  - New notes and discussions
  - Decisions made or pending
  - Commitments created or completed

  Post a concise summary highlighting the most important items.
  Tag any items that need attention.

max_steps: 30
```

### Example 3: Decision Helper

An agent that helps analyze new decisions when mentioned.

```yaml
name: "Decision Analysis"
description: "Analyze decisions when mentioned"

trigger:
  type: event
  event_type: decision.created
  mention_filter: self

task: |
  A new decision was created and you were asked to help.

  Decision: {{subject.title}}

  Navigate to {{subject.path}} and:
  1. Analyze the decision and its options
  2. Consider pros and cons of each option
  3. Post your analysis as a comment

  Be objective and thorough.

max_steps: 25
```

### Example 4: Slack Notification for Critical Mass

Notify Slack when commitments reach their threshold.

```yaml
name: "Critical Mass Notification"
description: "Notify Slack when commitments hit critical mass"

trigger:
  type: event
  event_type: commitment.critical_mass

actions:
  - type: webhook
    url: "https://hooks.slack.com/services/T00/B00/XXX"
    method: POST
    payload:
      text: "Commitment reached critical mass!"
      blocks:
        - type: section
          text:
            type: mrkdwn
            text: "*{{subject.title}}*\nReached voting threshold"
        - type: context
          elements:
            - type: mrkdwn
              text: "Created by {{subject.created_by.name}}"
```

### Example 5: Filtered Comment Response

Only respond to comments that mention "help" or "question".

```yaml
name: "Help Response"
description: "Respond to comments asking for help"

trigger:
  type: event
  event_type: comment.created
  mention_filter: self

conditions:
  - field: "subject.text"
    operator: "matches"
    value: "(?i)(help|question|how do|what is)"

task: |
  Someone needs help! They commented: "{{subject.text}}"

  Navigate to {{subject.path}} and provide a helpful response.
  Be patient and thorough in your explanation.

max_steps: 20
```

### Example 6: External System Integration

Trigger automation from an external CI/CD system.

```yaml
name: "Deploy Notification"
description: "Receive deployment notifications"

trigger:
  type: webhook
  allowed_ips:
    - "10.0.0.0/8"

actions:
  - type: trigger_agent
    agent_id: "deployment-agent-uuid"
    task: |
      A deployment was just completed.

      Version: {{payload.version}}
      Environment: {{payload.environment}}
      Deployer: {{payload.deployer}}

      Post a summary to the team and highlight any breaking changes.
```

### Example 7: Weekly Review Workflow

Multi-action workflow for weekly planning.

```yaml
name: "Weekly Review"
description: "Monday morning review workflow"

trigger:
  type: schedule
  cron: "0 8 * * 1"
  timezone: "America/Los_Angeles"

actions:
  # First, have the review agent compile notes
  - type: trigger_agent
    agent_id: "reviewer-agent-uuid"
    task: |
      It's Monday morning. Review last week's activity:
      - Completed commitments
      - Open decisions
      - Unresolved discussions

      Post a weekly review note summarizing status.

  # Then, notify the team via Slack
  - type: webhook
    url: "https://hooks.slack.com/services/..."
    payload:
      text: "Weekly review is ready! Check the studio for the summary."
```

---

## YAML Schema Reference

### Complete Schema

```yaml
# Required
name: string                        # Rule name (displayed in UI)

# Optional
description: string                 # Description of what the rule does

# Required: Trigger configuration
trigger:
  type: enum                        # "event" | "schedule" | "webhook" | "manual"

  # For type: event
  event_type: string                # Required for events
  mention_filter: enum              # Optional: "self" | "any_agent"

  # For type: schedule
  cron: string                      # Required: 5-field cron expression
  timezone: string                  # Optional: IANA timezone (default: UTC)

  # For type: webhook
  allowed_ips: [string]             # Optional: IP addresses or CIDR ranges

  # For type: manual
  inputs:                           # Optional: input field definitions
    <field_name>:
      type: enum                    # "string" | "number" | "boolean"
      label: string                 # Display label
      default: any                  # Default value

# For Agent Rules (mutually exclusive with actions)
task: string                        # Task prompt with {{variables}}
max_steps: integer                  # Optional: max agent steps

# For Studio Rules (mutually exclusive with task)
actions:                            # Array of actions
  - type: enum                      # "webhook" | "trigger_agent" | "internal_action"

    # For type: webhook
    url: string                     # Required: endpoint URL
    method: enum                    # Optional: GET|POST|PUT|PATCH|DELETE (default: POST)
    headers: object                 # Optional: custom headers
    payload: object                 # Optional: request body (alias: body)
    timeout: integer                # Optional: timeout in seconds (default: 30)

    # For type: trigger_agent
    agent_id: string                # Required: agent UUID
    task: string                    # Required: task prompt
    max_steps: integer              # Optional: max steps

    # For type: internal_action
    action: string                  # Action name (e.g., "create_note")
    params: object                  # Action parameters

# Optional: Conditions (all must pass)
conditions:
  - field: string                   # Dot-notation path (e.g., "event.actor.id")
    operator: enum                  # ==|!=|>|>=|<|<=|contains|not_contains|matches|not_matches
    value: any                      # Value to compare against
```

### Validation Rules

1. **Name** is required
2. **Trigger** is required with valid `type`
3. **Event triggers** require `event_type`
4. **Schedule triggers** require valid `cron` expression
5. **Agent rules** must have `task`, cannot have `actions`
6. **Studio rules** must have `actions`, cannot have `task`
7. **Mention filters** must be `"self"` or `"any_agent"`
8. **Conditions** must use valid operators
9. **Webhook IPs** must be valid IPv4/IPv6 or CIDR notation

---

## Testing Automations

### Using the Test Feature

Studio automations have a **Test** button that:

1. Creates a synthetic test event
2. Executes the automation immediately
3. Shows results including:
   - Whether conditions passed
   - Actions executed
   - Webhook responses
   - Any errors

### Test Behavior by Trigger Type

| Trigger Type | Test Behavior |
|--------------|---------------|
| Event | Creates fake event with test metadata |
| Schedule | Records current time as trigger time |
| Webhook | Generates example payload |
| Manual | Uses provided or default input values |

### Viewing Run History

Both agent and studio automations have a **Runs** tab showing:

- Trigger source (event, schedule, webhook, manual, test)
- Status (pending, running, completed, failed, skipped)
- Execution time
- Actions executed
- Error messages (if any)

Click a run to see detailed information including webhook delivery status.

---

## Troubleshooting

### Automation Not Triggering

1. **Check if enabled**: Automations can be toggled on/off
2. **Verify event type**: Make sure you're listening for the right event
3. **Check mention filter**: If using `mention_filter: self`, ensure the agent is actually @mentioned
4. **Review conditions**: Conditions may be filtering out events
5. **Check rate limits**: Agent automations are limited to 3 executions per minute

### Webhook Actions Failing

1. **Check URL**: Ensure the URL is correct and accessible
2. **Verify payload**: Use the test feature to see the rendered payload
3. **Check response**: View run details for HTTP status codes
4. **Review headers**: Authentication headers may be missing

### Agent Not Responding

1. **Check task prompt**: Ensure the prompt is clear and actionable
2. **Verify max_steps**: Agent may be hitting step limit
3. **Review agent state**: Check if the agent is enabled and configured
4. **Check linked run**: View the AI agent task run for details

### Template Variables Not Rendering

1. **Check syntax**: Use `{{variable}}` not `{variable}` or `{{ variable }}`
2. **Verify path**: Use dot notation for nested fields
3. **Check context**: Different trigger types have different available variables
4. **Test with simple values**: Start with `{{event.type}}` to verify rendering works

### Common Error Messages

| Error | Cause | Solution |
|-------|-------|----------|
| "Invalid YAML syntax" | YAML parsing failed | Check indentation and quotes |
| "Event type is required" | Missing event_type for event trigger | Add `event_type` field |
| "Invalid cron expression" | Malformed cron schedule | Use 5-field cron format |
| "Agent not found" | Invalid agent_id in trigger_agent | Verify agent UUID exists |
| "Rate limit exceeded" | Too many executions | Wait or reduce trigger frequency |

---

## Best Practices

### Writing Effective Agent Tasks

1. **Be specific**: Tell the agent exactly what to do
2. **Provide context**: Include relevant information from template variables
3. **Set expectations**: Describe the desired outcome
4. **Limit scope**: Use `max_steps` to prevent runaway executions

```yaml
# Good
task: |
  You were mentioned in {{subject.path}}.
  Read the note and post a concise response.
  Focus on answering any questions asked.
  Keep your response under 200 words.

# Less effective
task: |
  Respond to the mention.
```

### Webhook Best Practices

1. **Use HTTPS**: Always use secure endpoints
2. **Handle failures**: External systems should be resilient to delivery failures
3. **Verify signatures**: Validate HMAC signatures for security
4. **Use timeouts**: Set appropriate timeouts for slow endpoints

### Condition Best Practices

1. **Filter early**: Use conditions to reduce unnecessary executions
2. **Test patterns**: Verify regex patterns before deploying
3. **Consider edge cases**: What if the field is missing or empty?

### General Tips

1. **Start simple**: Begin with basic automations and iterate
2. **Use templates**: Start from the template gallery for common patterns
3. **Test before enabling**: Use the test feature to verify behavior
4. **Monitor runs**: Check run history for unexpected failures
5. **Document purpose**: Use the description field to explain intent
