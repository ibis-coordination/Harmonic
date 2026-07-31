# Notification Webhooks as a Delivery Channel

**Status: draft, round 1, 2026-07-31. Direction agreed with Dan: webhooks are a notification delivery channel, not an automation. This plan supersedes stage F1b of [automations-mental-model-and-foundation.md](automations-mental-model-and-foundation.md) and answers F3's open question ("do forwarders migrate to their own table?") with yes.**

## The problem

Notification webhooks deliver a user's notifications to an external URL. Today that delivery runs through the automation system: `NotificationService` synthesizes a `notifications.delivered` event → the automation dispatcher matches it against a pseudo-rule owned by the recipient → the firing gate admits it → an `AutomationRuleRun` is created → the executor renders the payload template and POSTs.

Compare web push, which is a notification *channel*: a `NotificationRecipient` row with `channel: "web_push"` → delivery job → push. The webhook path rebuilds that pipeline out of borrowed automation parts.

The borrowed abstraction leaks everywhere. The carve-outs the current design requires:

- The event registry carries a whole **audience axis** (`:single_recipient`) that exists for exactly two event types, both synthesized for this transport.
- The dispatcher **skips membership checks, the tier gate, and the self-trigger guard** for these events, and matches by rule owner instead of by collective.
- The firing gate has a **separate rate limit** for forwarder rules.
- The rules table enforces **one-forwarder-per-recipient uniqueness** — a constraint about subscriptions, not rules (made explicit by `rule_type: notification_webhook`, previously shape-sniffed).
- Chat and trustee notifications **route their delivered events through private workspaces** solely because `Event` requires a `collective_id` these deliveries don't naturally have.
- The delivered event stores its recipient in `actor_id`, because **events have no recipient concept — and shouldn't**: events are things that happen; notifications are the thing with recipients. (The 2026-07 cross-delivery leak was this implicitness biting: routing read a recipient out of a field named "actor".)

One feature forcing exceptions in five subsystems is in the wrong subsystem.

## Target architecture

**A webhook is a notification channel, alongside `in_app`, `email`, and `web_push`.**

1. **Subscription model** — `NotificationWebhookSubscription` (controlled-vocabulary term is "notification webhook"): `tenant`, recipient user (human or agent), `url`, signing secret, `payload_template`, delivery filters, `enabled`, lifecycle state. One per (tenant, recipient), enforced by a unique index on the subscription table — where the invariant belongs. The bridge-setup "pending" state (today a rule with no URL, formerly marked by a magic name) becomes an honest subscription lifecycle state: `pending → registered`.

2. **Channel** — delivery fans out a `NotificationRecipient` row with `channel: "webhook"` when the recipient has a registered, enabled subscription (same preference machinery as other channels; reminders included). The delivery job hands webhook rows to a deliverer that renders the subscription's payload template and POSTs.

3. **Deliverer** — reuses the existing `WebhookDeliveryService` + `WebhookDelivery` machinery (signed POST, retry states); `WebhookDelivery.automation_rule_run` becomes optional with a subscription/recipient reference added. Per-recipient rate limiting (3/min today) moves here — it's a delivery throttle, not an automation limit.

4. **Wire protocol unchanged** — this is a hard constraint. External agents and harmonic-bridge keep receiving the same signed POST (`X-Harmonic-Timestamp` + `X-Harmonic-Signature` over `"{timestamp}.{body}"`) with the same payload context: `recipient`, `actor` (the originating party), `notification`, and `event.type` strings `"notifications.delivered"` / `"reminders.delivered"` — which survive as *payload vocabulary* even after the internal Event rows stop existing. The deliverer builds this context from the notification directly; no Event needed.

5. **Everything it deletes, once no consumers remain**: emission of `notifications.delivered` / `reminders.delivered`; the `:single_recipient` audience axis and its registry entries; the dispatcher's owner-matching branch and all three guard skips; the gate's forwarder rate-limit branch; the forwarder uniqueness index and validations on `automation_rules`; the private-workspace routing contortions in chat and trustee delivery. `rule_type` stays (it still distinguishes the rows until migration completes, and remains honest afterward with a single value — dropping it can be its own later decision).

## Migration path (sketch — stages TBD in round 2)

1. Subscription model + channel + deliverer land behind the existing surfaces: the webhook settings UI, test delivery, secret rotation, toggle, and the bridge-setup handshake re-point from rules to subscriptions.
2. Data migration: every live `rule_type: notification_webhook` rule becomes a subscription (URL, secret, template, event filters, enabled state); `rule_type` makes this a query, not a hunt. Soft-deleted forwarder rules stay as history.
3. Billing (`User#has_notification_webhook?` → +1 billable) keys on registered subscriptions.
4. Dual-emission window if needed, then delivered-event emission stops and the carve-out teardown lands as its own commit(s).

## Open questions for round 2

1. **Are there non-forwarder consumers of delivered events?** The dispatcher today matches *any* recipient-owned rule on these event types — a recipient's agent rule with a task would fire on their own notification deliveries. Audit prod/sandbox for such rules before scheduling the teardown. If "run my agent when I'm notified" is a capability worth keeping, it needs a deliberate home (subscription option? agent-side reaction to the webhook?) — not silent removal. (Bridge agents don't need it: their harness reacts to the webhook.)
2. **Delivery filters**: today's subscriptions say `event_types: [notifications.delivered, reminders.delivered]`. As a channel, the natural grammar is notification types (the existing per-type channel preferences). Decide whether filters collapse into the standard preference matrix or stay subscription-level.
3. **Reminder batching**: `reminders.delivered` batches per (user, timestamp) with a `reminders` array payload. Preserve batch shape in the deliverer, or simplify to per-notification with bridge-compat shim?
4. **Delivery observability**: run history pages currently show forwarder runs. Decide the replacement surface (recent deliveries already render on the webhook settings page from `WebhookDelivery` rows — likely sufficient).
5. **Retry semantics parity**: confirm the channel path inherits the same retry/backoff the executor path had, and what happens to `NotificationRecipient.status` on terminal failure.
6. **Sequencing against the foundation plan**: F4 (steps unification) is independent and can proceed in parallel; F6's docs rewrite should land *after* this so the help pages describe the channel model. Where this slots relative to F4 is a scheduling choice, not a dependency.

## Non-goals

- Any change to the external webhook payload, signing, or verification handshake.
- New channel types or per-collective webhooks.
- Touching rule-authored webhook *actions* (`actions: [{type: webhook, ...}]`) or inbound webhook triggers — those are real automations and stay.
