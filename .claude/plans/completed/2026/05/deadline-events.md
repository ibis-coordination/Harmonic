# Deadline Events

## Problem

When a decision or commitment deadline passes, nothing happens automatically. No event is fired, so automations, webhooks, and agent rules can't react to deadlines. The lottery draw job (`LotteryDrawJob`) works around this by being manually enqueued when someone closes a lottery, but if nobody takes action, deadlines pass silently.

This also means:
- Webhooks can't notify external systems when a deadline passes
- Automations can't trigger actions at deadline time (e.g., post a summary, notify participants)
- Lottery decisions with preset deadlines require manual closing before the draw happens

## Design

### New cron job: `DeadlineEventJob`

A `SystemJob` that runs every minute via sidekiq-cron (same pattern as `ReminderDeliveryJob`). It:

1. Queries for decisions and commitments whose deadlines have passed but haven't had a deadline event fired yet
2. Fires `EventService.record!` for each, producing `decision.deadline_reached` and `commitment.deadline_reached` events
3. These events flow through the existing `AutomationDispatcher` and `NotificationDispatcher`

### Duplicate prevention

Add a `deadline_event_fired_at` timestamp column to both `decisions` and `commitments`. The job sets this after firing the event. The query filters on `deadline < NOW() AND deadline_event_fired_at IS NULL`.

This is simpler and more reliable than querying the events table, and survives event table cleanup.

### Lottery draw as a downstream handler

Instead of `LotteryDrawJob` being enqueued manually from `close_decision`, it becomes a handler for the `decision.deadline_reached` event. Options:

1. **Inline in the job**: `DeadlineEventJob` fires the event, then checks `decision.is_lottery?` and enqueues `LotteryDrawJob`
2. **Via automation dispatch**: An internal/system automation rule listens for `decision.deadline_reached` where subtype is lottery

Option 1 is simpler and keeps the lottery logic explicit. The `LotteryDrawJob` already has all the right guards (checks closed?, is_lottery?, not already drawn), so enqueuing it from the deadline job is safe and idempotent.

The existing `close_decision` path in `ApiHelper` should also continue to enqueue `LotteryDrawJob` — this handles the case where someone manually closes a lottery before the deadline.

### Event metadata

The deadline events should include useful context in metadata:

```ruby
{
  "resource_type" => "decision",  # or "commitment"
  "resource_id" => decision.id,
  "question" => decision.question,
  "subtype" => decision.subtype,
  "deadline" => decision.deadline.iso8601,
}
```

### Tenant/collective context

`DeadlineEventJob` is a `SystemJob` (like `ReminderDeliveryJob`). It queries across all tenants unscoped, then sets tenant/collective context before firing each event via `with_tenant_and_collective_context`.

### Documentation

Add `decision.deadline_reached` and `commitment.deadline_reached` to the automation YAML reference so users can write automations triggered by deadlines.

## Scope

- Migration: add `deadline_event_fired_at` to decisions and commitments
- New job: `DeadlineEventJob` (system job, cron every minute)
- Update `sidekiq_cron.rb` to register the job
- Enqueue `LotteryDrawJob` from `DeadlineEventJob` for lottery decisions
- Update automation YAML reference with new event types
- Tests for the job, duplicate prevention, and lottery integration
