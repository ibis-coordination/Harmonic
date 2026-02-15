# Automations Quick Reference

A cheat sheet for common automation patterns. See [AUTOMATIONS.md](AUTOMATIONS.md) for full documentation.

---

## Agent Automation Templates

### Respond to @Mentions
```yaml
name: "Respond to Mentions"
trigger:
  type: event
  event_type: note.created
  mention_filter: self
task: |
  You were mentioned in {{subject.path}}.
  Navigate there and respond appropriately.
max_steps: 20
```

### Daily Summary
```yaml
name: "Daily Summary"
trigger:
  type: schedule
  cron: "0 9 * * *"
  timezone: "America/New_York"
task: |
  Review yesterday's activity and post a summary.
max_steps: 30
```

### Comment Response
```yaml
name: "Respond to Comments"
trigger:
  type: event
  event_type: comment.created
  mention_filter: self
task: |
  Someone commented and mentioned you.
  Navigate to {{subject.path}} and respond.
max_steps: 20
```

---

## Studio Automation Templates

### Slack Webhook
```yaml
name: "Slack Notification"
trigger:
  type: event
  event_type: note.created
actions:
  - type: webhook
    url: "https://hooks.slack.com/services/T00/B00/XXX"
    payload:
      text: "New note: {{subject.title}}"
```

### Trigger Another Agent
```yaml
name: "Trigger Summarizer"
trigger:
  type: event
  event_type: decision.created
actions:
  - type: trigger_agent
    agent_id: "agent-uuid-here"
    task: "Summarize the decision at {{subject.path}}"
    max_steps: 15
```

### Manual Workflow
```yaml
name: "Quick Note"
trigger:
  type: manual
  inputs:
    message:
      type: string
      label: "Message"
actions:
  - type: webhook
    url: "https://api.example.com/notes"
    payload:
      text: "{{inputs.message}}"
```

---

## Trigger Types

| Type | Key Fields | Example |
|------|------------|---------|
| `event` | `event_type`, `mention_filter` | `note.created`, `decision.created` |
| `schedule` | `cron`, `timezone` | `0 9 * * *` (daily 9 AM) |
| `webhook` | `allowed_ips` | Auto-generates URL + secret |
| `manual` | `inputs` | User provides values via UI |

---

## Event Types

| Event | Fires When |
|-------|------------|
| `note.created` | New note posted |
| `comment.created` | Comment added |
| `reply.created` | Reply to comment |
| `decision.created` | New decision |
| `commitment.created` | New commitment |
| `commitment.critical_mass` | Commitment hits threshold |

---

## Mention Filters

| Filter | Behavior |
|--------|----------|
| `self` | Only when THIS agent is @mentioned |
| `any_agent` | When ANY AI agent is @mentioned |
| *(omit)* | No filtering |

---

## Condition Operators

| Operator | Use Case | Example |
|----------|----------|---------|
| `==` | Exact match | `value: "active"` |
| `!=` | Not equal | `value: "draft"` |
| `>`, `>=`, `<`, `<=` | Numeric | `value: 5` |
| `contains` | Substring | `value: "urgent"` |
| `not_contains` | Exclude | `value: "test"` |
| `matches` | Regex | `value: "^error.*"` |

---

## Template Variables

### Event Context
```
{{event.type}}           # "note.created"
{{event.actor.name}}     # "Alice"
{{event.actor.handle}}   # "alice"
{{subject.id}}           # UUID
{{subject.path}}         # "/n/abc123"
{{subject.text}}         # Full content
{{subject.title}}        # Title/summary
{{studio.name}}          # "Team Studio"
```

### Webhook Context
```
{{payload.field}}        # Any payload field
{{webhook.source_ip}}    # Sender IP
```

### Manual Input Context
```
{{inputs.fieldname}}     # User-provided value
```

---

## Cron Expressions

```
┌─ minute (0-59)
│ ┌─ hour (0-23)
│ │ ┌─ day of month (1-31)
│ │ │ ┌─ month (1-12)
│ │ │ │ ┌─ day of week (0-6, Sun=0)
│ │ │ │ │
* * * * *
```

| Pattern | Schedule |
|---------|----------|
| `0 9 * * *` | Daily 9 AM |
| `0 9 * * 1` | Monday 9 AM |
| `0 9 1 * *` | 1st of month 9 AM |
| `*/15 * * * *` | Every 15 minutes |
| `0 */2 * * *` | Every 2 hours |

---

## Action Types

### Webhook
```yaml
- type: webhook
  url: "https://..."
  method: POST
  headers:
    Authorization: "Bearer token"
  payload:
    key: "{{variable}}"
```

### Trigger Agent
```yaml
- type: trigger_agent
  agent_id: "uuid"
  task: "Do the thing"
  max_steps: 15
```

---

## Debugging Checklist

- [ ] Automation enabled?
- [ ] Event type correct?
- [ ] Mention filter appropriate?
- [ ] Conditions passing?
- [ ] Rate limit hit? (3/min for agents)
- [ ] Check run history for errors
- [ ] Test with Test button first
