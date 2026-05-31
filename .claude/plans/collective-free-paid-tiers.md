# Collective free/paid tiers

## Goal

Two-tier model for collectives:

- **Free**: most features (notes, decisions, commitments, cycles, media, API access).
- **Paid** ($3/mo, charged to `created_by`): everything in free, plus the three paid features — **automations**, **Trio AI assistant**, **file attachments** (non-media uploads).

A collective is on the paid tier iff it's a non-main, non-archived, non-`billing_exempt` collective with ≥1 enabled automation rule, OR `trio_enabled?`, OR `file_attachments_enabled?`. Cap is 1 per collective (any combination of paid features = $3/mo, not $9). Main collectives stay free.

Future paid-only features get bolted onto the same tier.

## Guiding principle: transparency

Users must never be surprised by a charge. Any UI action that would push a collective from free to paid must say so explicitly — dollar amount, when it kicks in, owner's billing status. The current tier and what's causing it must be visible everywhere it's relevant.

## Decisions

1. **Migration**: re-evaluate on next billing cycle. `BillingReconciliationJob` (daily) catches up; Stripe prorates on next invoice.
2. **Gate behavior**: when actor enables a paid feature on a free collective whose owner has no billing — if actor IS the owner, redirect to `billing_show_path`; otherwise flash "Collective owner must set up billing first."
3. **Disabled rules don't count.** Disabling all paid features pauses the $3/mo on the next cycle. Surfaced explicitly in UI.
4. **Trust reconciliation.** No pre-deploy revenue-impact report.
5. **Free collectives hidden from `/billing`.** Page only shows what costs money.
6. **`file_attachments` default flips to false** + backfill migration turns it off on collectives that have it via default. Currently defaults to true on new collectives, so this protects the "bills drop" migration story. Feature isn't in production use, so nothing real is wiped.
7. **Trio billing flows through collective tier**, not the agent. Trio agents have `parent_id: nil` and are already invisible to `User#active_billable_agent_count`. No double-billing, no code change on the agent side.
8. **Private workspaces bill the same as standard collectives.** Existing `.listable` scope filters out `collective_type: "private_workspace"`, so private workspaces are currently never billed. New scope `Collective.billable_types` (= standard + private_workspace) replaces `.listable` in billing paths. `chat`-type collectives remain non-billable.

## Predicates

Three predicates on `Collective`, separated by concern:

- **`paid_tier?`** — state of the collective. True when non-main, non-archived, non-`billing_exempt`, and ≥1 paid feature is active. Type-agnostic — applies to standard and private_workspace collectives alike. (Whether a collective is *billable* is a separate question, gated by `Collective.billable_types` scope at the count site.)
- **`owner_billing_setup?`** — state of the owner with respect to this collective. True when the tenant doesn't have `stripe_billing` enabled, OR owner is sys/app admin, OR owner has an active Stripe customer. This is what the gate checks.
- **`requires_stripe_billing?`** — `paid_tier? && !owner_billing_setup?`. Same name as [User#requires_stripe_billing?](app/models/user.rb#L614) for vocabulary consistency. Used for app-level redirects and inventory.

`free_tier?` = `!paid_tier?`.

`would_be_paid_tier?(has_enabled_automation_after:, trio_after:, file_attachments_after:)` — same shape as `paid_tier?` but accepts overrides for each input. Each entry point passes only what it's changing; defaults read from DB. This is what the gate uses to detect transitions.

**Why split out `owner_billing_setup?`**: the gate runs before the action saves, so `paid_tier?` still reads its pre-change state. A predicate that bakes in `paid_tier?` (like `requires_stripe_billing?`) returns false at the gate even when the transition would require billing. Need the tier-agnostic owner check.

**Why not chain to `User#stripe_billing_setup?`**: that helper returns true when current `billable_quantity == 0` (the "everyone exempt" shortcut). At gate time, the new feature isn't saved yet — a brand-new user with no other billable resources would slip through even though enabling will put them at $3/mo. `owner_billing_setup?` skips that shortcut.

**Vocabulary**: code uses `paid_tier?` / `free_tier?`; UI copy uses "paid plan" / "free plan." Intentional split — `_collective_tier_badge.html.erb` partial centralizes UI copy.

## Implementation (red-green TDD)

### Step 0 — `file_attachments` default flip + backfill

- Edit [config/feature_flags.yml](config/feature_flags.yml): `file_attachments.default_collective: false`.
- Migration: set `settings.feature_flags.file_attachments = false` on every non-main collective without an explicit value. Idempotent — explicit values respected.
- Pre-deploy console check: confirm no collective has explicit `file_attachments: true` in production.

### Step 1 — `Collective` predicates

Tests cover:
- `paid_tier?`: main / archived / billing_exempt all return false; each of (≥1 enabled automation, trio_enabled, file_attachments_enabled) returns true; all three together is still true; all-disabled / all-off returns false; **private_workspace with paid feature also returns true**; chat type also returns true (predicate is type-agnostic — type filtering happens in the billing scope, not the predicate).
- `owner_billing_setup?`: tenant flag off → true; sys/app admin → true; active stripe_customer → true; no customer + non-admin → false; inactive customer → false.
- `requires_stripe_billing?`: composition behaves correctly.
- `would_be_paid_tier?`: defaults from DB; each override works in isolation.

```ruby
sig { returns(T::Boolean) }
def paid_tier?
  return false if is_main_collective? || archived? || billing_exempt?
  automation_rules.enabled.exists? || trio_enabled? || file_attachments_enabled?
end

sig { returns(T::Boolean) }
def owner_billing_setup?
  return true unless T.must(tenant).feature_enabled?("stripe_billing")
  owner = T.must(created_by)
  return true if owner.sys_admin? || owner.app_admin?
  owner.stripe_customer&.active? || false
end

sig { returns(T::Boolean) }
def requires_stripe_billing?
  paid_tier? && !owner_billing_setup?
end

sig { returns(T::Boolean) }
def would_be_paid_tier?(has_enabled_automation_after: nil, trio_after: nil, file_attachments_after: nil)
  return false if is_main_collective? || archived? || billing_exempt?
  automation = has_enabled_automation_after.nil? ? automation_rules.enabled.exists? : has_enabled_automation_after
  trio = trio_after.nil? ? trio_enabled? : trio_after
  files = file_attachments_after.nil? ? file_attachments_enabled? : file_attachments_after
  automation || trio || files
end
```

### Step 2 — `User#active_billable_collective_count` + billing-types scope

Add `Collective.billable_types` scope: `where(collective_type: %w[standard private_workspace])`. Use it in both `active_billable_collective_count` and the `/billing` inventory query. Replaces `.listable` for billing-purpose queries (`.listable` keeps its current meaning for feed/index purposes — it's about UI listing, not billing).

Tests: existing assumption "all non-main collectives bill" is replaced — only `paid_tier?` collectives count. Enable automation → +1. Second automation same collective → still +1. Enable on second collective → +2. `billing_exempt` collective with paid features → 0. **Private workspace with trio enabled → +1**. Chat-type collective with paid feature → 0 (excluded by scope).

```ruby
# in Collective
scope :billable_types, -> { where(collective_type: %w[standard private_workspace]) }

# in User
def active_billable_collective_count(tenant_ids = billing_tenant_ids)
  return 0 if tenant_ids.empty?
  main_collective_ids = Tenant.where(id: tenant_ids).pluck(:main_collective_id).compact
  candidates = Collective.for_user_across_tenants(self).billable_types.where(
    tenant_id: tenant_ids, archived_at: nil, billing_exempt: false,
  )
  candidates = candidates.where.not(id: main_collective_ids) if main_collective_ids.any?
  candidates.count(&:paid_tier?)
end
```

### Step 3 — Gate paid-feature transitions

Shared concern in `app/controllers/concerns/paid_transition_gate.rb`. Two helpers — one returns a boolean so callers handle their own render strategy:

```ruby
# Returns true if the action should be blocked. Caller halts and renders.
def paid_transition_blocked?(collective, **overrides)
  return false unless collective.would_be_paid_tier?(**overrides)
  return false if collective.paid_tier?           # already paid
  return false if collective.owner_billing_setup? # owner covered
  true
end

# Owner-redirect convenience for the common case.
# Returns true if redirect was issued (caller halts).
def redirect_owner_to_billing(collective)
  return false unless current_user == collective.created_by
  redirect_to billing_show_path,
    alert: "This action moves the collective to the paid plan ($3/mo). Set up billing to continue."
  true
end
```

Each entry point handles its own block-action body. The non-owner flash message is consistent ("Collective owner must set up billing before you can enable this feature.") but the render target varies.

Entry points (verified line numbers; no Api::V1 automation endpoint; `trio_activator.rb:61` only creates agent-scoped rules):

| Entry point | Overrides | Failure response |
|---|---|---|
| `collective_automations_controller#execute_create` ([:108](app/controllers/collective_automations_controller.rb#L108)) | `has_enabled_automation_after: new_rule.enabled? \|\| any_existing_enabled` | `render_action_error` with billing message |
| `#execute_update` ([:168](app/controllers/collective_automations_controller.rb#L168)) | `has_enabled_automation_after: rule_after_yaml.enabled? \|\| others_enabled` | `render_action_error` |
| `#execute_toggle` ([:237](app/controllers/collective_automations_controller.rb#L237)) | `has_enabled_automation_after: !current_rule.enabled? \|\| others_enabled` | `render_action_error` |
| `collectives_controller#update_settings` ([:227](app/controllers/collectives_controller.rb#L227)) | `trio_after: new_trio, file_attachments_after: new_files` | redirect back with flash error |
| `users_controller#update_workspace_trio` ([:255](app/controllers/users_controller.rb#L255)) | `trio_after: new_trio` | redirect to settings with flash |
| `ApiHelper#update_collective_settings` ([api_helper.rb:856](app/services/api_helper.rb#L856)) | `file_attachments_after: new_value` | raise/return API error response |

`others_enabled` = `c.automation_rules.enabled.where.not(id: current_rule.id).exists?`.

Sample call site (`execute_create`):
```ruby
if paid_transition_blocked?(@current_collective, has_enabled_automation_after: rule.enabled? || existing_any_enabled)
  return if redirect_owner_to_billing(@current_collective)
  return render_action_error(action_name: "create_automation_rule", resource: nil,
    error: "Collective owner must set up billing before you can enable this feature.")
end
```

Tests cover, for each entry point: free→paid blocked when owner has no billing; allowed when owner has billing; non-owner admin sees flash/error; un-billing actions always allowed; transition on already-paid collective is a no-op gate-wise.

The `describe_*` action endpoints add a `billing_impact` field when the action would transition the tier — transparency only, no enforcement.

### Step 4 — `/billing` inventory

In [billing_controller.rb:335](app/controllers/billing_controller.rb#L335) `load_billing_inventory`: switch the collective queries from `.listable` to `.billable_types`, then filter `@active_collectives` to `paid_tier?` only. Each row shows cost + active paid features as the reason. Free collectives hidden. Private workspaces now appear in inventory when paid (consistent with the new billing model).

### Step 5 — Transparent UI

Per the transparency principle, every place a user might trigger a charge or wonder why they're being charged:

- **Collective settings**: tier indicator (`_collective_tier_badge.html.erb` partial) + inline transition warnings next to the trio and file_attachments toggles when collective is free.
- **Automations index**: status banner — free version names the cost ($3/mo) and the action that triggers it; paid version lists active paid features and notes that disabling them pauses the charge next cycle. Pre-flight warning if owner lacks billing.
- **New / edit automation form**: inline confirmation copy near the enabled checkbox if action would transition.
- **Private workspace settings**: same treatment for the user-controlled trio toggle.
- **`/billing`**: per-collective row shows cost + active paid features.
- **Gate flashes**: specific to action ("Enabling Trio moves..."), not generic.

The badge partial renders the tier label + reason; conditional warnings (owner-lacks-billing, would-be-transition) live inline because they depend on viewer + action.

### Step 6 — Docs

- CHANGELOG entry at release time.
- Update `memory/project_billing_status.md` post-merge.
- If [PHILOSOPHY.md](PHILOSOPHY.md) discusses pricing, sync it.

## File touch list

**App code**:
- `config/feature_flags.yml` — flip default
- `db/migrate/YYYYMMDD_backfill_file_attachments_off.rb` — backfill
- `app/models/collective.rb` — predicates + `billable_types` scope
- `app/models/user.rb` — `active_billable_collective_count` filter
- `app/controllers/concerns/paid_transition_gate.rb` — shared helper
- `app/controllers/collective_automations_controller.rb` — gate 3 actions
- `app/controllers/collectives_controller.rb` — gate flag flips
- `app/controllers/users_controller.rb` — gate workspace trio
- `app/services/api_helper.rb` — gate file_uploads param
- `app/controllers/billing_controller.rb` — filter inventory
- `app/views/billing/show.{html,md}.erb`
- `app/views/collectives/settings.{html,md}.erb`
- `app/views/collective_automations/{index,new,edit}.html.erb`
- `app/views/users/settings.{html,md}.erb` (private workspace trio)
- `app/views/shared/_collective_tier_badge.html.erb` (new)

**Tests** (red-green for new behavior + fixture sweep for existing):
- `test/models/collective_test.rb` — new predicates
- `test/models/user_test.rb` — updated `billable_quantity` cases
- `test/controllers/collective_automations_controller_test.rb` — gate transitions
- `test/controllers/collectives_controller_test.rb` — gate trio/file_attachments
- `test/controllers/users_controller_test.rb` — gate workspace trio
- `test/services/api_helper_test.rb` (or matching controller test) — gate file_uploads
- `test/controllers/billing_controller_test.rb` — inventory display
- `test/migrate/backfill_file_attachments_off_test.rb` — migration
- Fixture sweep — these 4 files assume non-main = billable: `test/integration/api_auth_test.rb`, `test/jobs/billing_reconciliation_job_test.rb`, `test/controllers/api_tokens_controller_test.rb`, `test/services/stripe_service_test.rb`

**Other**: `CHANGELOG.md` at release time.

## Risks

- **Bills drop next cycle.** Most non-main collectives have none of the three paid features active. Pre-deploy sanity check via Rails console.
- **Backfill safety.** Migration only flips off collectives without explicit values. Verify by console before running.
- **N+1**: each `paid_tier?` does ≥1 SQL `EXISTS` + 2 feature-flag reads. Cheap; push to SQL if measured hot.
- **Race**: simultaneous enables from two tabs both pass the gate. No harm — reconciliation handles it.
- **Copy drift**: shared badge partial + `would_be_paid_tier?` keep tier statements centralized.
- **Settings partial save**: trio toggle + description edit in same form — if trio is gated, whole save is blocked. Simpler than partial save; acceptable trade.
