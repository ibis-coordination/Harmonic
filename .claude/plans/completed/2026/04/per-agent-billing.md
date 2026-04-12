# Per-Agent Billing + Billing Exemption

## Context

Harmonic currently charges human users $3/month for an account subscription. We need to extend this so that each AI agent identity also costs $3/month, billed to the parent human user. Additionally, admins need the ability to grant free accounts that bypass billing entirely.

**Motivation**: Every identity in the system (human or AI) represents a real actor that can create content, make decisions, and interact with other users. The per-identity cost ensures aligned incentives and prevents unbounded agent proliferation.

**Approach**: Subscription quantity on the same Price. User pays `$3 × (1 + active_agent_count)` per month. Stripe handles proration automatically when agents are added or removed mid-cycle.

---

## Phase 1: Migration + Billing Exemption

### 1.1 Migration

New file: `db/migrate/XXXXXX_add_billing_exempt_to_users.rb`
- Add `billing_exempt` boolean to users (default: false, null: false)

### 1.2 User model changes — `app/models/user.rb`

Update `stripe_billing_setup?` (~line 470):
```ruby
def stripe_billing_setup?
  billing_exempt? || (stripe_customer&.active? || false)
end
```

Add `active_billable_agent_count(tenant)` method:
```ruby
def active_billable_agent_count(tenant)
  ai_agents
    .joins(:tenant_users)
    .where(tenant_users: { tenant_id: tenant.id, archived_at: nil })
    .where(suspended_at: nil)
    .count
end
```

Takes tenant as an explicit parameter so it doesn't depend on thread-local state. This matters because `sync_subscription_quantity!` may be called from admin controllers or background jobs where `Tenant.current_id` isn't the right tenant.

### 1.3 Admin toggle — `app/controllers/app_admin_controller.rb`

Add describe/execute actions for `toggle_billing_exempt`, following the existing suspension pattern. Toggle `user.billing_exempt`, log to `SecurityAuditLog`.

Update admin user views to show billing exemption status.

### 1.4 Tests (RED then GREEN)

- `stripe_billing_setup?` returns true when `billing_exempt` is true (no StripeCustomer needed)
- `stripe_billing_setup?` falls back to `stripe_customer.active?` when not exempt
- `active_billable_agent_count` counts only non-archived, non-suspended agents for the given tenant
- Admin toggle_billing_exempt requires app_admin

---

## Phase 2: Subscription Quantity Sync

### 2.1 StripeService — `app/services/stripe_service.rb`

Add `sync_subscription_quantity!(user, tenant)`:
```ruby
def self.sync_subscription_quantity!(user, tenant)
  return if user.billing_exempt?
  sc = user.stripe_customer
  return unless sc&.active? && sc.stripe_subscription_id.present?

  new_quantity = 1 + user.active_billable_agent_count(tenant)
  Stripe::Subscription.update(sc.stripe_subscription_id, quantity: new_quantity)
  Rails.logger.info("[StripeService] Updated subscription #{sc.stripe_subscription_id} quantity to #{new_quantity}")
rescue Stripe::StripeError => e
  Rails.logger.error("[StripeService] Failed to update subscription quantity for user #{user.id}: #{e.message}")
  # Do not re-raise — user action should not be blocked by Stripe failure
end
```

Key design choices:
- **Recomputes from DB state** (not increment/decrement). Last write wins, always correct. No race conditions.
- **Rescue and log** on Stripe failure. The user action (create agent, archive, etc.) proceeds regardless.
- **Takes tenant explicitly** so it doesn't depend on thread-local state.

### 2.2 Checkout initial quantity — `app/services/stripe_service.rb`

Update `create_checkout_session` to set initial quantity based on existing active agents:
```ruby
def self.create_checkout_session(stripe_customer:, success_url:, cancel_url:, quantity: 1)
  session = Stripe::Checkout::Session.create(
    customer: stripe_customer.stripe_id,
    mode: "subscription",
    line_items: [{ price: ENV.fetch("STRIPE_PRICE_ID"), quantity: quantity }],
    success_url: success_url,
    cancel_url: cancel_url,
  )
  T.must(session.url)
end
```

In `BillingController#setup`, compute and pass the quantity:
```ruby
quantity = 1 + current_user.active_billable_agent_count(current_tenant)
checkout_url = StripeService.create_checkout_session(
  stripe_customer: stripe_customer,
  success_url: success_url,
  cancel_url: billing_url,
  quantity: quantity,
)
```

### 2.3 Tests (RED then GREEN)

- `sync_subscription_quantity!` sends correct quantity to Stripe
- `sync_subscription_quantity!` is no-op for billing_exempt users
- `sync_subscription_quantity!` is no-op without active subscription
- `sync_subscription_quantity!` logs and does not raise on Stripe failure
- `create_checkout_session` sets initial quantity based on agent count

---

## Phase 3: Lifecycle Hooks

Every agent lifecycle event calls `sync_subscription_quantity!` to recompute the correct quantity.

### 3.1 Agent created — `app/controllers/ai_agents_controller.rb`

After `assign_billing_customer!` in `execute_create_ai_agent` (~line 319):
```ruby
StripeService.sync_subscription_quantity!(current_user, current_tenant)
```

### 3.2 Agent created via API — `app/controllers/api/v1/users_controller.rb`

In `create` (~line 18), after agent creation:
```ruby
if current_tenant.feature_enabled?("stripe_billing")
  assign_billing_customer!(user)
  StripeService.sync_subscription_quantity!(current_user, current_tenant)
end
```

### 3.3 Agent archived/unarchived via API — `app/controllers/api/v1/users_controller.rb`

In `update` (~line 37-41), after archive!/unarchive!:
```ruby
if user.ai_agent? && current_tenant.feature_enabled?("stripe_billing") && user.parent_id.present?
  parent = User.find_by(id: user.parent_id)
  StripeService.sync_subscription_quantity!(parent, current_tenant) if parent
end
```

### 3.4 Agent hard-deleted via API — `app/controllers/api/v1/users_controller.rb`

In `destroy` (~line 48), after successful deletion:
```ruby
if user.ai_agent? && current_tenant.feature_enabled?("stripe_billing") && user.parent_id.present?
  parent = User.find_by(id: user.parent_id)
  StripeService.sync_subscription_quantity!(parent, current_tenant) if parent
end
```

### 3.5 Agent suspended — `app/models/user.rb`

In `suspend!` (~line 404), add billing sync after the recursive suspension block. Use a `skip_billing_sync` parameter to avoid N+1 Stripe calls when a parent's agents are recursively suspended:

```ruby
def suspend!(by:, reason:, skip_billing_sync: false)
  # ... existing logic ...
  ai_agents.where(suspended_at: nil).find_each do |ai_agent|
    ai_agent.suspend!(by: by, reason: "Parent user suspended: #{reason}", skip_billing_sync: true)
  end

  unless skip_billing_sync
    billing_user = ai_agent? ? User.find_by(id: parent_id) : self
    tenant = billing_user&.tenant_users&.first&.tenant
    if billing_user && tenant&.feature_enabled?("stripe_billing")
      StripeService.sync_subscription_quantity!(billing_user, tenant)
    end
  end
end
```

### 3.6 Agent unsuspended — `app/controllers/app_admin_controller.rb`

In `execute_unsuspend_user`, after `user.unsuspend!`:
```ruby
if user.ai_agent? && user.parent_id.present?
  parent = User.find_by(id: user.parent_id)
  tenant = user.tenant_users.first&.tenant
  if parent && tenant&.feature_enabled?("stripe_billing")
    StripeService.sync_subscription_quantity!(parent, tenant)
  end
end
```

Note: `unsuspend!` does NOT recursively unsuspend children. This is correct — an admin must individually unsuspend each agent. Each unsuspend triggers a sync.

### 3.7 Tests (RED then GREEN)

- Agent creation syncs quantity
- Agent archive decrements quantity
- Agent unarchive increments quantity
- Agent hard-delete decrements quantity
- Parent suspend syncs once (not per-agent)
- Agent unsuspend increments quantity

---

## Phase 4: Billing Page UI

### 4.1 Controller — `app/controllers/billing_controller.rb`

Add `@active_agent_count` to `show`:
```ruby
@active_agent_count = current_user.active_billable_agent_count(current_tenant) if @stripe_customer&.active?
```

### 4.2 Views — `app/views/billing/show.html.erb` and `show.md.erb`

When active, show subscription breakdown:
- Your account: $3/mo
- AI Agents (N): $N×3/mo
- Total: $(1+N)×3/mo

---

## Phase 5: Reconciliation Job (safety net)

### 5.1 Job — `app/jobs/billing_reconciliation_job.rb`

Periodic job that recomputes and syncs quantity for all active StripeCustomers. Catches drift from failed Stripe API calls. Run daily.

---

## Files Summary

**New files:**
- `db/migrate/XXXXXX_add_billing_exempt_to_users.rb`
- `app/jobs/billing_reconciliation_job.rb`

**Modified files:**
- `app/models/user.rb` — `stripe_billing_setup?`, `active_billable_agent_count`, `suspend!`
- `app/services/stripe_service.rb` — `sync_subscription_quantity!`, `create_checkout_session` quantity param
- `app/controllers/ai_agents_controller.rb` — sync after creation
- `app/controllers/api/v1/users_controller.rb` — sync after create/archive/unarchive/destroy
- `app/controllers/app_admin_controller.rb` — billing exempt toggle, sync on unsuspend
- `app/controllers/billing_controller.rb` — agent count for view
- `app/views/billing/show.html.erb` — subscription breakdown
- `app/views/billing/show.md.erb` — subscription breakdown
- Admin user views — billing exempt status

**Test files:**
- New/extended tests for each phase

---

## Verification

1. Run `./scripts/run-tests.sh` — all tests pass
2. Run `docker compose exec web bundle exec srb tc` — no type errors
3. Manual test:
   - Set up billing → subscription quantity = 1
   - Create agent → Stripe dashboard shows quantity = 2
   - Archive agent → quantity = 1
   - Unarchive agent → quantity = 2
   - Suspend agent → quantity = 1
   - Admin grants billing_exempt → user can access app without subscription
   - Admin revokes billing_exempt → user redirected to /billing
