# Notification-Forwarding Webhooks (per-User)

## Goal

One webhook per user that forwards every notification they receive (@-mentions, comment replies, chat messages, reminders, future types) to an HTTPS URL of their choosing. User-type is incidental: humans manage their own webhook on `/u/<handle>/settings`; AI agents' webhooks are managed by their parent on `/ai-agents/<handle>/settings`.

Replaces the multi-rule UI shipped on `gate-automations-add-webhooks` (commit `ecc6c8a`), which exposed three radio-button triggers per rule. Collapses to: one URL, one toggle, forwards everything.

## Why this is small

[`notification_delivery_job.rb`](app/jobs/notification_delivery_job.rb) already fires `notifications.delivered` with a comment that reads "for user webhooks." `ReminderDeliveryJob` fires `reminders.delivered`. The dispatch substrate exists. This plan is mostly: dispatcher carve-outs to let those events reach agent rules, two patches to the event-firing path, and a polymorphic UI shrinkage.

## A. Predicate + shape validation

`AutomationRule#notification_webhook_rule?` requires a single owning recipient (never collective-only) so the executor has someone to dispatch to:

```ruby
def notification_webhook_rule?
  return false if ai_agent_id.nil? && user_id.nil?
  actions.is_a?(Hash) && actions["webhook_url"].present?
end
```

Paired validation rejects collective-only rules adopting the webhook-shape `actions` hash. Single-webhook-per-user enforced by validation + DB partial unique index on `(tenant_id, COALESCE(ai_agent_id, user_id))` filtered by `(actions->>'webhook_url') IS NOT NULL`. Rails 7.2 expression-index syntax may need a raw-SQL fallback.

Trigger config (internal, never user-facing): `{ "event_types" => ["notifications.delivered", "reminders.delivered"] }`.

**Dev-data hazard:** the multi-rule UI shipped in `ecc6c8a` allowed multiple webhook rules per agent. The unique index migration will fail in dev DBs that have duplicates. Migration should loud-fail with cleanup instructions; production data is empty (no-op).

## B. Dispatcher carve-outs

Four changes to [`AutomationDispatcher`](app/services/automation_dispatcher.rb):

**Multi-event matching.** `for_event_type` scope adds array-form via PostgreSQL's `?` jsonb operator, escaped as `??` to avoid AR placeholder collision:

```ruby
where(trigger_type: "event").where(
  "trigger_config->>'event_type' = :t OR trigger_config->'event_types' ?? :t",
  t: t,
)
```

Verify `??` escaping at impl time; fall back to `jsonb_path_exists` via `Arel.sql` if unreliable.

**Self-trigger carve-out.** [Line 74](app/services/automation_dispatcher.rb#L74) blocks `agent_rule? && actor_id == ai_agent_id`. For notification-delivered events the actor IS the recipient — exactly when we want to fire. Carve out:

```ruby
NOTIFICATION_DELIVERED_EVENTS = %w[notifications.delivered reminders.delivered].freeze

return false if rule.agent_rule? &&
  event.actor_id == rule.ai_agent_id &&
  !NOTIFICATION_DELIVERED_EVENTS.include?(event.event_type)
```

**Mention-filter bypass.** Existing guard (`if rule.mention_filter.present?`) already handles notification-webhook rules since they don't set `mention_filter`. Verify, no code change expected.

**Collective access.** `rule_has_collective_access?` requires recipient be a member of the event's collective. Redundant for notification events (recipient already had access) but not wrong. Leave in place.

## C. Fill the event-firing gaps

**Chat messages.** `NotificationService.notify_chat_message!` creates `NotificationRecipient` directly with `status: "delivered"` and never enqueues `NotificationDeliveryJob`, so `notifications.delivered` never fires. Add `EventService.record!` call in the `else` (new-notification) branch only — not the already-undismissed early-return. Caller (`ChatsController`) sets `Collective.set_thread_context(@chat_session.collective)` before invoking, so EventService finds collective context. Include `metadata["original_actor_id"] = sender.id` since the chat Notification has no `event` (see Section E renderer fallback).

**Channel-preference edge case.** [`notification_delivery_job.rb:64`](app/jobs/notification_delivery_job.rb#L64) gates event firing on `channel == "in_app"` to avoid double-fire when a user has both `in_app` and `email`. A user with only email enabled for some notification type gets no event → no webhook.

Fix: move event emission from `NotificationDeliveryJob` (per-channel) to `NotificationService.create_and_deliver!` (per-notification), once, regardless of channels. Metadata uses `"channels" => channels` array. Behavior change: event now fires at notification creation rather than after in_app delivery. Grep confirms no other consumers exist. Remove the firing from the delivery job.

**Reminders.** `ReminderDeliveryJob` already fires `reminders.delivered`. Multi-event matching in B handles it. No change.

## D. Executor

Drop `external_agent_rule?` (no other use). `notification_webhook_rule?` becomes the branching predicate. Renamed from `execute_external_agent_rule` to `execute_notification_webhook_rule`. Recipient liveness check generalized for humans + agents (both can leave a tenant):

```ruby
recipient = @rule.ai_agent || @rule.user
return @run.mark_failed!("Recipient not found") unless recipient
return @run.mark_failed!("Recipient is suspended.") if recipient.suspended?

recipient_tu = recipient.tenant_users.find_by(tenant_id: @rule.tenant_id)
if recipient_tu.nil? || recipient_tu.archived?
  return @run.mark_failed!("Recipient no longer active in this tenant.")
end
```

No billing gate. Reuses `create_webhook_delivery`.

## E. Payload template + renderer

For `notifications.delivered`, `event.actor` is the recipient. Original actor lives at `event.subject.event.actor` (the Notification's underlying event). Chat messages and reminders have no `notification.event`, so the renderer falls back to `event.metadata["original_actor_id"]`.

```ruby
def self.context_from_event(event)
  base = standard_context(event)
  return base unless NOTIFICATION_DELIVERED_EVENTS.include?(event.event_type)

  notification = event.subject
  return base unless notification.is_a?(Notification)

  original_actor = notification.event&.actor
  if original_actor.nil? && event.metadata["original_actor_id"].present?
    original_actor = User.find_by(id: event.metadata["original_actor_id"])
  end

  base.merge(
    "recipient" => actor_context(event.actor),
    "actor" => actor_context(original_actor),  # null for reminders
    "notification" => {
      "id" => notification.id, "type" => notification.notification_type,
      "title" => notification.title, "body" => notification.body,
      "url" => notification.url, "created_at" => notification.created_at.iso8601,
    },
  )
end
```

Default payload template (set at create-time, recipient id/handle/type interpolated as literals):

```json
{
  "event": "notifications.delivered",
  "recipient": { "id": "<literal>", "handle": "<literal>", "type": "<human|ai_agent>" },
  "notification": { "type": "{{notification.type}}", "title": "{{notification.title}}",
    "body": "{{notification.body}}", "url": "{{notification.url}}", "created_at": "{{notification.created_at}}" },
  "actor": { "id": "{{actor.id}}", "handle": "{{actor.handle}}" },
  "collective": { "handle": "{{collective.handle}}" }
}
```

`{{actor.*}}` resolves to the original actor, not the recipient.

## F. UI surface

`NotificationWebhooksController` mounted at both `/u/:handle/webhook` and `/ai-agents/:handle/webhook` (singular) with PATCH (set URL), POST `/toggle`, POST `/test`, POST `/rotate_secret`, DELETE. URL-prefix-aware target resolution prevents type confusion since `TenantUser.handle` is tenant-unique regardless of `user_type`:

```ruby
def set_target_user
  tu = @current_tenant.tenant_users.find_by(handle: params[:handle])
  return render status: :not_found, plain: "404 Not Found" if tu.nil?

  @target_user = tu.user
  expected = request.path.start_with?("/ai-agents/") ? :ai_agent : :human
  return render status: :not_found, plain: "404 Not Found" if expected == :ai_agent && !@target_user.ai_agent?
  return render status: :not_found, plain: "404 Not Found" if expected == :human && !@target_user.human?
end

def authorize_target_user
  return if @target_user == @current_user
  return if @target_user.ai_agent? && @target_user.parent_id == @current_user&.id

  redirect_to "/", alert: "You don't have permission to manage this webhook."
end
```

`require_external_agent` stays on the `/ai-agents/` path (internal agents use YAML automations).

Shared partial `app/views/shared/_notification_webhook_form.html.erb` takes locals `target_user`, `url_prefix`, `webhook_rule` (nil if unset). Renders URL field, enable toggle, test/rotate/delete buttons, last-10 delivery history. Embedded in both settings pages.

`AutomationRule` is shared storage, so listings that load all rules for an owner would mix in webhook rules and render `rule.event_type` as nil. Add a scope:

```ruby
scope :excluding_notification_webhooks, -> {
  where("(actions->>'webhook_url') IS NULL OR (ai_agent_id IS NULL AND user_id IS NULL)")
}
```

Apply at [`ai_agents_controller.rb:70`](app/controllers/ai_agents_controller.rb) and [`agent_automations_controller.rb:23`](app/controllers/agent_automations_controller.rb).

**Deletes from `ecc6c8a`:** `AgentWebhooksController`, plural routes, all `app/views/agent_webhooks/*` except `show_secret.html.erb` (moves to `app/views/notification_webhooks/`), the multi-rule list in `ai_agents/settings.html.erb`, and `external_agent_rule?` from `AutomationRule`. The executor branch survives renamed.

## G. Privacy: test-delivery-before-enable

Disable-by-default. The toggle accepts enable only when a successful test delivery has been recorded for the rule's _current_ URL. On a 2xx test response, write `actions["last_successful_test"] = { "url" => actions["webhook_url"], "at" => Time.current.iso8601 }`. The toggle's enable action checks `actions.dig("last_successful_test", "url") == actions["webhook_url"]`. Changing the URL invalidates; disabling and re-enabling without URL change does not require re-test.

Human surface enforces this gate. Agent surface treats it as recommended but not required (the parent already opted into running an external agent).

Plain-English notice on the human form:

> Enabling this webhook will POST every notification you receive — including comment text, decision titles, and the actor's handle — to the URL you provide. Only enable this for servers you control.

## H. Rate-limit scope

Existing per-rule limit is 3/min for agent rules, 10/min for everything else. Notification-webhook rules (agent or user-owned) share the 3/min cap; other user rules keep 10/min:

```ruby
max_per_minute = (rule.notification_webhook_rule? || rule.agent_rule?) ? 3 : 10
```

## Implementation-time verifications

- `??` jsonb escape works in current Rails; fall back to `jsonb_path_exists` if not.
- `add_index` with expression form works in Rails 7.2; fall back to raw `execute "CREATE UNIQUE INDEX ..."` if not.
- No other consumer of `notifications.delivered` exists today (grep). If one appears, the move-to-creation in C may need a guard.
- Dev DB has no duplicate webhook rules from `ecc6c8a` testing; clean up if migration fails.

## Rollout

Single PR, single deploy. New files `# typed: true`; regenerate RBIs via `tapioca`. Order:

1. Predicate + shape validation + single-webhook validation + partial unique index migration.
2. Dispatcher carve-outs (multi-event match, self-trigger).
3. Event-firing fixes (move from job to service, add to `notify_chat_message!`).
4. Renderer (`context_from_event` for notification events with actor fallback).
5. Executor (drop `external_agent_rule?`, branch on `notification_webhook_rule?`, generalize liveness).
6. Controller (`NotificationWebhooksController` polymorphic).
7. Views (shared partial, embed in both settings pages, move `show_secret`).
8. Test-before-enable gate (`actions["last_successful_test"]`, URL-binding policy).
9. Scope-out for automation listings (`excluding_notification_webhooks` scope applied).
10. Tear-down: delete old controller, views, plural routes, `external_agent_rule?`.
