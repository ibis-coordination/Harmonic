# Explicit collective tier state machine

## Goal

Replace the implicit "enabling a paid feature moves the collective to paid tier" model with an explicit `tier` state machine. Upgrade is a deliberate user action (button → confirm or billing setup), not a side effect of feature toggling. Paid features are unavailable on free collectives.

Builds on commits `eccdf29`, `9f6fd96`, `ffaea5f` (this branch). Much of that work gets simplified or replaced — refactor goes on top as a 4th commit.

## Decisions

1. **State machine**: `free` / `paid` / `lapsed`. In-progress Stripe Checkout is tracked in the user's session, not as a fourth state. Transitions enforced via `VALID_TIER_TRANSITIONS` map + `validate :tier_transition_allowed`.
2. **Existing collectives all start at `free`** — backfill regardless of current feature state.
3. **`downgrade!` actively disables paid features** (automations, trio, file_attachments + `TrioActivator.deactivate!`). User opted out; clean slate for any future re-upgrade.
4. **`mark_lapsed!` only flips the column.** Runtime gates (predicate short-circuits, automation runner check) handle the pause. Restore is instant and zero-loss — fits the "card declined, fix tomorrow" case.
5. **`tier` × `archived` are orthogonal.** Archive a paid collective → stops billing (existing `archived_at: nil` filter), tier preserved for unarchive.
6. **Subscription loss → `lapsed`, not archive** (behavior change vs current code). Softer recovery path.
7. **Auto-restore on payment-resolved**: `customer.subscription.created` / re-subscription webhook restores all the user's `lapsed` collectives to `paid`. Matches the user expectation that fixing the card just resumes the paid plan — no extra clicks.
8. **Stripe Checkout**: dedicated `/collectives/:handle/upgrade` endpoint. Session-creation extracted from `BillingController#setup` into shared `StripeCheckoutService`. Session metadata carries `collective_id`. The user-session stash (`session[:pending_collective_upgrade]`) lets the settings page show a "Resume checkout" affordance if the owner navigates back during checkout.
9. **Upgrade/downgrade are POST-with-turbo-confirm**, not separate confirmation pages. Dialog copy includes the consequences (e.g., "Downgrade? This will disable N automation(s) and turn off Trio / file attachments.").
10. **Non-owner admins** see the Upgrade button but get "Only the owner can upgrade" on click.
11. **Owner transfer** out of scope (separate future feature; `created_by` treated as immutable).

## State machine

```
[free] ──upgrade──▶ Stripe Checkout (session) ──webhook confirms──▶ [paid]
   ▲                          │                                      │
   │                          │ owner abandons (session expires)     │ subscription
   │                          ▼                                      │ lapse webhook
   │                       [free]                                    ▼
   │                                                            [lapsed]
   │                                                                 │
   │◀──── downgrade (active feature cleanup) ────────────────────────┤
   │                                                                 │
   └─────── owner re-ups billing (webhook auto-restores) ───────────▶[paid]
```

```ruby
VALID_TIER_TRANSITIONS = {
  TIER_FREE   => [TIER_PAID],            # via upgrade (direct if owner has billing, else via Checkout)
  TIER_PAID   => [TIER_FREE, TIER_LAPSED], # downgrade or lapse
  TIER_LAPSED => [TIER_PAID, TIER_FREE], # restore or downgrade
}.freeze
```

## Predicates

- `paid_tier?` → `tier == TIER_PAID` (short-circuits true for main collectives in compositions — see below).
- `free_tier?` → `!paid_tier?`.
- `requires_stripe_billing?` → `tier == TIER_LAPSED`.

Main collectives are treated semantically as paid (everything works) but their column stays `TIER_FREE`; predicates that gate feature access short-circuit on `is_main_collective?` first.

Runtime gates for paid features:
- `Collective#trio_enabled?` → returns false unless `paid_tier? || is_main_collective?`. Then existing cascade check.
- `Collective#file_attachments_enabled?` → same shape.
- Automation runner checks `collective.paid_tier?` before firing each rule.

Trio agent stays alive during lapse (preserves user record + config); routing checks tier and goes nowhere when paused.

## What's removed / simplified / kept

**Removed:** `would_be_paid_tier?`, `owner_billing_setup?`, `PaidTransitionGate` concern + helpers, all transition-hint copy in views, the `keeps`/`moves` conditional wording, `describe_create`'s tier_note, the existing archive-on-subscription-loss webhook handler.

**Simplified:** `paid_tier?` is a column read; `requires_stripe_billing?` is a state check; `active_billable_collective_count` collapses to a single SQL count filtered by `tier == paid`; `/billing` inventory query similarly.

**Kept:** `Collective::PAID_FEATURE_FLAGS`, `billable_types` scope, `requires_stripe_billing?` predicate name, tier badge partials, the file_attachments-default-flip migration, the workspace-billing-exempt-clear migration.

## Implementation steps

### A — Schema
1. Add `tier` column to `collectives`: string, NOT NULL, default `TIER_FREE`, indexed.
2. Backfill all rows to `TIER_FREE` (per decision #2 — no feature-state-based variation).
3. Update Sorbet RBI.

### B — Collective model
1. Add `TIER_*` constants, `TIERS` array, `VALID_TIER_TRANSITIONS`, validations.
2. Predicates (per "Predicates" section above).
3. Transition methods (all idempotent; owner-only ones raise on `actor != created_by`):
   - `upgrade!(actor:)` — `free → paid` if actor has `stripe_customer&.active?`. Otherwise raises `BillingRequired` so the controller knows to redirect to Stripe Checkout. Tier flips to `paid` only after checkout completes (via `confirm_upgrade!`).
   - `confirm_upgrade!` — `free → paid` from Stripe Checkout webhook.
   - `downgrade!(actor:)` — `paid|lapsed → free` + active cleanup (disable automations, clear trio + `TrioActivator.deactivate!`, clear file_attachments).
   - `mark_lapsed!` — `paid → lapsed` (webhook). No cleanup; just flips column.
   - `restore_from_lapsed!` — `lapsed → paid` (webhook on subscription re-create). No restoration step needed.

### C — Replace gate at feature-enable points
Delete [paid_transition_gate.rb](app/controllers/concerns/paid_transition_gate.rb). Six call sites (`collective_automations#execute_create|update|toggle`, `collectives#update_settings`, `users#update_workspace_trio`, `ApiHelper#update_collective_settings`) replace `paid_transition_blocked?` with:

```ruby
return render_action_error(error: "This action requires the paid plan. Upgrade on the collective settings page.") unless @current_collective.paid_tier?
```

`update_settings` gates per-toggle: refusing a paid-flag flip doesn't block name/description edits.

### D — Upgrade/downgrade controller actions
`CollectivesController` adds two POST endpoints (no GET confirmation pages — the buttons use `data-turbo-confirm`):

- `POST /collectives/:handle/upgrade` — owner-only. Calls `upgrade!`. If owner already has active stripe_customer → confirms inline, redirects to settings with success flash. If `BillingRequired` raised → creates Stripe Checkout session via `StripeCheckoutService`, stashes session_id in `session[:pending_collective_upgrade]`, redirects to Stripe.
- `POST /collectives/:handle/downgrade` — owner-only. Calls `downgrade!`.

Settings page wiring:
- Upgrade button: `<%= button_to "Upgrade to Paid ($3/month)", upgrade_path, method: :post, data: { turbo_confirm: "Upgrade this collective to the paid plan ($3/month)?" } %>`
- Downgrade button: dialog mentions count of automations + which flags will clear.
- If `session[:pending_collective_upgrade]` matches this collective → show "Resume checkout" affordance instead of Upgrade button.

Non-owner admins see the Upgrade button but the POST returns "Only the owner can upgrade" flash.

### E — Stripe Checkout + webhooks
Extract `StripeCheckoutService.create_session!(user:, success_url:, cancel_url:, metadata:)` from `BillingController#setup`. Callers: existing per-user `BillingController#setup` + new `CollectivesController#upgrade` (passes `metadata: { collective_id: c.id }`).

`StripeWebhooksController` handles:
- `checkout.session.completed`: if `metadata[:collective_id]` present → `Collective.find(id).confirm_upgrade!`, clear `session[:pending_collective_upgrade]`. Else existing user-level setup.
- `customer.subscription.deleted` / `invoice.payment_failed`: loop user's paid collectives → `mark_lapsed!`. Replaces archive-on-loss.
- `customer.subscription.created` / payment-resumed event: loop user's lapsed collectives → `restore_from_lapsed!` + sync Stripe quantity.

### F — Settings page (rewrite)
The "Paid Plan Features" section becomes tier-driven:
- `free` (no pending checkout): explainer + "Upgrade to Paid ($3/month)" button. Toggles hidden.
- `free` (pending checkout in session): "Pending billing setup" + "Resume checkout" link.
- `paid`: toggles + Automations entry + "Downgrade to Free" button.
- `lapsed`: "Billing lapsed — features paused" + "Resume billing" button. Toggles read-only.

Drops all transition-hint copy.

### G — `/billing` inventory
```ruby
@active_collectives = Collective.for_user_across_tenants(current_user).billable_types.where(
  tenant_id: billing_tenant_ids,
  archived_at: nil,
  pending_billing_setup: false,
  tier: Collective::TIER_PAID,
).where.not(id: main_collective_ids).includes(:tenant).order(:name)
```

Add a `lapsed` section ("Resume billing") to the inventory.

### H — `User#active_billable_collective_count`
Collapses to single SQL count filtered by `tier: TIER_PAID` (no Ruby filter, no per-tenant automation batching).

### I — Tests
Drop tests for removed predicates (`would_be_paid_tier?`, `owner_billing_setup?`, transition gate). Add:
- State machine transitions (valid + invalid, idempotency, owner-auth)
- `downgrade!` disables features; `mark_lapsed!` doesn't
- `restore_from_lapsed!` works without per-feature restoration
- Upgrade/Downgrade controller actions
- Webhook → mark_lapsed; webhook → restore_from_lapsed
- Inventory uses `tier`

Replace the 3 scattered "make this paid" test helpers with one in `test_helper.rb`:

```ruby
def upgrade_collective_to_paid!(collective, owner: collective.created_by)
  StripeCustomer.find_or_create_by!(billable: owner) do |c|
    c.stripe_id = "cus_test_#{SecureRandom.hex(4)}"
    c.active = true
  end
  collective.update!(tier: Collective::TIER_PAID)
end
```

### J — Docs
Update `memory/project_billing_status.md`; CHANGELOG at release.

## Open questions (decide during impl)

1. Keep 3 commits + add 4th refactor commit, or squash. I lean keep — each is coherent.
2. Upgrade button copy ("Upgrade to Paid ($3/month)" vs just "Upgrade").

## Risks

- **Big surface area** — schema, 6 controllers, webhooks, views, tests.
- **Stripe Checkout integration** is highest-risk piece; per-user flow is already complex.
- **Webhook drift** — backstop via daily `BillingReconciliationJob`.
- **Test fixture churn** — many tests need the new `upgrade_collective_to_paid!` helper.
- **UX scope creep** in upgrade/downgrade pages — stay minimal for v1.
