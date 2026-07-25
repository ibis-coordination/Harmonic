# Automation rule soft delete — fix webhook deletion 500 without destroying audit history

**Status: ready to implement. Design direction (soft delete) is decided; open questions below are implementation-level.**

## The bug (user-visible)

Deleting a notification webhook from the agent/user settings UI returns a 500 whenever the webhook was created through the harmonic-bridge connect flow. `NotificationWebhooksController#destroy` calls `@webhook_rule&.destroy!` (`app/controllers/notification_webhooks_controller.rb`), and Postgres refuses the delete: `harmonic_bridge_setups.automation_rule_id` holds a foreign key (`fk_rails_35e2d720f0`) to the rule, `AutomationRule` declares no inverse association for it, and the FK has no `ON DELETE` action → `ActiveRecord::InvalidForeignKey` → 500.

A second, latent instance: `ai_agent_task_runs.automation_rule_id` has the same FK shape with no `dependent:` handling, so any automation rule that ever dispatched an agent task also 500s on destroy (from the general automations UI, `agent_automations_controller.rb`).

Reproduced on production 2026-07-23 (bridge-connected agent webhook). Directly-created webhooks (URL pasted into the form) delete fine — they have no bridge-setup row and no task runs.

## Why NOT to fix it with `dependent: :nullify`

The obvious two-line fix (add `has_one :harmonic_bridge_setup, dependent: :nullify` + `has_many :ai_agent_task_runs, dependent: :nullify`) would make deletion *work*, but working deletion is the problem. `AutomationRule` has `has_many :automation_rule_runs, dependent: :destroy`, and `automation_rule_runs.automation_rule_id` is `NOT NULL` — runs structurally cannot outlive their rule. Destroying a rule therefore destroys every run: `status`, `actions_executed`, `trigger_data` (event/actor provenance), `chain_metadata` (trigger-chain provenance), errors, timestamps — plus each run's context `api_tokens` and `automation_rule_run_resources`. `webhook_deliveries` survive (runs nullify them) but become unreachable in the UI, which queries them through run ids.

The FK violations are functioning as accidental audit guards: they block deletion precisely in the cases with the richest history (bridge-connected webhooks, agent-task rules). Run history and task-run attribution are audit data; deleting a rule should not destroy them.

## The fix: soft delete (archive)

"Delete" on an automation rule becomes archive: the rule row stays, everything referencing it stays, and the rule stops dispatching, stops appearing in listings, and stops counting for uniqueness and billing.

### Migration

- Add `deleted_at` (`timestamp`, nullable, default nil) to `automation_rules`. Consider a partial index on `deleted_at IS NULL` only if a hot query needs it (dispatch paths already filter on other indexed columns — measure, don't assume).
- Rebuild the one-notification-webhook-per-user partial unique index (find it in `db/structure.sql`; it's on `(tenant_id, COALESCE(ai_agent_id, user_id))` with a `WHERE (actions->>'webhook_url') IS NOT NULL`-style predicate) to add `AND deleted_at IS NULL` to the predicate — otherwise a user can never create a replacement webhook after archiving one.

### Model (`app/models/automation_rule.rb`)

- `scope :not_deleted, -> { where(deleted_at: nil) }` (or `kept`/`active` — match repo naming taste, but be consistent).
- Thread the filter through every read path that means "live rules":
  - `enabled` scope — dispatch paths compose from it; safest is to have `enabled` also require `deleted_at: nil`, since a rule that is archived must never fire regardless of its `enabled` flag. Verify all `enabled` callers agree with that semantic before folding it in; otherwise apply `not_deleted` at each dispatch site (`AutomationDispatcher`, the scheduled-rules job, webhook-trigger lookup by `webhook_path`).
  - `notification_webhook_for` scope — must exclude archived rules (this is what `set_webhook_rule` and billing checks use).
  - `one_notification_webhook_per_user` validation — exclude archived rows from the SELECT (mirror the index predicate change).
  - Listings: agent/user/collective automations indexes, and anywhere in system-admin that enumerates rules. Decide whether archived rules show (greyed out) or hide; hiding is fine for now.
- Add a `soft_delete!` method (sets `deleted_at`, flips `enabled` false, sets `updated_by`). Do NOT use Rails `default_scope` — this repo's multi-tenancy already composes scopes in `ApplicationRecord`; a default scope on top invites subtle bugs.
- Decide the fate of hard `destroy`: recommended is a `before_destroy` guard raising unless a `@allow_hard_destroy` flag is set (leaving a path for future data-retention tooling), so nobody reintroduces the cascade by habit. If that feels heavy, at minimum grep for other `destroy` callers on rules and convert them.

### Controllers

- `NotificationWebhooksController#destroy` → `@webhook_rule.soft_delete!`. Keep the redirect + "Webhook deleted." copy — "deleted" is the right user-facing word even though the row is archived.
- The general automations destroy path (`agent_automations_controller.rb`, and any user/collective automations controllers) → same treatment, uniform semantics.

### Billing interaction (do not skip)

Humans with a notification webhook are +1 billable (`has_notification_webhook?` — locate it on `User`; it queries the webhook rule). An archived webhook must NOT count as billable, or users will be charged for a webhook they deleted:

- Ensure whatever query backs `has_notification_webhook?` / `billable_quantity` excludes archived rules (it should fall out of the `notification_webhook_for` fix, but pin it with a test).
- Check whether the existing destroy path calls `StripeService.sync_subscription_quantity!` to decrement — reading the controller, deletion appears NOT to sync the subscription down (creation does, via `sync_subscription_for_new_billable!`). If that's a real gap it predates this change; fix it as part of this work (soft delete → sync quantity down for humans with active Stripe customer) and test it.

## Tests first (red-green)

Write these, watch them fail, then implement:

1. **Regression, the actual bug**: rule + associated `HarmonicBridgeSetup` row → `DELETE` the webhook via the controller → response succeeds, rule archived (`deleted_at` set), bridge-setup row intact and still pointing at the rule.
2. Rule with an `AiAgentTaskRun` → destroy via general automations path → succeeds, task run intact with attribution.
3. Rule with runs → archive → runs and their `webhook_deliveries` still exist and still reference the rule/run.
4. After archiving a user's webhook, creating a new one succeeds (uniqueness validation + unique index both allow it).
5. Archived rule never dispatches: event matching an archived event-rule creates no run; scheduled job skips archived; inbound webhook-trigger path 404s (or equivalent) for archived.
6. Archived webhook doesn't count toward `has_notification_webhook?` / billable quantity.
7. If implementing the hard-destroy guard: `destroy!` on a rule raises.

Existing test suites to keep green: `test/controllers/notification_webhooks_controller_test.rb`, automation dispatcher tests, any billing/`billable_quantity` tests. Run targeted files only; CI runs the full suite.

## Conventions

- Sorbet `typed: true`, regenerate RBIs with tapioca if columns change; rubocop clean; tenant-safety script clean (no `.unscoped`).
- Branch off `main`; do not commit to `main` directly. CHANGELOG is updated post-merge, not in the feature branch.
- Do not reference this plan document, or phase/option numbering from it, in code or commit messages.

## Explicitly out of scope

- `webhook_deliveries.secret` — delivery rows retain a copy of the signing secret; a rotation/scrub story for historical rows is a separate discussion. Noted 2026-07-23, don't solve here.
- Orphaned-delivery reachability (deliveries whose run was destroyed before this change) — console-only access is acceptable for now.
- Any retention/purge policy for archived rules — future data-retention tooling.
- UI for viewing/restoring archived rules — nothing user-facing beyond "delete works and history survives."

## Key files

- `app/controllers/notification_webhooks_controller.rb` — destroy action, `set_webhook_rule`, billing gates
- `app/controllers/agent_automations_controller.rb` — general automations destroy path
- `app/models/automation_rule.rb` — associations, scopes, uniqueness validation
- `app/models/automation_rule_run.rb` — run children (`api_tokens`, `webhook_deliveries`, `run_resources`)
- `app/models/harmonic_bridge_setup.rb` — `belongs_to :automation_rule, optional: true`
- `app/services/automation_dispatcher.rb` — event dispatch path (rule matching)
- `db/structure.sql` — FK names, partial unique index to rebuild, `NOT NULL` on `automation_rule_runs.automation_rule_id`
