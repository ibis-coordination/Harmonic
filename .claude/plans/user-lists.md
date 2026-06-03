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

  # The headline gesture — "tune in to this user" (adds them to my primary list)
  get  'actions/tune_in'  => 'users#describe_tune_in',  on: :member
  post 'actions/tune_in'  => 'users#execute_tune_in',   on: :member
  get  'actions/tune_out' => 'users#describe_tune_out', on: :member
  post 'actions/tune_out' => 'users#execute_tune_out',  on: :member
end
```

URL summary:
- `/lists/:list_id` — canonical show URL
- `/u/:handle/lists` — listing of lists owned by user
- `/u/:handle/actions/tune_in` — one-click gesture (uses current_user's primary list)
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
| `tune_in` | `/u/:handle/actions/...` | (none) | authenticated; auto-resolves current_user's primary list |
| `tune_out` | `/u/:handle/actions/...` | (none) | authenticated; removes URL handle from current_user's primary list |

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

### ✅ Phase 1 — The "tune in" gesture — SHIPPED (commit 34defdb, renamed in a later commit)

Originally shipped as `add_to_list` / `remove_from_list`. Renamed to
`tune_in` / `tune_out` in a cosmetic pass after Phase 4 to align the
verbs between the HTML button copy ("Tune in" / "Tuned in") and the
markdown frontmatter action names.

- Action endpoints at `/u/:handle/actions/{tune_in,tune_out}`.
- `tune_in` lazy-creates the actor's primary list and upserts membership;
  idempotent.
- Self-tune-in returns 422 (decided).
- Action authorization is a Proc that hides actions on the actor's own
  profile (target_user == current_user) so frontmatter only offers them
  when meaningful.
- `tune_out` distinguishes "Tuned out." vs "Not tuned in." outcomes.
- Both actions added to `CapabilityCheck.AI_AGENT_GRANTABLE_ACTIONS`.
- Verified end-to-end via the harmonic MCP.

### ✅ Phase 2 — Custom list CRUD (markdown + actions) — SHIPPED

- `create_user_list`, `update_user_list`, `delete_user_list` (describe + execute).
- `/lists/:list_id` markdown show page; `/u/:handle/lists` markdown index.
- ActionsHelper entries + new `@@actions_by_route` for `/lists`, `/lists/:list_id`,
  `/u/:handle/lists`.
- `CapabilityCheck.AI_AGENT_GRANTABLE_ACTIONS` includes all three.
- Existence-hiding via `set_list` (private list to non-owner → 404).
- Non-owner mutation on a visible public list → 403.
- Primary list cannot be deleted while is_primary=true (422). Frontmatter on
  the primary list hides `delete_user_list` (auth Proc checks `!is_primary`).
- `MarkdownHelper.build_authorization_context` extended to include `@list` so
  resource-context-aware Procs receive the list when rendering frontmatter.
- Custom list ownership: created in `tenant.main_collective`; lists in non-main
  collectives remain schema-supported but routes still restrict.

### ✅ Phase 3 — `add_policy` column + enforcement — SHIPPED

- Migration: `add_policy` string column on `user_lists`, NOT NULL, default `owner_only`.
- Four enum values (`UserList::VALID_ADD_POLICIES`):
  - `owner_only` — only the owner adds (anyone)
  - `self_add` — anyone in the collective can add themselves; owner adds anyone
  - `members_add` — list members (and owner) add anyone; non-members can't self-add
  - `anyone_add` — any collective member adds anyone
- `UserList#can_add?(actor:, target:)` encapsulates the policy logic. Owner
  always returns true regardless of policy.
- `add_member` / `remove_member` action endpoints at `/lists/:id/actions/...`.
  - `add_member` resolves `user_handle`, checks `can_add?`, blocks/collective
    membership enforced by existing `UserListMember` validations.
  - `remove_member` is fixed-rule: owner removes anyone; user removes self;
    nobody else. No `remove_policy` (asymmetric on purpose — removes are
    subtractive and warrant stricter auth).
- `update_user_list` accepts an `add_policy` param. `create_user_list` accepts
  one too (defaults to `owner_only`).
- Frontmatter listing of `add_member` is policy-aware via the auth Proc: owner
  + self_add/anyone_add → everyone in collective; members_add → only members.
- Capability + ActionsHelper + routes wired for both new actions.
- **Primary and private lists are constrained to `owner_only`.** Primary lists
  are strictly the owner's by design; members of a private list can't see it,
  so non-owner_only add policies would be meaningless. Enforced by a model
  validation AND a DB CHECK constraint
  (`user_lists_restricted_owner_only`) — belt-and-suspenders, matching the
  partial-unique-index precedent for primary uniqueness.
- 33 controller tests + 24 model tests added (all green).

### ✅ Phase 4 — HTML UI — SHIPPED

- Profile "Add to your list" / "On your list" toggle button on `/u/:handle`
  (uses Phase 1 action endpoints; computes the toggle state by checking
  whether the showing user is on the current viewer's primary list).
- "Lists" accordion on `/u/:handle` showing lists owned by that user the
  viewer can see (private filtered out for non-owners).
- HTML show page at `/lists/:id` with name + badges (your list, private),
  owner link, member count + list, action buttons (Edit, Delete), and an
  in-page "Add a member" form (handle text input → submits to add_member
  action endpoint). Each member row has a Remove/Leave button for the owner
  or self.
- HTML index at `/u/:handle/lists` with a "New list" button for the owner.
- New/Edit form pages (`/lists/new`, `/lists/:id/edit`) submitting to the
  existing create/update action endpoints. Form covers name, description,
  visibility, and add_policy.
- `create_user_list` and `delete_user_list` pass an explicit `redirect_to`
  so the HTML flow lands on the new resource / owner's lists index instead
  of redirect_back_or_to bouncing to the form page.
- Browser-verified end-to-end: create, edit, show, add_member, profile
  toggle, delete (with turbo confirm), index. Unit/integration coverage
  (168 tests) backs the underlying actions.

Known limitation (deferred): when an owner switches a public list with
members to private, those members lose visibility and can't self-remove
via the existing remove_member endpoint. The owner can still prune; a
"lists I'm on" view would provide an alternate access path.

### ✅ Phase 5 — Mutual tuning-in detection + state-based button — SHIPPED

The HTML toggle and the markdown status line previously only expressed
the viewer's side of the relationship. This phase computes the reverse
direction as well and surfaces the four states on the profile, plus
sweeps the active-state wording to "tuned in" (past participle, state
label) while keeping "tune in" / "tune out" as the gesture verbs.

Four states (viewer V, profile-user P):

| V tunes in to P? | P tunes in to V? | Status                                                |
|------------------|------------------|-------------------------------------------------------|
| ✓                | ✓                | "You and P are _mutually tuned in_ to each other."    |
| ✓                | ✗                | "You are _tuned in_ to P."                            |
| ✗                | ✓                | "P is _tuned in_ to you."                             |
| ✗                | ✗                | "You are _not tuned in_ to P."                        |

Shipped:
- `users#show` computes `@viewer_on_target_list` (P→V) in parallel to
  the existing `@target_on_my_list` (V→P). Two `exists?` queries.
- Markdown view (`users/show.md.erb`) — four-state status line.
- HTML view (`users/show.html.erb`) — a `Tuned in to you` badge
  appears below the handle (muted-pill style) when P→V is true. The
  AjaxToggleButton still shows V's side.
- Wording sweep — "tuning in" → "tuned in" for state labels:
  - Toggle button on-state: "Tuned in" (off-state stays "Tune in").
  - Badge text: "Tuned in to you".
  - Markdown status: all four lines use "tuned in" (or "mutually
    tuned in").
  - Controller result strings: "Already tuned in.", "Not tuned in."
    (the `Tuned in.` / `Tuned out.` outcomes already used past tense).
- State-based button class — the toggle button is now PRIMARY
  (`.pulse-action-btn`, dark filled) in the off state and SECONDARY
  (`.pulse-action-btn-secondary`, outlined) in the on state, so the
  call-to-action visually emphasizes the unset state and recedes once
  the relationship is established. Implemented by extending
  `AjaxToggleButtonComponent` with `on_class:` / `off_class:` params
  and adding an `alt-class` value to the `ajax-toggle` Stimulus
  controller that swaps `element.className` on toggle (alongside
  innerHTML and URL).
- Tests: 4 controller tests for the markdown states, 2 HTML tests
  for the badge presence/absence, 2 component tests for state-based
  classes, 2 Stimulus controller tests for the className swap.

Out of scope (deferred):
- Notifications when someone tunes in to you.
- Profile-level filters / sorting by mutual relationships.
- HTML status line mirroring the markdown ("You are tuned in to X" —
  the badge surfaces P→V but V→P is only shown via the toggle button).

### ✅ Phase 5.5 — Block integration on profile — SHIPPED (commit 13170b1)

Out-of-original-scope follow-up. The list feature shipped without explicit
block handling on the profile beyond the existing `UserListMember.respects_blocks`
validation. This phase wired blocks into the UI and trimmed the profile
header now that the new tune-in button had crowded it.

Shipped:
- **Profile header tidy.** Message link moved into the kebab menu. Block
  button label dropped the handle ("Block @handle" → "Block"; same for
  Unblock). The Block description now lives on the button as a `title`
  tooltip instead of always-visible muted text. Kebab button alignment
  fix in `pulse/_layout.css` (`.top-menu ul li button` got
  `display: inline-flex; align-items: center; gap: 8px;` to match the
  sibling `<a>` rule).
- **Unblock now `redirect_back`s** to the originating page (previously
  always landed on `/user-blocks`). Block was already doing this.
- **New blocks clear mutual primary-list memberships.** `after_create`
  callback on `UserBlock` wipes both directions within the block's tenant.
  Tolerates missing primary lists / one-sided tune-ins.
- **Profile (HTML + markdown) hides tune-in when blocked** and replaces
  the tuning-state line with "You have blocked X." (viewer-as-blocker) or
  "X has blocked you." (viewer-as-blocked).
- **Markdown frontmatter** `tune_in` / `tune_out` converted from static
  `actions:` to `conditional_actions:` that filter on `UserBlock.between?`.
  Added `showing_user` to `MarkdownHelper#build_condition_context`.
- **Message link in the kebab is suppressed** when a block exists in
  either direction (blocked users can't message each other).
- **Blocked profile is mostly empty.** The Common Collectives count chip
  and the Common Collectives, Lists, and Recent Activity accordions are
  all hidden on blocked profiles (HTML); the corresponding markdown
  sections drop too.
- Tests: 27 controller HTML tests + 24 markdown tests + 14 UserBlock
  model tests + 9 UserBlocks controller tests, all green; broader
  block-adjacent suite at 183/183.

Deferred / not in this phase:
- Backfill for memberships that pre-date the cleanup callback (one-time
  data sweep if any stale rows exist).
- Cleanup of custom (non-primary) list memberships on block — the spec
  was explicitly primary-only, but custom lists with members across
  blocks can still leak the listed user's presence to the blocker.
- Retiring the AjaxToggleButton title attribute that still promises
  "adds their activity to your timeline view" (drift toward a follow
  graph the code doesn't deliver — list-feeds tracked in a separate
  plan doc, `.claude/plans/user-list-feeds.md`).

### Phase 6 — Polish + ship

- Lint, type-check, manual test checklist.
- (CHANGELOG and version bump handled separately per repo convention.)

---

## Open questions (decide during implementation)

1. **Tuning in to yourself.** The first `tune_in` gesture on your own profile
   would try to add you to your own list. Disallow (422)? Silently no-op?
   I'd lean **silently no-op + return success** — easier UX, harmless
   semantically. (Shipped: 422 with "You can't tune in to yourself.")

2. **Primary list demotion.** Can a user demote `is_primary=true → false`?
   Default to **no** in v1 — primary is a fixed property once a list is born
   primary. (Avoids edge cases like "what's my primary now?")

3. **Notifications on add.** Notify the added user? **Defer entirely to a later
   phase.** v1 ships without notifications.

4. **Counter for "lists I'm on".** Useful for profile display. Skip in v1 —
   compute via `lists_im_on.count` on demand. Add a counter cache only if
   profile-load latency demands it.

5. **What about a `tune_in` action that targets a non-primary list?**
   The `/u/:handle/actions/tune_in` endpoint as designed always uses the
   primary list. To add to a specific list, agents use the explicit
   `/lists/:id/actions/add_member` endpoint. Two endpoints, two semantics:
   `tune_in` is the one-button gesture; `add_member` is the general
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
has the UserList action capabilities added to its
`agent_configuration["capabilities"]` for MCP verification (`tune_in`,
`tune_out`, `create_user_list`, `update_user_list`, `delete_user_list`,
`add_member`, `remove_member`). Persists in dev DB. Re-grant via runner
if testing again from a fresh clone:

```ruby
agent = User.find("fa59a88a-19c1-419a-afeb-330145aac850")
cfg = agent.agent_configuration.dup
new_caps = %w[tune_in tune_out create_user_list update_user_list delete_user_list add_member remove_member]
cfg["capabilities"] = (cfg["capabilities"] + new_caps).uniq
agent.update!(agent_configuration: cfg)
```

When new action endpoints land in later phases, the same agent will need
those capabilities granted before MCP-based verification will succeed.
