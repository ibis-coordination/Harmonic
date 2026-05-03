# Fix: AI Agents Not Added to Main Collective on Creation

## Bug

When an AI agent is created via `ApiHelper#create_ai_agent`, it calls `current_tenant.add_user!(user)` which adds the agent to the tenant (creates TenantUser) but does NOT add them to the main collective (no CollectiveMember created).

This means agents like "Bill" exist as tenant users but can't be found via collective-scoped queries (autocomplete, member lists, chat search). They also can't access main collective routes due to `validate_authenticated_access` checks in ApplicationController.

## Location

`app/services/api_helper.rb:728` — `current_tenant.add_user!(user)` without a subsequent `collective.add_user!(user)`.

## Fix

After `add_user!`, add the agent to the main collective and the current collective (if different):

```ruby
current_tenant.add_user!(user)
current_tenant.main_collective.add_user!(user)
if current_collective && current_collective.id != current_tenant.main_collective_id
  current_collective.add_user!(user)
end
```

Also need a data migration to backfill existing agents missing collective membership.

## Scope

- Fix `create_ai_agent` in ApiHelper
- Backfill migration for existing agents
- Test coverage
