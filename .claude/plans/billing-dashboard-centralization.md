# Billing Dashboard Centralization

## Goal

Make the `/billing` page the single source of truth for everything billing-related. Every billable identity is listed by name, with direct deactivate/reactivate actions. The user should never be surprised by what they're paying for.

## Completed

### Phase 1: Billing page inventory (read-only) — DONE

- Billing page shows itemized inventory: every agent and collective listed by name with type icons
- Each row shows resource name (linked), type label "(agent)" / "(collective)", and cost
- Separate "Inactive Resources" section for archived/suspended items
- Cross-tenant notice when user belongs to other billing-enabled tenants
- Three view states: active subscription, all-exempt (no subscription needed), needs setup
- Pre-checkout itemization: users see exactly what they'll be billed for before Stripe checkout
- Shared `_inventory_table.html.erb` partial eliminates duplication across view branches
- Markdown API view (`show.md.erb`) matches HTML structure
- 8 new tests + all existing tests passing (264 total, 0 failures)

### Per-resource billing exemption — DONE

Changed `billing_exempt` from a blanket user-level bypass to per-resource:

**Data model:**
- Added `billing_exempt` boolean to `collectives` table (migration `20260410000000`)
- `billing_exempt` already existed on `users` (covers both humans and agents)

**Quantity calculation:**
- `User#billable_quantity(tenant)` = `(user exempt ? 0 : 1) + non-exempt agents + non-exempt collectives`
- `User#active_billable_agent_count` now excludes `billing_exempt: true` agents
- `User#active_billable_collective_count` now excludes `billing_exempt: true` collectives
- `StripeService.sync_subscription_quantity!` uses per-resource quantity, handles quantity 0

**Billing gate:**
- `User#stripe_billing_setup?(tenant)` now takes tenant param
- Returns true if active subscription OR `billable_quantity == 0` (all exempt)
- All callers updated (controllers, views, tests)

**Security fixes:**
- API agent creation (`api/v1/users_controller`) now checks `requires_stripe_billing?` before creating
- Checkout quantity uses `billable_quantity(tenant)` instead of hardcoded `1 + agents + collectives`
- Billing confirmation always required for agent/collective create and reactivate (even for exempt users)
- Toggle billing exemption now syncs Stripe subscription quantity
- Reconciliation job no longer skips exempt users (they may have non-exempt resources)
- Proration preview shown to all users, not just non-exempt
- All creation/reactivation views show billing info regardless of user exemption

## Remaining Phases

### Phase 2: Move deactivate/reactivate actions to billing page

**New routes** (all POST to billing controller):
- `POST /billing/deactivate_agent/:handle`
- `POST /billing/reactivate_agent/:handle`
- `POST /billing/deactivate_collective/:collective_handle`
- `POST /billing/reactivate_collective/:collective_handle`

**New controller actions** (`app/controllers/billing_controller.rb`):
- `deactivate_agent` — mirrors current `AiAgentsController#deactivate` logic
- `reactivate_agent` — mirrors current `AiAgentsController#reactivate` logic
- `deactivate_collective` — mirrors current `CollectivesController#deactivate` logic
- `reactivate_collective` — mirrors current `CollectivesController#reactivate` logic
- All redirect back to `/billing` after action

**Confirmation UX**:
- Deactivation: confirmation checkbox per resource (same as current)
- Reactivation: shows proration amount inline, confirmation checkbox

### Phase 3: Simplify resource pages

**Agent settings page** (`app/views/ai_agents/settings.html.erb`):
- Remove deactivate/reactivate forms
- When archived: show "This agent is inactive. [Manage on billing page](/billing)" instead of the reactivation form
- When active + stripe_billing enabled: show "This agent costs $3/mo. [Manage billing](/billing)" instead of the deactivation form

**Collective settings page** (`app/views/collectives/settings.html.erb`):
- Remove deactivate/reactivate forms
- Same pattern: status text + link to billing page

**Agent show page** — keep the status badge, update text to link to `/billing`

**Collective show page** — keep archived redirect to settings (this is about access control, not billing UI)

### Phase 4: Pending billing state for resource creation

When a user without a subscription creates an agent or collective:
- Resource created in a "pending" state (not yet active)
- Shows on billing page as "pending — set up billing to activate"
- Activated automatically once user sets up billing and pays

## Scope boundaries

- Cross-tenant notice is **read-only** — no managing other-tenant resources
- Creation billing confirmation stays on creation forms — not moving to billing page
- The Stripe portal link remains for payment method management and cancellation
- No changes to webhook handling or StripeService internals (beyond per-resource quantity)
- Agent/collective archival behavior unchanged (archive!, unarchive!, what gets disabled)
