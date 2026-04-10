# Per-Collective Billing

## Context

Every identity in Harmonic costs $3/month. We've implemented this for human users and AI agents. Now we need to extend it to collectives. Each collective has a collective identity user, and creating a non-main collective should cost $3/month billed to the creator.

**Who pays**: The user who creates the collective (via `created_by`). Their subscription quantity includes their collectives, same as their AI agents.

**Main collective is free**: Each tenant has one main collective (identified by `tenant.main_collective_id`). It doesn't count toward billing.

**Deactivate/reactivate**: Same pattern as agents. Collectives can be archived to stop billing and reactivated later.

## Changes

### 1. Migration: Add `archived_at` to collectives

Collectives currently have no archival mechanism. Add `archived_at` timestamp.

```ruby
add_column :collectives, :archived_at, :datetime
```

### 2. Collective model — `app/models/collective.rb`

Add archive/unarchive methods:
```ruby
def archive!
  update!(archived_at: Time.current)
end

def unarchive!
  update!(archived_at: nil)
end

def archived?
  archived_at.present?
end
```

### 3. User model — `app/models/user.rb`

Add `active_billable_collective_count(tenant)`:
```ruby
def active_billable_collective_count(tenant)
  Collective.where(
    tenant_id: tenant.id,
    created_by_id: id,
    archived_at: nil,
  ).where.not(id: tenant.main_collective_id).count
end
```

Update `active_billable_agent_count` is unchanged — but `sync_subscription_quantity!` needs to include both agents and collectives.

### 4. StripeService — `app/services/stripe_service.rb`

Update `sync_subscription_quantity!`:
```ruby
new_quantity = 1 + user.active_billable_agent_count(tenant) + user.active_billable_collective_count(tenant)
```

Update `preview_proration` similarly (already uses `item.quantity + 1`, which is correct since it previews adding one more unit regardless of type).

### 5. BillingController — `app/controllers/billing_controller.rb`

Update `@active_agent_count` to also include collectives for the subscription details display. Or add a separate `@active_collective_count`.

### 6. Billing page views

Update billing page to show collectives in the subscription breakdown:
```
Your account          $3/mo
AI Agents (3)         $9/mo
Collectives (2)       $6/mo
Total                 $18/mo
```

### 7. Collective creation — billing confirmation

**Controller**: `app/controllers/collectives_controller.rb`
- In `create` and `create_collective` actions: require `confirm_billing` param when `stripe_billing` enabled and user is not exempt and the new collective would not be the main collective
- Sync subscription quantity after creation
- Show proration preview on the `new` form
- Show charge confirmation in flash after creation

**View**: `app/views/collectives/new.html.erb`
- Add billing confirmation section before submit (same pattern as agent creation)
- Show exact proration amount

**Markdown view**: `app/views/collectives/new.md.erb`
- Add billing info and `confirm_billing` parameter

### 8. Collective settings — deactivate/reactivate

**Routes**:
```ruby
post 'collectives/:collective_handle/deactivate' => 'collectives#deactivate'
post 'collectives/:collective_handle/reactivate' => 'collectives#reactivate'
```

**Controller**: `app/controllers/collectives_controller.rb`
- `deactivate`: archives collective, syncs quantity. Must be collective admin.
- `reactivate`: requires billing confirmation, unarchives, syncs quantity. Must be collective admin AND the billing user (creator).

**Settings view**: `app/views/collectives/settings.html.erb`
- When archived: show "Inactive" banner + reactivation form (same pattern as agent settings)
- When active: show "Deactivate Collective" at bottom
- Main collective: no deactivation option

**Settings markdown**: `app/views/collectives/settings.md.erb`
- Same pattern as agent settings markdown

### 9. Collective show page — status display

Show active/inactive/archived status on collective pages when `stripe_billing` is enabled, similar to agent show page.

### 10. Subscription loss — collective handling

`suspend_agents_for_customer` already suspends agents when subscription is lost. We should also archive collectives created by the user. However, collectives are shared resources — archiving them affects all members, not just the creator.

**Decision**: When subscription is lost, archive the user's created collectives (same as suspending their agents). When the user re-subscribes, they must manually reactivate each collective.

Update `StripeService.suspend_agents_for_customer` → rename to `deactivate_resources_for_customer` and also archive collectives.

### 11. BillingReconciliationJob

Already calls `sync_subscription_quantity!` which will automatically include collectives once the count method is updated. No changes needed.

### 12. Tests

- `active_billable_collective_count` — counts correctly, excludes main, excludes archived
- Collective creation with billing confirmation
- Collective deactivation/reactivation
- Subscription deletion archives collectives
- Billing page shows collective count
- Reconciliation includes collectives

## Files Summary

**New files:**
- `db/migrate/XXXXXX_add_archived_at_to_collectives.rb`

**Modified files:**
- `app/models/collective.rb` — archive/unarchive methods
- `app/models/user.rb` — `active_billable_collective_count`
- `app/services/stripe_service.rb` — quantity includes collectives, rename suspend method
- `app/controllers/collectives_controller.rb` — billing confirmation, deactivate/reactivate
- `app/controllers/billing_controller.rb` — collective count for view
- `app/views/collectives/new.html.erb` — billing confirmation UI
- `app/views/collectives/new.md.erb` — billing info
- `app/views/collectives/settings.html.erb` — deactivate/reactivate UI
- `app/views/collectives/settings.md.erb` — deactivate/reactivate info
- `app/views/billing/show.html.erb` — collective count in breakdown
- `app/views/billing/show.md.erb` — collective count in breakdown
- `config/routes.rb` — deactivate/reactivate routes
- `docs/BILLING.md` — document collective billing

## Verification

1. Run tests
2. Sorbet type check
3. Manual test: create collective → see proration, confirm, check Stripe quantity
4. Manual test: deactivate collective → quantity decrements, credit applied
5. Manual test: reactivate → confirmation, charge, quantity increments
6. Verify main collective is never billed
