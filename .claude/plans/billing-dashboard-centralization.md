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

### Phase 3: Simplify resource pages — DONE

- Removed deactivate/reactivate forms from agent and collective settings pages
- Removed old routes: POST /ai-agents/:handle/deactivate, /reactivate, POST /collectives/:handle/deactivate, /reactivate
- Removed old controller actions and 12 associated tests
- Settings pages now show status with link to /billing
- Exempt resources show "billing-exempt" instead of "$3/month"
- Error messages reference billing page for reactivation
- Markdown views match HTML, including creator-only reactivation message for collectives
- Removed unnecessary Stripe proration API calls from settings controllers

### Phase 4: Pending billing state for resource creation — DONE

**Data model:**
- Added `pending_billing_setup` boolean to `users` and `collectives` tables (migration `20260410000001`)

**Creation flow:**
- When stripe_billing enabled and user has no active subscription, new agents/collectives are created with `pending_billing_setup: true`
- API tokens are not generated for pending agents
- User is shown "Set up billing to activate it" instead of "created successfully"
- Collective creation redirects to /billing when pending

**Blocking:**
- `AgentQueueProcessorJob` blocks pending agents from running tasks
- `AutomationExecutor` blocks pending agents from running automations
- Pending resources count in `billable_quantity` (so checkout includes them)

**Activation:**
- After Stripe checkout return, `activate_pending_resources!` clears the flag on all user's pending agents and collectives

**Billing page:**
- Pending resources shown in a "Pending Resources" section: "will activate once billing is set up"
- Also shown in the inventory table in the pre-checkout view with "$3/mo when active"

## All phases complete
