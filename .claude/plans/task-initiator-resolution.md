# Task Initiator Resolution

## Context

We want to formalize who the "initiator" of an agent task run is, so that downstream features (dynamic billing, opening chat to non-parents, collective billing) can rely on a well-defined concept. The `initiated_by` field already exists on `AiAgentTaskRun`, but its semantics vary by context and it doesn't always represent the person who should bear responsibility (e.g., financial) for the task run.

This plan focuses **only** on defining and correctly resolving the task initiator. Stripe customer assignment and collective billing are separate follow-up plans.

## Current State of `initiated_by`

| Context | Current `initiated_by` value | Set in |
|---------|------------------------------|--------|
| Manual task run | `current_user` (the human clicking "run") | `ai_agents_controller.rb` |
| Chat message | `current_user` (the human sending the message) | `chats_controller.rb` |
| Auto-dispatch chat turn | The human participant in the chat | `agent_runner_controller.rb` |
| Event automation (agent rule) | `event.actor` or `rule.created_by` | `automation_executor.rb:81` |
| Event automation (trigger_agent action) | `event.actor` or `rule.created_by` | `automation_executor.rb:291` |

## The Problem

`initiated_by` conflates two different concepts:

1. **Who caused this task to exist?** (attribution/audit)
2. **Who bears responsibility for this task?** (billing, authorization)

For direct interactions (chat, manual run), these are the same person. For automations, they diverge:

- A user @mentions an agent in a note → the event actor **caused** the task, but the **rule creator** set up the automation and opted into the cost
- A scheduled automation fires → nobody "caused" it in the moment, the rule creator is responsible
- A webhook fires → external system caused it, rule creator is responsible

## Proposed Design

### Add a `responsible_party` concept

Rather than overloading `initiated_by`, introduce a `responsible_party_id` column on `AiAgentTaskRun` that explicitly answers "who bears responsibility for this task run?"

| Context | `initiated_by` (who caused it) | `responsible_party` (who's responsible) |
|---------|-------------------------------|----------------------------------------|
| Manual task run | The user who clicked run | Same as `initiated_by` |
| Chat message | The message sender | Same as `initiated_by` |
| Auto-dispatch chat turn | The human in the chat | Same as `initiated_by` |
| Scheduled automation | `rule.created_by` | `rule.created_by` |
| Webhook automation | `rule.created_by` | `rule.created_by` |
| Manual automation trigger | The user who triggered it | Same as `initiated_by` |
| Event automation (non-mention) | `event.actor` | `rule.created_by` |
| @mention automation | `event.actor` (the mentioner) | `rule.created_by` |

### Why `responsible_party` defaults to rule creator for all automations

- **Consent**: The rule creator explicitly chose to set up an automation that consumes tokens
- **No surprise bills**: Event actors (especially for non-mention events) may not know automations exist
- **@mentions are tricky but rule creator still wins**: Even though @mentioning is an explicit action, the rule creator decided to wire up the mention trigger — they accepted responsibility for what that costs. The mentioner is just using the feature the rule creator enabled.
- **Abuse protection**: If event actors paid, a malicious rule creator could set up automations that bill other users

### Future flexibility

The `responsible_party` concept is deliberately generic. When collective billing is implemented later, `responsible_party` could point to a collective's representative user or a collective-level billing entity, without changing the schema again.

## Considerations and Tradeoffs

### Abuse vectors when rule creator pays

Other users can cause the rule creator to spend tokens by:

- **@mentions**: Writing `@agent-a do something` in a note
- **Event triggers**: Creating content that matches a rule's trigger (e.g., "when any note is created")
- **Rate limits help**: Agent rules are capped at 3 executions/min, tenant-wide cap of 100/min

### Potential mitigations (future work, not in this plan)

1. Per-rule spending caps
2. Approval mode for mention-triggered runs
3. Credit balance alerts
4. Billing the mentioner for @mentions specifically (opt-in per rule)

## Implementation Plan

### Step 1: Add `responsible_party_id` column

Migration to add `responsible_party_id` (UUID, foreign key to `users`, not null) to `ai_agent_task_runs`.

### Step 2: Add model association and resolution logic

**File**: [ai_agent_task_run.rb](app/models/ai_agent_task_run.rb)

- Add `belongs_to :responsible_party, class_name: "User"`
- Add a class method or factory method that resolves the responsible party based on context:

```ruby
def self.resolve_responsible_party(initiated_by:, automation_rule:)
  if automation_rule.present?
    automation_rule.created_by
  else
    initiated_by
  end
end
```

### Step 3: Set `responsible_party` at all creation sites

Update all 5 creation sites to set `responsible_party_id`:

1. **`ai_agents_controller.rb`** (manual task run): `responsible_party: current_user`
2. **`chats_controller.rb`** (chat message): `responsible_party: current_user`
3. **`agent_runner_controller.rb`** (auto-dispatch chat): `responsible_party: human` (the chat participant)
4. **`automation_executor.rb:84`** (agent rule): `responsible_party: @rule.created_by`
5. **`automation_executor.rb:293`** (trigger_agent action): `responsible_party: @rule.created_by`

### Step 4: Backfill existing records

Data migration to populate `responsible_party_id` for existing task runs:
- If `automation_rule_id` is present: set to `automation_rule.created_by_id`
- Otherwise: set to `initiated_by_id`

### Step 5: Tests

- Test that `responsible_party` equals `initiated_by` for direct interactions (chat, manual run)
- Test that `responsible_party` equals `rule.created_by` for all automation contexts (event, schedule, webhook, manual trigger with automation rule)
- Test that `responsible_party` equals `rule.created_by` even when `initiated_by` is a different user (the @mention / event actor case)
- Test the `resolve_responsible_party` helper method

### Verification

```bash
docker compose exec web bundle exec rails test test/models/ai_agent_task_run_test.rb test/controllers/chats_controller_test.rb test/services/automation_executor_test.rb
```
