# Gate Automations Behind a Flag; Add External Webhooks

## Goal

**1. New `automations` feature flag** that gates the existing full-featured automations UI (YAML authoring, all trigger types, all action types, conditions, etc.). When off, the UI is hidden but any existing `AutomationRule` records continue to fire — the flag gates *authoring*, not *execution*.

**2. New "Webhooks" UI** at `/ai-agents/<handle>/webhooks`, available for **external** AI agents whenever they exist. Form-based, no YAML, scoped to one use case: ping a parent's external service when their external agent is @-mentioned or receives a comment on their content.

Both UIs author the same `AutomationRule` model. The model gains a parallel predicate to distinguish: rules owned by an internal agent dispatch to the Task Runner (today's behavior); rules owned by an external agent deliver a webhook (new behavior). Same identity field (`ai_agent_id`), same mention filter, same parent-only authorization (`authorize_parent_user`), same `WebhookDelivery` retry/signing infrastructure.

## Why

External-agent rollout on the `app` tenant needs a way for human parents to set up "ping my server when my agent is mentioned" without YAML. The existing automations UI assumes internal agents and asks users to author YAML — wrong for this audience. The simple webhook surface gives them the one thing they need.

The `automations` flag also lets operators keep the full system hidden on tenants that don't need it (most external-only rollouts).

## Current state (brief)

- [`AutomationRule`](app/models/automation_rule.rb) is one model with three owner shapes (agent / collective / user) and four trigger types (event / schedule / webhook / manual).
- [`AutomationExecutor`](app/services/automation_executor.rb#L23) branches per-owner: `agent_rule?` → implicit task → `AiAgentTaskRun` → Task Runner; everything else → iterates `actions` array (handles `internal_action` / `webhook` / `trigger_agent`).
- [`WebhookDeliveryService`](app/services/webhook_delivery_service.rb) handles signed async delivery with HMAC-SHA256 + exponential-backoff retry, fully production-grade. Reuse as-is.
- [`AutomationMentionFilter`](app/services/automation_mention_filter.rb) reads `@rule.ai_agent_id` to filter agent rules — works for both internal and external agent rules **as-is, no changes**. The simple webhooks UI's three trigger options map directly onto the existing `mention_filter` values (`self`, `self_or_reply`).
- Existing UIs ([`agent_automations_controller`](app/controllers/agent_automations_controller.rb) + [`collective_automations_controller`](app/controllers/collective_automations_controller.rb)) are YAML textareas. Agent automations have no flag gate today.

## Design

### A. New `automations` feature flag

Add to [config/feature_flags.yml](config/feature_flags.yml):

```yaml
automations:
  name: "Automations"
  description: "Enables the full Automations UI with YAML authoring, all trigger and action types. Existing rules continue to fire when the flag is off — only the authoring UI is gated. Agent webhooks for external AI agents are available separately without this flag."
  app_enabled: true
  default_tenant: false
  default_collective: false
  collective_level: false   # tenant-level only
```

Gate the authoring surfaces (both checks read tenant-level):
- [`AgentAutomationsController`](app/controllers/agent_automations_controller.rb) — entire controller behind `tenant.automations_enabled?`.
- [`CollectiveAutomationsController`](app/controllers/collective_automations_controller.rb) — behind `tenant.automations_enabled?` too. (The collective's existing `paid_tier?` gate stays as a separate billing check.)
- Nav links to those controllers on `/ai-agents/<handle>` show page, `/ai-agents` index, and collective settings.

Tenant-level gating keeps the migration trivial (one UPDATE) and avoids the cascade pitfall where a collective without an explicit value would inherit the YAML default instead of the tenant's setting. Per-collective gating, if needed later, can layer on top.

The dispatcher/executor stay flag-agnostic so pre-existing rules keep firing.

**Migration**: a data migration sets `automations = true` for any tenant that already has `AutomationRule` records, so existing users don't lose their UI. New tenants default to off.

### B. `AutomationRule` predicates

Add to [`AutomationRule`](app/models/automation_rule.rb):

```ruby
def internal_agent_rule?
  ai_agent_id.present? && ai_agent&.internal_ai_agent?
end

def external_agent_rule?
  ai_agent_id.present? && ai_agent&.external_ai_agent?
end
```

No new columns. The discrimination is by the owning agent's current mode.

**Agent mode is immutable.** Add a model-level validation on `User`:

```ruby
validate :agent_mode_is_immutable, if: :ai_agent?

def agent_mode_is_immutable
  return unless persisted?
  return unless agent_configuration_changed?
  old_mode = (agent_configuration_was || {})["mode"]
  new_mode = (agent_configuration || {})["mode"]
  # Allow initial assignment (old was nil → new value), but block any subsequent change.
  return if old_mode.nil?
  return if old_mode == new_mode
  errors.add(:agent_configuration, "mode cannot be changed after agent creation")
end
```

Because `agent_configuration` is a JSONB column, Rails' built-in dirty tracking does flag changes to the column (it can't deep-diff but knows the hash changed). The validation compares the persisted value to the in-memory value before saving. The `old_mode.nil?` short-circuit allows the create-time path where the field starts unset and gets its initial value.

If a future product need requires mode changes (e.g., migrating internal → external), it'll come with its own data-migration plan to archive/convert existing rules. For now: mode is set at agent-creation time and never changes.

### C. Executor branching

Update [`AutomationExecutor#execute`](app/services/automation_executor.rb#L20):

```ruby
def execute
  @run.mark_running!
  if @rule.internal_agent_rule?
    execute_internal_agent_rule    # renamed from execute_agent_rule
  elsif @rule.external_agent_rule?
    execute_external_agent_rule    # NEW
  else
    execute_general_rule           # existing
  end
  @rule.increment_execution_count!
rescue StandardError => e
  @run.mark_failed!(e.message)
  raise
end
```

**`execute_internal_agent_rule`** is the existing `execute_agent_rule`, unchanged. It already gates on `internal_ai_agents_enabled?` + `internal_ai_agent?`, dispatches a `AiAgentTaskRun`, etc.

**`execute_external_agent_rule`** (new, in the same file):

```ruby
def execute_external_agent_rule
  ai_agent = @rule.ai_agent
  return @run.mark_failed!("AI agent not found") unless ai_agent
  return @run.mark_failed!("Agent is suspended.") if ai_agent.suspended?

  # Archived check — same as the internal path. An archived external agent
  # shouldn't fire webhooks any more than an archived internal agent should
  # dispatch tasks.
  agent_tu = ai_agent.tenant_users.find_by(tenant_id: @rule.tenant_id)
  return @run.mark_failed!("Agent is deactivated.") if agent_tu&.archived?

  # No billing gate: external webhooks aren't billed (no Task Runner
  # involvement, no LLM credit usage). The stripe_billing branch from
  # the internal path does not apply.

  webhook_url = @rule.actions["webhook_url"]
  payload_template = @rule.actions["payload_template"]
  signing_secret = @rule.actions["signing_secret"]
  return @run.mark_failed!("Webhook URL missing.") if webhook_url.blank?

  context = AutomationTemplateRenderer.context_from_event(@event)
  body = AutomationTemplateRenderer.render_body(payload_template, context)

  # Use the same constructor + queueing the existing webhook-action path
  # uses in execute_general_rule (AutomationExecutor#execute_webhook_action).
  # Implementation step: factor that path into a shared helper rather than
  # duplicating; confirm the WebhookDelivery API signature when implementing.
  delivery = create_webhook_delivery(url: webhook_url, secret: signing_secret, body: body)
  WebhookDeliveryJob.perform_later(delivery.id)
  @run.record_actions!(executed_actions: [{ type: "webhook", delivery_id: delivery.id }])
  # Don't mark completed — WebhookDelivery callback notifies parent run on completion.
end
```

Reuses `AutomationTemplateRenderer`, `WebhookDelivery`, and `WebhookDeliveryJob` — no new infrastructure. The `create_webhook_delivery` helper is factored out of the existing [`AutomationExecutor#execute_webhook_action`](app/services/automation_executor.rb#L224) at implementation time so the internal-path-for-collective-rules and this external-agent path share construction logic.

### D. Storage shape for external agent rules

External-agent rules store a single hash in `automation_rules.actions` (matching the compactness of the internal `{task: "..."}` shape):

```jsonb
{
  "webhook_url": "https://parent.example.com/harmonic-webhook",
  "payload_template": { ...default payload structure with {{template.vars}}... },
  "signing_secret": "whsec_<32-byte-hex>"
}
```

**Signing secret is stored unhashed** — different from API tokens, which are hashed at rest. The reason is symmetric: every outbound delivery needs to sign the request body with HMAC, so the plaintext has to be available at sign time. The encrypted-at-rest concern is handled by the existing DB-level column encryption (the same protection that covers the existing collective-rule webhook secrets in `actions`). If the DB is compromised, every webhook secret across the system is exposed regardless; we're not introducing new risk.

The default `payload_template` (set by `AgentWebhooksController#create`, not user-edited) mirrors the existing webhook payload context. The agent's id and handle are interpolated **at create time** (not via the renderer), so the template only references variables the existing `context_from_event` actually provides:

```jsonb
{
  "event": "{{event.type}}",
  "agent": { "id": "<agent.id literal>", "handle": "<agent.handle literal>" },
  "actor": { "id": "{{event.actor.id}}", "handle": "{{event.actor.handle}}" },
  "subject": { "type": "{{subject.type}}", "path": "{{subject.path}}", "text": "{{subject.text}}" },
  "collective": { "handle": "{{collective.handle}}" }
}
```

The literal values are embedded into the stored template at controller create-time. Consequence: if an agent's handle changes after a webhook is created, the webhook keeps sending the old handle until the rule is re-saved. Acceptable for v1; we can add `{{rule.*}}` to the renderer context later if it becomes annoying.

Users see this as a "what your server will receive" preview on the form; they don't edit it in v1.

### E. Validation

Add conditional validations on `AutomationRule`:

```ruby
validate :require_task_for_internal_agent_rule
validate :require_webhook_url_for_external_agent_rule

def require_task_for_internal_agent_rule
  return unless ai_agent&.internal_ai_agent?
  errors.add(:actions, "must include a task") if actions.blank? || actions["task"].blank?
end

def require_webhook_url_for_external_agent_rule
  return unless ai_agent&.external_ai_agent?
  errors.add(:actions, "must include a webhook_url") if actions.blank? || actions["webhook_url"].blank?
end
```

### F. `AgentWebhooksController` (new)

Routes (nested under ai-agents, parent-only writes):
```
GET    /ai-agents/:handle/webhooks
GET    /ai-agents/:handle/webhooks/new
POST   /ai-agents/:handle/webhooks
GET    /ai-agents/:handle/webhooks/:id/edit
PATCH  /ai-agents/:handle/webhooks/:id
DELETE /ai-agents/:handle/webhooks/:id
POST   /ai-agents/:handle/webhooks/:id/test
POST   /ai-agents/:handle/webhooks/:id/rotate_secret
POST   /ai-agents/:handle/webhooks/:id/toggle    # flips enabled
```

before_actions:
- `require_login`, `set_ai_agent`, `authorize_parent_user` — same pattern as `AgentAutomationsController`.
- `require_external_agent` — 404 unless `@ai_agent.external_ai_agent?`. (Internal agents use the full automations UI when its flag is on.)

Form fields (`new`/`edit`):
- **Trigger** — radio with three labeled options (resolves to `event_type` + `mention_filter`):
  - "When @-mentioned in a note" → `note.created`, `mention_filter: self`
  - "When @-mentioned in a comment" → `comment.created`, `mention_filter: self`
  - "When someone comments on my content" → `comment.created`, `mention_filter: self_or_reply`

  Each rule has **exactly one trigger**. To listen on multiple triggers, the user creates multiple rules (each gets its own URL/secret/history). This is intentional in v1 — keeps the model simple and matches the existing one-trigger-per-rule shape.

  **Verification needed before implementation:** `mention_filter: "self_or_reply"` was documented as "agent @mentioned OR event subject is a reply to something agent authored." For `comment.created`, this needs to actually cover "comment on a note the agent wrote," not just "comment replying to a comment by the agent." Read [`automation_mention_filter.rb`](app/services/automation_mention_filter.rb) to confirm. If `self_or_reply` only matches comment-to-comment replies, we either (a) introduce a new filter value `commentable_authored_by_self` or (b) drop this third trigger option from v1 and add it later when the filter is extended.
- **Webhook URL** — `https://` only, validated against SSRF list at save time.
- **Name** — optional, defaults to hostname of URL.
- **Signing secret** — auto-generated on create, displayed inline once with a "Save this — you won't see it again" notice (mirrors the API token + create-agent flows).

Actions:
- **Test** — sends a fixed `{event: "harmonic.webhook.test", ...}` payload to the URL and shows the response inline (status code + body). Both response and request body visible so the user can verify their server received what we sent. **Sync HTTP from the controller**; the request blocks up to the underlying HTTP timeout (~30s) — render a spinner / busy state during the call. A future async version (queue test, Turbo-stream the result back) is v2.
- **Rotate secret** — generates a new secret and reveals it once. URL/trigger unchanged.
- **Enable/disable toggle** — flips the rule's existing `enabled` boolean column. A disabled webhook is preserved (URL, secret, trigger config) but the dispatcher skips it. Useful when the parent's server is in maintenance.
- **Delete** — destroys the rule (and any in-flight WebhookDeliveries — match `dependent: :destroy` on the relation).

**Delivery history (v1, minimal)** — on `edit` (or a dedicated `show`), display a small table of the last N (~10) `WebhookDelivery` records for this rule: timestamp, status, response code, attempt count, link to the AutomationRuleRun for full detail. No filtering, no pagination, no manual retry button — just enough to answer "did my server receive the last few pings?". Larger UI deferred to v2.

UI placement: a new "Webhooks" section on `/ai-agents/<handle>/settings` between the API Tokens section and the Billing notice (when `@ai_agent.external_ai_agent?` true). Section header lists existing webhooks with name, status (enabled/disabled), and last delivery time; "Create webhook" button leads to the form.

### G. UI surfaces don't overlap on the same agent

The two UIs are for **different kinds of agents**, not two views of the same agent:

- **Webhooks UI** (`/ai-agents/:handle/webhooks`) — gated on `require_external_agent`. Shows up only on external-agent settings pages. Always available when the agent is external (no flag check on this surface).
- **Full Automations UI** (`agent_automations_controller`) — gated on `tenant.automations_enabled?`. On an external agent, the link is hidden from the show page even when the flag is on (because the executor's external-agent path doesn't speak the `task` shape that this UI authors). The full UI in practice serves internal agents and collectives.

**To prevent dead-letter rules**: `AgentAutomationsController#new` should redirect external agents to the Webhooks UI (`/ai-agents/:handle/webhooks`) with a flash explaining "Use Webhooks instead — external agents don't have task runs." The full UI's `create` action should reject `ai_agent_id` referring to an external agent with the same message. This keeps the data model honest: rules authored via the YAML path always have a `task`, rules authored via the form path always have a `webhook_url`. The validations in section E enforce this at the model layer.

## Tests

- `feature_flag_service_test`: `automations` flag exists, predicate works.
- `agent_automations_controller_test`: 403 when `automations` flag off; existing tests stay green when on.
- `collective_automations_controller_test`: same.
- `automation_executor_test`:
  - Internal-agent rule still dispatches to Task Runner (existing tests stay green).
  - External-agent rule fires `WebhookDeliveryJob`, doesn't create `AiAgentTaskRun`, doesn't require `internal_ai_agents_enabled?`.
- `user_test` (or `agent_configuration_test`): mode is immutable after creation — attempting to change `agent_configuration["mode"]` raises a validation error.
- `agent_webhooks_controller_test` (new):
  - `index` / `new` render for external agents; 404 for internal.
  - `create` with valid URL produces an `AutomationRule` with the expected `actions` hash.
  - `create` with non-https URL rejected with `flash[:alert]`.
  - `test` action delivers to the URL synchronously and shows response.
  - `rotate_secret` regenerates and reveals the secret once.
  - `toggle` flips the rule's `enabled` flag.
  - `edit` page shows the last ~10 `WebhookDelivery` records for the rule.
  - `destroy` removes the rule.
- `automation_mention_filter_test`: existing tests stay green (filter still uses `ai_agent_id`).
- View test: webhook section visible on settings page for external agents; absent for internal.

## Migration

Single data migration, backfills `automations = true` on tenants that already have `AutomationRule` records so existing users keep their authoring UI:

```ruby
execute <<-SQL
  UPDATE tenants
  SET settings = jsonb_set(
    settings,
    '{feature_flags,automations}',
    'true'::jsonb,
    true
  )
  WHERE EXISTS (
    SELECT 1 FROM automation_rules WHERE automation_rules.tenant_id = tenants.id
  );
SQL
```

No schema changes — no new columns on `AutomationRule`, no new tables. Tenant-level flag only (no collective-level backfill needed, see Section A).

## What we are NOT changing

- `WebhookDelivery` / `WebhookDeliveryJob` / `WebhookDeliveryService` — reused unchanged.
- `AutomationTemplateRenderer` syntax + context vars.
- `AutomationMentionFilter` — works for both rule kinds.
- `AutomationDispatcher` matching logic — unchanged.
- Internal-agent rule execution path — unchanged.
- Collective-rule execution path — unchanged.
- Existing rate limits (3/min per agent rule, 100/min per tenant) — apply to both internal and external agent rules.

## Open questions

None outstanding for v1.

Resolved during planning:
- Naming = "Webhooks".
- Enable/disable toggle on each rule = yes (existing `enabled` column).
- Delivery history = yes, minimal in v1 (last ~10 deliveries on the edit page).
- Mention mechanism = reuse `AutomationMentionFilter` and the existing `mention_filter` values as-is.

## Rollout

All of the below ships in a single PR; the migration runs as part of the deploy:

1. **YAML**: add `automations` flag to `config/feature_flags.yml` (default off).
2. **Predicates**: `AutomationRule#internal_agent_rule?` / `external_agent_rule?`; agent-mode immutability validation on `User`.
3. **Executor**: split `execute` into `execute_internal_agent_rule` (existing code, renamed) / `execute_external_agent_rule` (new) / `execute_general_rule` (existing). Factor out a shared `create_webhook_delivery` helper.
4. **Validation**: conditional `actions.task` / `actions.webhook_url` requirements.
5. **Existing UIs gated**: `AgentAutomationsController` and `CollectiveAutomationsController` behind `tenant.automations_enabled?`. Update nav links.
6. **External-agent redirect**: `AgentAutomationsController#new` redirects external agents to `/ai-agents/:handle/webhooks` with explanatory flash.
7. **New `AgentWebhooksController`** + views (index, new, edit with delivery history, test, rotate_secret, toggle, destroy).
8. **Webhooks section** added to `/ai-agents/<handle>/settings` for external agents.
9. **Data migration** (runs on deploy): backfill `automations = true` on tenants with existing AutomationRule records. (See migration SQL above.)
10. **CHANGELOG**: new `automations` flag (default off; auto-on for tenants with existing rules); new Webhooks UI for external agents; agent mode is now immutable.
