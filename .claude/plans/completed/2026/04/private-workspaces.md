# Private Workspaces

## Context

We want every user (human and AI agent) to have a private workspace — a personal collective that only they can see and use. This enables agents to use Notes/Decisions/Commitments as memory, and gives humans a personal space for drafts, private notes, and personal organization.

Private workspaces are regular collectives with a special `collective_type` that causes them to be filtered from all public-facing collective lists and exempted from social features (invitations, representation, heartbeats) and billing.

**Privacy rule: Private workspaces are always 100% private.** Only the owner can access their workspace. No exceptions — not via representation sessions, not via trustee grants, not via parent-agent relationships. If someone wants to know what's in another user's workspace, they ask that user (or agent) directly.

## Design Decisions

### `collective_type` column

Add a `collective_type` string column to collectives (default: `"standard"`). A private workspace has `collective_type: "private_workspace"`. This is cleaner than a boolean or a JSONB settings key because:
- It's indexable and queryable at the DB level (efficient filtering)
- It's extensible if we add other collective types later
- It parallels `user_type` on User

### No parent/trustee access

The workspace has exactly one member: the owner. No read-only access, no parent access to agent workspaces, no trustee access via representation sessions. Reasons:
- "Everything here is always private" is the simplest possible mental model
- Read-only collective membership doesn't exist yet and would be a significant authorization system change
- Parents can ask agents about their memories via chat sessions
- Trustees can interact with the user through existing channels

### One workspace per tenant

Users can belong to multiple tenants. Each tenant association gets its own private workspace. This is natural because collectives require a `tenant_id`, and a user's work context differs per tenant.

### No identity user for private workspaces

Standard collectives auto-create a `collective_identity` User to represent the collective when it acts as a member of other collectives. Private workspaces don't participate in collective agency — they don't join other collectives or have representatives. Skipping the identity user avoids creating unnecessary User + TenantUser records (one per workspace). The `identity_user_id` column is already nullable in the DB.

### Creation triggered by `Tenant#add_user!`

Private workspaces need a tenant association and a user handle (for deriving the workspace handle). Both are available after `Tenant#add_user!` creates the TenantUser. An `after_create` callback on User fires too early — the user has no tenant_users at that point.

### Suspension does not affect workspaces

Suspension blocks a user from acting (revokes tokens, blocks execution). The workspace is private — if the owner is suspended, they can't log in anyway. No cascade needed. Archival does cascade, since archival is more permanent.

## Behavior Differences

| Behavior | Standard Collective | Private Workspace |
|----------|-------------------|-------------------|
| Appears in `/collectives` index | Yes | No |
| Appears in "Your Collectives" on `/whoami` | Yes | No |
| Appears in user profile "Common Collectives" | Yes | No |
| Appears in billing inventory | Yes | No |
| Counted in `billable_quantity` | Yes (unless exempt) | No |
| Appears in tenant admin dashboard | Yes | No |
| Appears in representation session collective list | Yes | No |
| Accessible during representation sessions | Yes (per grant scope) | **No — always blocked** |
| Appears in API `GET /api/v1/collectives` | Yes | No |
| Appears in trustee grant collective picker | Yes | No |
| Included in `TrusteeGrant#allows_collective?` | Yes (per scope) | **No — always false** |
| Appears in agent settings "Collective Memberships" | Yes | No |
| Can invite members | Yes | No |
| Can have representatives | Yes | No |
| Requires heartbeat | Yes (non-main) | No |
| Has identity user | Yes | **No** |
| Has cycles | Yes | Yes (for temporal organization) |
| Has notes/decisions/commitments | Yes | Yes |
| Has search | Yes | Yes |
| Has links/backlinks | Yes | Yes (within workspace only — links are already same-collective) |
| Has pinning | Yes | Yes |
| Directly navigable by URL (by owner) | Yes | Yes |
| Has settings page | Yes | Yes (simplified) |
| Has automations | Yes | Yes |
| `unlisted` | Configurable | Always true |
| `invite_only` | Configurable | Always true |
| Members | Multiple | Owner only |

## Plan

### Step 1: Migration — add `collective_type` column

**New file:** `db/migrate/TIMESTAMP_add_collective_type_to_collectives.rb`

```ruby
add_column :collectives, :collective_type, :string, default: "standard", null: false
add_index :collectives, :collective_type
```

### Step 2: Collective model — `private_workspace?`, scopes, identity user skip

**File:** [app/models/collective.rb](app/models/collective.rb)

Add scopes and predicate:
```ruby
scope :standard, -> { where(collective_type: "standard") }
scope :private_workspaces, -> { where(collective_type: "private_workspace") }
scope :not_private_workspace, -> { where.not(collective_type: "private_workspace") }

def private_workspace?
  collective_type == "private_workspace"
end
```

Make identity_user optional:
```ruby
belongs_to :identity_user, class_name: "User", optional: true
```

Skip identity user creation for private workspaces:
```ruby
def create_identity_user!
  return if collective_type == "private_workspace"
  return if identity_user
  # ... existing creation logic
end
```

Update `set_defaults` to enforce settings for private workspaces:
```ruby
def set_defaults
  # ... existing defaults ...
  if collective_type == "private_workspace"
    self.settings["unlisted"] = true
    self.settings["invite_only"] = true
    self.settings["all_members_can_invite"] = false
    self.settings["any_member_can_represent"] = false
  end
end
```

Add validation to prevent changing type after creation:
```ruby
validate :collective_type_immutable, on: :update

def collective_type_immutable
  errors.add(:collective_type, "cannot be changed") if collective_type_changed?
end
```

### Step 3: Create workspace when user is added to a tenant

**File:** [app/models/tenant.rb](app/models/tenant.rb) — `add_user!` (line 248)

After creating the TenantUser, create the private workspace:

```ruby
def add_user!(user)
  tu = tenant_users.create!(
    user: user,
    display_name: user.name,
    handle: user.name.parameterize
  )
  create_private_workspace_for!(user, tu) unless user.collective_identity?
  tu
end
```

New private method on Tenant:
```ruby
private

def create_private_workspace_for!(user, tenant_user)
  handle = "#{tenant_user.handle}-workspace"
  unless Collective.handle_available?(handle)
    handle = "#{handle}-#{SecureRandom.hex(3)}"
  end

  previous_collective_id = Collective.current_id
  begin
    collective = collectives.create!(
      name: "#{user.name}'s Workspace",
      handle: handle,
      created_by: user,
      collective_type: "private_workspace",
      billing_exempt: true,
    )

    Collective.scope_thread_to_collective(
      handle: collective.handle,
      subdomain: subdomain,
    )
    collective.add_user!(user, roles: ["admin"])
  ensure
    if previous_collective_id
      prev_collective = Collective.find_by(id: previous_collective_id)
      if prev_collective
        Collective.scope_thread_to_collective(
          handle: prev_collective.handle,
          subdomain: prev_collective.tenant.subdomain,
        )
      else
        Collective.clear_thread_scope
      end
    else
      Collective.clear_thread_scope
    end
  end
end
```

### Step 4: User model — `private_workspace` method + archival cascade

**File:** [app/models/user.rb](app/models/user.rb)

Add method:
```ruby
sig { returns(T.nilable(Collective)) }
def private_workspace
  @private_workspace ||= collectives.find_by(collective_type: "private_workspace")
end
```

Update `archive!`:
```ruby
def archive!
  T.must(tenant_user).archive!
  ApiToken.for_user_across_tenants(self).where(deleted_at: nil).find_each(&:delete!) if ai_agent?
  private_workspace&.archive!
end
```

Update `unarchive!`:
```ruby
def unarchive!
  T.must(tenant_user).unarchive!
  private_workspace&.unarchive!
end
```

Clear memoized `@private_workspace` in `reload`:
```ruby
def reload(options = nil)
  # ... existing removes ...
  remove_instance_variable(:@private_workspace) if defined?(@private_workspace)
  super
end
```

### Step 5: Block access via representation sessions and trustee grants

**5a. TrusteeGrant#allows_collective? — always return false for private workspaces**

**File:** [app/models/trustee_grant.rb](app/models/trustee_grant.rb) (line 120)

```ruby
def allows_collective?(collective)
  return false if collective.private_workspace?
  
  scope = studio_scope || { "mode" => "all" }
  # ... existing logic
end
```

**5b. ApplicationController navigation guard — explicit private workspace check**

**File:** [app/controllers/application_controller.rb](app/controllers/application_controller.rb) (line 452)

```ruby
if @current_representation_session&.user_representation? && !current_collective.is_main_collective?
  if current_collective.private_workspace?
    flash[:alert] = "Private workspaces cannot be accessed during representation."
    redirect_to "/representing"
    return
  end
  
  grant = @current_representation_session.trustee_grant
  unless grant&.allows_collective?(current_collective)
    flash[:alert] = "This collective is not included in your representation grant."
    redirect_to "/representing"
    return
  end
end
```

### Step 6: Filter private workspaces from all collective lists

**Controllers:**

| File | Location | Change |
|------|----------|--------|
| [collectives_controller.rb](app/controllers/collectives_controller.rb) | `index` (line 9) | Add `.not_private_workspace` to query |
| [api/v1/collectives_controller.rb](app/controllers/api/v1/collectives_controller.rb) | `index` (line 6) | Add `.not_private_workspace` to query |
| [representation_sessions_controller.rb](app/controllers/representation_sessions_controller.rb) | `representing` (line 134) | Add `.not_private_workspace` to query |
| [users_controller.rb](app/controllers/users_controller.rb) | `show` (lines 39, 43, 49) | Filter private workspaces from common collectives |
| [billing_controller.rb](app/controllers/billing_controller.rb) | `load_billing_inventory` (lines 367-383) | Add `.not_private_workspace` to all 3 queries |
| [ai_agents_controller.rb](app/controllers/ai_agents_controller.rb) | `settings` (line 80) | Filter from `@ai_agent_collectives` and `@available_collectives` |
| [trustee_grants_controller.rb](app/controllers/trustee_grants_controller.rb) | Line 61 | Add `.not_private_workspace` |

**Views:**

| File | Location | Change |
|------|----------|--------|
| [whoami/index.md.erb](app/views/whoami/index.md.erb) | Line 67 | Add `.not_private_workspace` to `user_collectives` query |
| [tenant_admin/dashboard.html.erb](app/views/tenant_admin/dashboard.html.erb) | Line 107 | Add `.reject(&:private_workspace?)` |
| [tenant_admin/dashboard.md.erb](app/views/tenant_admin/dashboard.md.erb) | Equivalent location | Same filter |
| [ai_agents/index.html.erb](app/views/ai_agents/index.html.erb) | Line 45 | Add `.reject(&:private_workspace?)` |
| [representation_sessions/_index_partial.html.erb](app/views/representation_sessions/_index_partial.html.erb) | Lines 29, 38 | Filter from identity user collectives list |
| [representation_sessions/index.md.erb](app/views/representation_sessions/index.md.erb) | Lines 15, 20 | Same filter |

**Models:**

| File | Location | Change |
|------|----------|--------|
| [user.rb](app/models/user.rb) | `active_billable_collective_count` (line 560) | Add `.not_private_workspace` to scope |

### Step 7: Block social features on private workspaces

**Heartbeats** — [app/services/actions_helper.rb](app/services/actions_helper.rb)

Update the 3 `send_heartbeat` conditional_action conditions (lines 630-634, 644-648, 672-676):
```ruby
condition: ->(context) {
  collective = context[:collective]
  current_heartbeat = context[:current_heartbeat]
  collective && !collective.is_main_collective? &&
    !collective.private_workspace? &&
    current_heartbeat.nil?
},
```

**Invitations** — [app/services/api_helper.rb](app/services/api_helper.rb)

Add early return in `create_invite` if `current_collective.private_workspace?`.

**Settings page** — [app/views/collectives/settings.html.erb](app/views/collectives/settings.html.erb) and [settings.md.erb](app/views/collectives/settings.md.erb)

Hide inapplicable sections for private workspaces:
- Invitations (lines 113-126)
- Representation (lines 128-141)
- AI Agents in collective (lines 179-237)

Wrap each in `<% unless @current_collective.private_workspace? %>`.

### Step 8: Navigation entry point

**File:** [app/views/whoami/index.md.erb](app/views/whoami/index.md.erb)

Add a "Your Workspace" section (before "Your Collectives") for all users. This is the only place the workspace link appears — agents find it here at task start, humans find it via `/whoami`.

For agents, the agent memory plan (separate) will replace this generic section with a richer "Your Memory" section.

```erb
<% if (workspace = @current_user.private_workspace) %>
## Your Workspace

[<%= workspace.name %>](<%= workspace.path %>) — your private workspace for personal notes and drafts.
<% end %>
```

During representation sessions, this section renders for the represented user but the link is blocked by the navigation guard (Step 5b). To avoid showing a dead link, guard it:

```erb
<% if !@current_representation_session && (workspace = @current_user.private_workspace) %>
```

### Step 9: Archival cascade (see Step 4)

Already covered in Step 4's `archive!`/`unarchive!` changes.

### Step 10: Rake task for existing users

**File:** `lib/tasks/private_workspaces.rake` (new)

Find all human and ai_agent users that belong to a tenant but don't have a private workspace in that tenant. Create one for each. Run post-deploy.

### Step 11: Tests

**Privacy enforcement (critical):**
- `TrusteeGrant#allows_collective?` returns false for private workspaces regardless of grant scope
- Navigating to another user's private workspace during a representation session redirects to `/representing`
- `/representing` page does not list the represented user's private workspace
- `/whoami` during representation does not show "Your Workspace" section
- API access to private workspace during representation is blocked

**Creation:**
- `Tenant#add_user!` for a human creates a private workspace in that tenant
- `Tenant#add_user!` for an ai_agent creates a private workspace (owner only — parent is NOT a member)
- `Tenant#add_user!` for a collective_identity does NOT create a private workspace
- Workspace has no identity user (nil)
- Workspace has correct settings: unlisted, invite_only, billing_exempt
- Workspace handle follows `{user_handle}-workspace` convention
- Handle collision appends hex suffix

**Filtering:**
- Private workspaces excluded from: `/collectives` index, billing inventory, `billable_quantity`, user profiles (common collectives), tenant admin, agent settings, API, trustee grant picker, representation session collective list
- Private workspace appears in owner's `/whoami` under "Your Workspace"
- Private workspace does NOT appear in `/whoami` during representation session

**Social features blocked:**
- Heartbeat action not shown for private workspaces
- Cannot create invite for a private workspace
- Settings page hides invitation/representation/AI agent sections

**Identity user:**
- Private workspace has nil identity_user
- Standard collective still creates identity user normally

**Lifecycle:**
- Archiving user archives workspace
- Unarchiving user unarchives workspace
- `collective_type` cannot be changed after creation

## Files to modify

| File | Change |
|------|--------|
| `db/migrate/...` | Add `collective_type` column (new) |
| `app/models/collective.rb` | `private_workspace?`, scopes, optional identity_user, skip creation, settings enforcement, type immutability |
| `app/models/tenant.rb` | `create_private_workspace_for!` in `add_user!` |
| `app/models/user.rb` | `private_workspace` method, archival cascade, reload cleanup |
| `app/models/trustee_grant.rb` | `allows_collective?` returns false for private workspaces |
| `app/controllers/application_controller.rb` | Block private workspace access during representation |
| `app/controllers/collectives_controller.rb` | Filter index |
| `app/controllers/api/v1/collectives_controller.rb` | Filter API index |
| `app/controllers/representation_sessions_controller.rb` | Filter representing view |
| `app/controllers/users_controller.rb` | Filter common collectives |
| `app/controllers/billing_controller.rb` | Filter inventory |
| `app/controllers/ai_agents_controller.rb` | Filter agent collective lists |
| `app/controllers/trustee_grants_controller.rb` | Filter collective picker |
| `app/services/actions_helper.rb` | Heartbeat exemption (3 places) |
| `app/services/api_helper.rb` | Block invites to private workspaces |
| `app/views/whoami/index.md.erb` | "Your Workspace" section + filter collectives list |
| `app/views/tenant_admin/dashboard.html.erb` | Filter collectives list |
| `app/views/tenant_admin/dashboard.md.erb` | Filter collectives list |
| `app/views/ai_agents/index.html.erb` | Filter collective memberships |
| `app/views/representation_sessions/_index_partial.html.erb` | Filter identity user collectives |
| `app/views/representation_sessions/index.md.erb` | Filter identity user collectives |
| `app/views/collectives/settings.html.erb` | Hide inapplicable sections |
| `app/views/collectives/settings.md.erb` | Hide inapplicable sections |
| `lib/tasks/private_workspaces.rake` | Backfill task (new) |

## Verification

1. Run full test suite to catch regressions
2. Create a human user — verify private workspace created, only owner is member, no identity user
3. Create an AI agent — verify private workspace created, parent is NOT a member
4. Visit private workspace directly — works for owner
5. Start a representation session as another user — verify their workspace is not listed, not navigable
6. Check TrusteeGrant with `mode: "all"` — verify `allows_collective?` still returns false for private workspace
7. Check `/collectives` index — no private workspaces
8. Check billing page — no private workspaces
9. Check tenant admin — no private workspaces
10. Archive a user — verify workspace also archived
