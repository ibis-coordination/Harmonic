# UserList — addressable, governable subgroups (v2 plan)

## Goal

Replace "follow" with **add to list**. Every user has a primary list ("[Name]'s
list") that's auto-created on first interaction; the "add to list" gesture
from a user's profile is the load-bearing UX move. Users can also create
additional lists with configurable add policies.

Lists are addressable subgroups within a collective: you can name them,
reference them, and (later) deliver decisions / commitments / notifications
to them.

## Out of scope for v1

- Ownership transfer (schema supports mutable `owner_id`; no endpoint yet)
- Separate moderators table (lightweight moderation will be expressed via the Phase 3 `add_policy` enum instead)
- `remove_others_policy` variants (rule is fixed: owner can remove anyone; user can remove themselves; nobody else)
- Anonymous read
- HTML UI (markdown + LLM actions only)
- Lists in non-main collectives (schema permits; routes restrict)
- Banner image, member cap
- Subscribe-to-list / list-feed / timeline (there is no follow graph; lists are *addressed*, not *subscribed to*)
- `Linkable` inclusion (deferred until concrete consumer exists)
- Notifications to listed users (added in a later phase)

## Why these shapes

- **"Add to list" is the headline gesture.** Single button on a profile.
  Auto-creates the actor's primary list on first use.
- **Primary list per user, per tenant.** `is_primary: true` is unique within
  `(tenant_id, owner_id, deleted_at IS NULL)`. The primary always lives in
  `tenant.main_collective` by convention (the "[Name]'s list" social
  signal is tenant-wide; non-main collectives are for named, context-scoped
  custom lists rather than primaries).
- **Truncated_id identifies lists in URLs.** Matches `Note` / `Decision` /
  `Commitment` precedent. No slugs, no reserved-name list, no route-ordering
  ritual.
- **Lists are top-level resources at `/lists/:list_id`**, not nested under
  the user. Twitter shape (`twitter.com/i/lists/12345`). A listing view at
  `/u/:handle/lists` shows lists owned by a given user.
- **`creator_id` immutable, `owner_id` mutable.** Two columns, two concerns:
  provenance (audit) vs current controller (transferable).
- **No `add_policy` in Phase 0.** Phase 0 ships owner-only-add as the
  implicit rule (nothing reads a policy yet). The column + enum land in
  Phase 3 alongside policy enforcement, with the value set chosen then
  based on concrete needs.
- **Markdown + dual-interface actions ship before HTML UI** (same rationale
  as the first attempt — harder design surface first, agents get the feature
  immediately, HTML layers on later).

---

## Schema

### `user_lists`

```ruby
create_table :user_lists, id: :uuid do |t|
  t.references :tenant,     type: :uuid, null: false, foreign_key: true
  t.references :collective, type: :uuid, null: false, foreign_key: true
  t.references :creator,    type: :uuid, null: false, foreign_key: { to_table: :users }
  t.references :owner,      type: :uuid, null: false, foreign_key: { to_table: :users }

  t.string  :truncated_id,   null: false, as: "LEFT(id::text, 8)", stored: true
  t.string  :name,           null: false
  t.text    :description
  t.string  :visibility,     null: false, default: "public"   # "public" | "private"
  t.boolean :is_primary,     null: false, default: false
  t.integer :members_count,  null: false, default: 0
  # `add_policy` column added in Phase 3.
  t.datetime :deleted_at
  t.uuid     :deleted_by_id

  t.timestamps
end

add_index :user_lists, :truncated_id, unique: true
add_index :user_lists, [:tenant_id, :owner_id],
          unique: true,
          where: "is_primary = TRUE AND deleted_at IS NULL",
          name: "index_user_lists_one_primary_per_owner_per_tenant"
add_index :user_lists, [:collective_id, :visibility]
add_index :user_lists, :deleted_at
```

### `user_list_members`

```ruby
create_table :user_list_members, id: :uuid do |t|
  t.references :tenant,     type: :uuid, null: false, foreign_key: true
  t.references :collective, type: :uuid, null: false, foreign_key: true
  t.references :user_list,  type: :uuid, null: false, foreign_key: true
  t.references :user,       type: :uuid, null: false, foreign_key: true   # the member
  t.references :added_by,   type: :uuid, null: false, foreign_key: { to_table: :users }
  t.timestamps
end

add_index :user_list_members, [:user_list_id, :user_id], unique: true,
          name: "index_user_list_members_on_list_and_user"
add_index :user_list_members, [:user_id, :collective_id],
          name: "index_user_list_members_on_user_and_collective"
```

**No `user_list_subscribers` table.** That concept is gone.

---

## Models

### `UserList`

```ruby
class UserList < ApplicationRecord
  extend T::Sig

  include HasTruncatedId
  include SoftDeletable

  VISIBILITIES = ["public", "private"].freeze

  belongs_to :tenant
  belongs_to :collective
  belongs_to :creator, class_name: "User"
  belongs_to :owner,   class_name: "User"

  has_many :user_list_members, dependent: :destroy
  has_many :members, through: :user_list_members, source: :user

  validates :name,        presence: true, length: { maximum: 80 }
  validates :description, length: { maximum: 500 }, allow_nil: true
  validates :visibility,  inclusion: { in: VISIBILITIES }
  validate  :one_primary_per_owner

  attr_readonly :tenant_id, :collective_id, :creator_id   # NOT owner_id

  sig { returns(T::Boolean) }
  def public?;  visibility == "public";  end

  sig { returns(T::Boolean) }
  def private?; visibility == "private"; end

  # Visibility predicate. Soft-deleted lists are filtered at query layer.
  sig { params(user: T.nilable(User)).returns(T::Boolean) }
  def visible_to?(user)
    return false if user.nil?
    return true if user.id == owner_id
    return false if private?
    CollectiveMember.exists?(collective_id: collective_id, user_id: user.id)
  end

  # Canonical path. No handle-in-URL since lists are top-level.
  sig { returns(String) }
  def path
    "/lists/#{truncated_id}"
  end

  sig { returns(String) }
  def content_snapshot
    [name, description].compact.join("\n\n")
  end
end
```

### `UserListMember`

```ruby
class UserListMember < ApplicationRecord
  belongs_to :tenant
  belongs_to :collective
  belongs_to :user_list
  belongs_to :user
  belongs_to :added_by, class_name: "User"

  validates :user_id, uniqueness: { scope: :user_list_id }
  validate  :scope_matches_list
  validate  :respects_blocks
  validate  :member_is_collective_member

  attr_readonly :tenant_id, :collective_id, :user_list_id

  after_create_commit  :increment_members_count
  after_destroy_commit :decrement_members_count
end
```

### `User` additions

```ruby
has_many :created_user_lists, class_name: "UserList", foreign_key: :creator_id
has_many :owned_user_lists,   class_name: "UserList", foreign_key: :owner_id, dependent: :restrict_with_exception
has_many :user_list_memberships, class_name: "UserListMember", dependent: :destroy
has_many :lists_im_on, through: :user_list_memberships, source: :user_list

# Primary list helper — lazy creation guarded by transaction + race-recovery.
# Per-tenant uniqueness: the primary always lives in tenant.main_collective.
sig { params(tenant: Tenant).returns(UserList) }
def primary_user_list_in!(tenant)
  UserList.transaction do
    existing = primary_user_list_in(tenant)
    return existing if existing
    UserList.create!(
      creator: self, owner: self,
      tenant: tenant, collective: tenant.main_collective,
      name: "#{display_name || name}'s list", is_primary: true, visibility: "public",
    )
  rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
    T.must(primary_user_list_in(tenant))
  end
end
```

The `dependent: :restrict_with_exception` on `owned_user_lists` ensures a user
cannot be destroyed while owning lists — forces transfer (later) or list
deletion first. Safer than `:destroy` (which would silently wipe everyone's
lists when a user is deleted).

---

## Routes

```ruby
# === Tenant subdomain root (alongside /n, /d, /c) ===
scope '/lists' do
  get  'actions'                            => 'user_lists#actions_index_new'
  get  'actions/create_user_list'           => 'user_lists#describe_create_user_list'
  post 'actions/create_user_list'           => 'user_lists#execute_create_user_list'
end

resources :user_lists, path: 'lists', param: :list_id, only: [:show] do
  member do
    get  'actions'                          => 'user_lists#actions_index_show'
    get  'actions/update_user_list'         => 'user_lists#describe_update_user_list'
    post 'actions/update_user_list'         => 'user_lists#execute_update_user_list'
    get  'actions/delete_user_list'         => 'user_lists#describe_delete_user_list'
    post 'actions/delete_user_list'         => 'user_lists#execute_delete_user_list'
    get  'actions/add_member'               => 'user_lists#describe_add_member'
    post 'actions/add_member'               => 'user_lists#execute_add_member'
    get  'actions/remove_member'            => 'user_lists#describe_remove_member'
    post 'actions/remove_member'            => 'user_lists#execute_remove_member'
  end
end

# === Under the user namespace ===
resources :users, path: 'u', param: :handle, only: [] do
  # Listing view: lists owned by this user (links to /lists/:list_id)
  get 'lists' => 'user_lists#index', on: :member

  # The headline gesture — "add this user to my primary list"
  get  'actions/add_to_list'    => 'users#describe_add_to_list',    on: :member
  post 'actions/add_to_list'    => 'users#execute_add_to_list',     on: :member
  get  'actions/remove_from_list' => 'users#describe_remove_from_list', on: :member
  post 'actions/remove_from_list' => 'users#execute_remove_from_list',  on: :member
end
```

URL summary:
- `/lists/:list_id` — canonical show URL
- `/u/:handle/lists` — listing of lists owned by user
- `/u/:handle/actions/add_to_list` — one-click gesture (uses current_user's primary list)
- `/lists/:list_id/actions/add_member` — explicit "add user X to this specific list"

---

## Actions (dual interface)

| Action | Where | Params | Auth |
|--------|-------|--------|------|
| `create_user_list` | `/lists/actions/...` | `name`, `description?`, `visibility?` | authenticated |
| `update_user_list` | `/lists/:id/actions/...` | `name?`, `description?`, `visibility?` | owner only |
| `delete_user_list` | `/lists/:id/actions/...` | (none) | owner only AND not is_primary |
| `add_member` | `/lists/:id/actions/...` | `user_handle` | owner only (Phase 2); per-policy in Phase 3 |
| `remove_member` | `/lists/:id/actions/...` | `user_handle` | owner OR self (target_user == current_user) |
| `add_to_list` | `/u/:handle/actions/...` | (none) | authenticated; auto-resolves current_user's primary list |
| `remove_from_list` | `/u/:handle/actions/...` | (none) | authenticated; removes URL handle from current_user's primary list |

### add_policy

Deferred to Phase 3. Until then, the implicit rule for every list is
**owner_only** (only the list's `owner_id` user can add members). The column,
enum values, and `update_user_list` `add_policy?` param land in Phase 3.

### Block respect

- Symmetric block (`UserBlock.between?`) between adder and target → reject.
- Symmetric block between owner and target → reject (even when adder is not the owner — relevant once non-owner-add policies exist).
- Self-removal always allowed regardless of blocks.

### Visibility rules

| Action | Public list | Private list |
|--------|-------------|--------------|
| Read (show, members listing) | Any collective member | Owner only (404 to others — existence hidden) |
| Appear in `/u/:handle/lists` | Yes | Only when `current_user == owner` |
| Mutations (update/delete/add/remove) | Owner / per-policy | Owner only (404 to others) |

Existence-hiding pattern: `set_list` filters by `visible_to?(current_user)`; if the
list exists but the current user can't see it, `@list` is left nil → the action's
existing `@list.nil?` check renders 404. Same single 404 for "doesn't exist" and
"exists but hidden."

---

## Phasing

### ✅ Phase 0 — Schema + bare models — SHIPPED (commit 4bcffd8)

- Migration: `user_lists` + `user_list_members`.
- Models: `UserList`, `UserListMember`, `User` additions.
- Validations: name/description/visibility; one_primary_per_owner_per_tenant;
  primary_list_is_strictly_owners (owner_id and is_primary immutable on
  primaries); scope_matches_list; respects_blocks; member_is_collective_member.
- `User#primary_user_list_in!(tenant)` lazy-creates in main_collective.
- `User#created_user_lists` and `owned_user_lists` use
  `dependent: :restrict_with_exception`.

### ✅ Phase 1 — The "add to list" gesture — SHIPPED (commit 34defdb)

- Action endpoints at `/u/:handle/actions/{add_to_list,remove_from_list}`.
- `add_to_list` lazy-creates the actor's list and upserts membership;
  idempotent.
- Self-add returns 422 (decided).
- Action authorization is a Proc that hides actions on the actor's own
  profile (target_user == current_user) so frontmatter only offers them
  when meaningful.
- `remove_from_list` distinguishes "Removed from your list." vs "Not on
  your list." outcomes.
- Both actions added to `CapabilityCheck.AI_AGENT_GRANTABLE_ACTIONS`.
- Verified end-to-end via the harmonic MCP.

### Phase 2 — Custom list CRUD (markdown + actions)

- `create_user_list`, `update_user_list`, `delete_user_list`.
- `/lists/:list_id` show page (markdown).
- `/u/:handle/lists` index page (markdown).
- ActionsHelper entries + `CapabilityCheck.AI_AGENT_GRANTABLE_ACTIONS`
  inclusion for the three actions plus `add_to_list` / `remove_from_list` /
  `add_member` / `remove_member`.
- Existence-hiding via `set_list`.
- Primary list cannot be deleted while is_primary=true (422).

### Phase 3 — `add_policy` column + enforcement

- Migration: add `add_policy` string column to `user_lists` with default
  `owner_only`.
- Define the policy enum values based on concrete needs at that point —
  candidates: `owner_only`, `members_can_invite`, `self_add` (decide which to
  ship based on use cases that have emerged).
- Update `add_member` / `remove_member` to enforce policy. `update_user_list`
  gains an `add_policy?` param.
- Tests for each policy and each block-relation direction.
- Self-removal-always-allowed verified across policies.

### Phase 4 — HTML UI

- Profile "Add to list" / "On your list" button (toggle).
- List show page HTML.
- List form HTML (new + edit).
- Listing on `/u/:handle/lists`.
- System tests for the core gestures.

### Phase 5 — Polish + ship

- Lint, type-check, manual test checklist.
- (CHANGELOG and version bump handled separately per repo convention.)

---

## Open questions (decide during implementation)

1. **Adding yourself to your own primary list.** The first `add_to_list` gesture
   on your own profile would try to add you to your own list. Disallow (422)?
   Silently no-op? I'd lean **silently no-op + return success** — easier UX,
   harmless semantically.

2. **Primary list demotion.** Can a user demote `is_primary=true → false`?
   Default to **no** in v1 — primary is a fixed property once a list is born
   primary. (Avoids edge cases like "what's my primary now?")

3. **Notifications on add.** Notify the added user? **Defer entirely to a later
   phase.** v1 ships without notifications.

4. **Counter for "lists I'm on".** Useful for profile display. Skip in v1 —
   compute via `lists_im_on.count` on demand. Add a counter cache only if
   profile-load latency demands it.

5. **What about an `add_to_list` action that targets a non-primary list?**
   The `/u/:handle/actions/add_to_list` endpoint as designed always uses the
   primary list. To add to a specific list, agents use the explicit
   `/lists/:id/actions/add_member` endpoint. Two endpoints, two semantics:
   `add_to_list` is the one-button gesture; `add_member` is the general
   primitive.

6. **AI agent capability defaults.** New actions need both global
   `AI_AGENT_GRANTABLE_ACTIONS` registration AND each existing agent's
   `capabilities` allowlist update. The global update is part of the patch;
   per-agent updates are out-of-band (user action) — document but don't
   automate.

7. **Block bypass via creator/owner mismatch.** If A creates a list, transfers
   ownership to B (post-v1), and then C tries to add A to the list — should
   block(A,C) apply? Yes (target ↔ adder check is symmetric). Should
   block(B,C) also apply (since B is current owner)? Yes (owner ↔ target).
   But block(A,B) doesn't affect adds by C. (Documented for future transfer
   work; not relevant in v1.)

---

## Non-goals (explicit, recap)

- Subscribers / follow-the-list / list-feed semantics
- Ownership transfer (deferred to v2 with TrusteeGrant-style accept)
- Separate moderators table
- `remove_others_policy` variants
- Linkable inclusion (deferred until concrete consumer)
- Anonymous read of lists
- Banner image, member cap
- Lists in non-main collectives (schema-supported; UI/routes restrict)
- Notification on add (later)

---

## Dev-DB state (outside git)

The `Claude Code Primary` agent (id `fa59a88a-19c1-419a-afeb-330145aac850`)
had `add_to_list` and `remove_from_list` added to its `agent_configuration["capabilities"]`
during MCP verification of Phase 1. Persists in dev DB. Re-grant via runner
if testing again from a fresh clone:

```ruby
agent = User.find("fa59a88a-19c1-419a-afeb-330145aac850")
cfg = agent.agent_configuration.dup
cfg["capabilities"] = (cfg["capabilities"] + ["add_to_list", "remove_from_list"]).uniq
agent.update!(agent_configuration: cfg)
```

When new action endpoints land in later phases, the same agent will need
those capabilities granted before MCP-based verification will succeed.
