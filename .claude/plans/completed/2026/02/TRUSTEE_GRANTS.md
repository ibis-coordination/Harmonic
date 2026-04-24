# Trustee Grants Implementation Plan

## Goal

Complete the trustee grants system to allow users to delegate specific capabilities to other users (including AI agents like Trio). This enables:

1. **User-to-user trustee grant** - Alice can grant Bob permission to act on her behalf
2. **User-to-agent trustee grant** - A user can grant Trio permission to create notes, vote, etc. on their behalf
3. **Transparency** - All delegated actions are attributed to a trustee user and logged in representation sessions

---

## Implementation Status

| Phase | Description | Status |
|-------|-------------|--------|
| **Phase 1** | Schema & Model Updates | ✅ Complete |
| **Phase 2** | Controller & Routes | ✅ Complete |
| **Phase 3** | User Interface | ✅ Complete |
| **Phase 4** | Representation Session Integration | ✅ Complete |
| **Phase 5** | Notifications | ⬚ Not Started |
| **Phase 6** | Trio Integration | ⬚ Not Started |
| **Phase 7** | Replace Impersonation | 🔶 Partial (7.4 remaining) |
| **Phase 8** | Simplify TrusteeGrant (remove synthetic users) | ✅ Complete |

### What's Complete
- ✅ `TrusteeGrant` model with CAPABILITIES constant, state methods, studio scoping
- ✅ Acceptance workflow (pending → active/declined/revoked/expired)
- ✅ `TrusteeGrantsController` at `/u/:handle/settings/trustee-grants`
- ✅ HTML and markdown views (index, new, show)
- ✅ `User#can_represent?` checks TrusteeGrant for user representation
- ✅ Capability enforcement consolidated into `ActionAuthorization` (TrusteeActionValidator removed)
- ✅ Auto-create TrusteeGrant when subagent is created
- ✅ Comprehensive tests for model, controller, and integration
- ✅ Navigation links from settings page to trustee grants with pending badge
- ✅ RepresentationSession extended with `trustee_grant_id` for user representation
- ✅ UI to start user representation sessions from trustee grants page (index and show)
- ✅ Capability enforcement via `require_capability!` in ApiHelper
- ✅ Subagent capability configuration for trustee grant actions (grantable, not always-allowed)
- ✅ Session history on trustee grant show page (Phase 4.7)
- ✅ Markdown API actions for all trustee grant operations (Phase 4.8)
- ✅ ActionsHelper integration with comprehensive test coverage (30 tests)
- ✅ Migration for existing subagents to create TrusteeGrants (Phase 7.2)
- ✅ `User#is_trusted_as?` method for representation checks (Phase 7.3)
- ✅ Session management uses representation sessions for parent-subagent (Phase 7.5)
- ✅ Tests updated for representation flow (Phase 7.6)
- ✅ **RepresentationSessionEvent** replaces old `activity_log` JSON column (2026-02-08)
- ✅ **Simplified TrusteeGrant** - `trustee_user` is now the actual person, not a synthetic user (Phase 8)
- ✅ `effective_user` returns `granting_user` for user representation (no synthetic user)

### What's Remaining
- ⬚ **Phase 5**: Notifications for trustee grant events
- ⬚ **Phase 6**: Trio integration and "Trio Access" settings
- ⬚ **Phase 7.4**: Remove impersonation UI (replace "Impersonate" with "Represent" flow)

---

## Current State (as of initial planning - now outdated)

~~### What Exists~~
~~- `TrusteeGrant` model with core fields~~
~~- `RepresentationSession` model - currently used for studio representation~~
~~- `grant_permissions!` and `revoke_permissions!` methods~~
~~- Test helper `create_trustee_grant`~~

~~### What's Missing~~
~~1. **Permission schema** - No defined structure for what can be granted~~
~~2. **Studio scoping** - Permissions need to be limited to specific studios~~
~~3. **Acceptance workflow** - Trusted user must accept the grant~~
~~4. **Authorization checks** - TODO at `User#can_represent?:140` for trustee grant trustees~~
~~5. **Controllers/routes** - No CRUD endpoints for TrusteeGrant~~
~~6. **UI** - No way for users to grant/manage permissions~~
~~7. **Notifications** - No alerts when trustee takes actions~~
~~8. **Enforcement** - No middleware to check permissions at action time~~

*See Implementation Status above for current state.*

## Design Decisions

### Unified Representation Model

**Key insight**: Use `RepresentationSession` for BOTH studio representation AND user representation.

The `RepresentationSession` model supports both types:
- `representative_user` - the person doing the acting
- `collective` - required for studio representation, NULL for user representation
- `trustee_grant` - required for user representation, NULL for studio representation
- `effective_user` method - returns the identity to use as `current_user`:
  - Studio: `collective.trustee_user`
  - User: `trustee_grant.granting_user`

**Flow comparison:**

| Step | Studio Representation | User Representation |
|------|----------------------|---------------------|
| Authorization | Studio role grants `can_represent?` | `TrusteeGrant` grants access |
| Session start | `POST /studios/:handle/represent` | `POST /u/:handle/settings/trustee-grants/:id/represent` |
| effective_user | `collective.trustee_user` | `trustee_grant.granting_user` |
| During session | Actions logged via `RepresentationSessionEvent` | Actions logged via `RepresentationSessionEvent` |
| Session end | `DELETE /studios/:handle/represent` | Same |

### Permission Schema

Use a **capability-based** model matching the app's core actions:

```ruby
TRUSTEE_CAPABILITIES = {
  # Content creation
  "create_notes" => "Create notes",
  "create_decisions" => "Create decisions",
  "create_commitments" => "Create commitments",

  # Participation
  "vote" => "Vote on decisions",
  "commit" => "Join commitments",
  "comment" => "Add comments",

  # Content management
  "edit_own_content" => "Edit content created by this trustee",
  "pin" => "Pin and unpin content",
}.freeze
```

The `permissions` JSONB stores granted capabilities:
```json
{
  "create_notes": true,
  "vote": true,
  "commit": true
}
```

### Studio Scoping

Permissions are scoped to specific studios:

```ruby
# New column on TrusteeGrant
t.jsonb :studio_scope, default: { "mode" => "all" }

# Examples:
{ "mode" => "all" }  # All studios where granting_user is a member
{ "mode" => "include", "studio_ids" => ["abc", "def"] }  # Only these studios
{ "mode" => "exclude", "studio_ids" => ["xyz"] }  # All except these
```

### Acceptance Workflow

TrusteeGrant requires acceptance:

```ruby
# New columns
t.datetime :accepted_at
t.datetime :declined_at
t.datetime :revoked_at

# States
pending   # Created, awaiting acceptance
active    # Accepted, not expired or revoked
declined  # Trusted user declined
revoked   # Granting user revoked
expired   # Past expires_at
```

### Notifications

Notify granting user when:
- Their trustee permission is accepted/declined
- Their trustee starts a representation session
- Their trustee takes actions (summary, not per-action)

---

## Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              TRUSTEE GRANT                                    │
│  (Standing authorization - can exist without active session)                  │
│                                                                               │
│  granting_user ─────────────────────────────────────> trustee_user            │
│  (the person      "allows to act on my behalf"        (the person             │
│   represented)                                         doing the acting)      │
│                                                                               │
│  States: pending → active (accepted)                                          │
│          pending → declined                                                   │
│          active  → revoked                                                    │
│          active  → expired                                                    │
│                                                                               │
└─────────────────────────────────────────────────────────────────────────────┘
                                       │
                                       │ when trustee_user wants to act
                                       ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                         REPRESENTATION SESSION                               │
│  (Active session - created when user starts representing)                    │
│                                                                              │
│  ┌───────────────────┐  represents   ┌───────────────────┐                   │
│  │ representative_   │──────────────>│ effective_user    │                   │
│  │ user              │               │ (granting_user)   │                   │
│  │ (trustee_user)    │               │                   │                   │
│  └───────────────────┘               └───────────────────┘                   │
│                                                                              │
│  User representation:                                                        │
│  - collective_id = NULL (can span studios)                                   │
│  - trustee_grant_id = grant.id                                               │
│  - Actions in any studio logged via RepresentationSessionEvent               │
│                                                                              │
│  States: active → ended (manual)                                             │
│          active → expired (24h)                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Comparison: Studio vs User Representation

```
STUDIO REPRESENTATION               USER REPRESENTATION
──────────────────────              ───────────────────

Authorization:                      Authorization:
  Studio role grants                  TrusteeGrant (accepted)
  can_represent?                      grants can_represent?

effective_user:                     effective_user:
  collective.trustee_user             trustee_grant.granting_user
  (studio's trustee)                  (person being represented)

Session creation:                   Session creation:
  RepresentationSession with          RepresentationSession with
  collective_id (required)            collective_id = NULL
  trustee_grant_id = NULL             trustee_grant_id (required)

Activity logging:                   Activity logging:
  RepresentationSessionEvent          RepresentationSessionEvent
  records per action                  records per action

Attribution:                        Attribution:
  Actions by "Studio Name"            Actions by granting_user

Path/URL:                           Path/URL:
  /studios/:handle/r/:id              /u/:handle/settings/trustee-grants/:id
```

---

## Phase 1: Schema & Model Updates ✅ COMPLETE

**Goal**: Extend TrusteeGrant with acceptance workflow, studio scoping, and capability definitions.

### 1.1 Database migration ✅

**File**: `db/migrate/YYYYMMDD_extend_trustee_grants.rb`

```ruby
class ExtendTrusteeGrants < ActiveRecord::Migration[7.0]
  def change
    add_column :trustee_grants, :accepted_at, :datetime
    add_column :trustee_grants, :declined_at, :datetime
    add_column :trustee_grants, :revoked_at, :datetime
    add_column :trustee_grants, :studio_scope, :jsonb, default: { "mode" => "all" }

    add_index :trustee_grants, :accepted_at
    add_index :trustee_grants, [:granting_user_id, :trusted_user_id], unique: true,
              where: "revoked_at IS NULL AND declined_at IS NULL",
              name: "idx_active_trustee_grants"
  end
end
```

### 1.2 Add capability constants and state methods ✅

**File**: `app/models/trustee_grant.rb`

```ruby
CAPABILITIES = {
  "create_notes" => { name: "Create notes", category: "content" },
  "create_decisions" => { name: "Create decisions", category: "content" },
  "create_commitments" => { name: "Create commitments", category: "content" },
  "vote" => { name: "Vote on decisions", category: "participation" },
  "commit" => { name: "Join commitments", category: "participation" },
  "comment" => { name: "Add comments", category: "participation" },
  "edit_own_content" => { name: "Edit trustee's content", category: "management" },
  "pin" => { name: "Pin/unpin content", category: "management" },
}.freeze

# States
def pending?
  accepted_at.nil? && declined_at.nil? && revoked_at.nil?
end

def active?
  accepted_at.present? && declined_at.nil? && revoked_at.nil? && !expired?
end

def declined?
  declined_at.present?
end

def revoked?
  revoked_at.present?
end

def expired?
  expires_at.present? && expires_at < Time.current
end

# Actions
def accept!
  raise "Cannot accept: not pending" unless pending?
  update!(accepted_at: Time.current)
  # TODO: Send notification to granting_user
end

def decline!
  raise "Cannot decline: not pending" unless pending?
  update!(declined_at: Time.current)
  # TODO: Send notification to granting_user
end

def revoke!
  raise "Cannot revoke: already revoked or declined" if revoked? || declined?
  update!(revoked_at: Time.current)
  # TODO: Send notification to trusted_user
end

# Capabilities
def has_capability?(capability)
  permissions&.dig(capability) == true
end

# Studio scoping
def allows_studio?(collective)
  scope = studio_scope || { "mode" => "all" }
  case scope["mode"]
  when "all"
    true
  when "include"
    scope["studio_ids"]&.include?(collective.id)
  when "exclude"
    !scope["studio_ids"]&.include?(collective.id)
  else
    false
  end
end

# Scopes
scope :pending, -> { where(accepted_at: nil, declined_at: nil, revoked_at: nil) }
scope :active, -> {
  where.not(accepted_at: nil)
       .where(declined_at: nil, revoked_at: nil)
       .where("expires_at IS NULL OR expires_at > ?", Time.current)
}
```

### 1.3 Implement authorization check ✅

**File**: `app/models/user.rb`

Complete the TODO at line 140:

```ruby
def can_represent?(collective_or_user)
  if collective_or_user.is_a?(Collective)
    # ... existing collective logic ...
  elsif collective_or_user.is_a?(User)
    user = collective_or_user
    return can_impersonate?(user) if can_impersonate?(user)

    # Check for trustee grant trustee grants
    return false unless self.trustee?
    return false if self.collective_trustee?  # Collective trustees handled above

    permission = TrusteeGrant.find_by(trustee_user: self)
    return false unless permission&.active?

    # The trustee can represent if it's the trustee for the given user
    permission.granting_user_id == user.id
  else
    false
  end
end

# Add lookup methods
def granted_trustee_grants
  TrusteeGrant.where(granting_user: self)
end

def received_trustee_grants
  TrusteeGrant.where(trusted_user: self)
end

def pending_trustee_grant_requests
  received_trustee_grants.pending
end
```

### 1.4 Tests ✅

**File**: `test/models/trustee_grant_test.rb`

- Test state transitions (pending → active, pending → declined, active → revoked)
- Test capability checks
- Test studio scoping
- Test expiration logic
- Test authorization flow via `User#can_represent?`

---

## Phase 2: Controller & Routes ✅ COMPLETE

**Goal**: Create endpoints for managing trustee grants with acceptance workflow.

### 2.1 Routes ✅

**File**: `config/routes.rb`

```ruby
# User settings - manage permissions
scope '/settings' do
  resources :trustee_grants, only: [:index, :new, :create], path: 'trustee grants' do
    member do
      post :accept
      post :decline
      post :revoke
    end
  end
end
```

### 2.2 Controller ✅

**File**: `app/controllers/trustee_grants_controller.rb`

```ruby
class TrusteeGrantsController < ApplicationController
  before_action :require_user

  def index
    @granted = current_user.granted_trustee_grants.includes(:trusted_user, :trustee_user)
    @received = current_user.received_trustee_grants.includes(:granting_user, :trustee_user)
    @pending_requests = current_user.pending_trustee_grant_requests.includes(:granting_user)
  end

  def new
    @permission = TrusteeGrant.new
    @available_users = available_users_for_trustee grant
    @available_studios = current_user.collectives
  end

  def create
    @permission = TrusteeGrant.new(permission_params)
    @permission.granting_user = current_user

    if @permission.save
      # TODO: Send notification to trusted_user
      redirect_to trustee_grants_path, notice: "Trustee Grant request sent"
    else
      @available_users = available_users_for_trustee grant
      @available_studios = current_user.collectives
      render :new, status: :unprocessable_entity
    end
  end

  def accept
    permission = current_user.pending_trustee_grant_requests.find(params[:id])
    permission.accept!
    redirect_to trustee_grants_path, notice: "Trustee Grant accepted"
  end

  def decline
    permission = current_user.pending_trustee_grant_requests.find(params[:id])
    permission.decline!
    redirect_to trustee_grants_path, notice: "Trustee Grant declined"
  end

  def revoke
    permission = current_user.granted_trustee_grants.find(params[:id])
    permission.revoke!
    redirect_to trustee_grants_path, notice: "Trustee Grant revoked"
  end

  private

  def permission_params
    params.require(:trustee_grant).permit(
      :trusted_user_id,
      :relationship_phrase,
      :expires_at,
      :studio_scope,
      permissions: TrusteeGrant::CAPABILITIES.keys
    )
  end

  def available_users_for_trustee grant
    User.joins(:tenant_users)
        .where(tenant_users: { tenant_id: Tenant.current_id })
        .where.not(id: current_user.id)
        .where(user_type: %w[person subagent])
  end
end
```

### 2.3 Markdown UI support ✅

Add `respond_to` blocks for markdown format in all actions.

---

## Phase 3: User Interface ✅ COMPLETE

**Goal**: Build UI for granting and managing permissions.

### 3.1 Index view ✅

**File**: `app/views/trustee_grants/index.html.erb`

Sections:
1. **Pending requests** - Accept/decline buttons for incoming requests
2. **Active trustee grants I've received** - Who can act on my behalf
3. **Active trustee grants I've granted** - Who I can act for (with revoke)
4. **Grant new trustee grant** button

### 3.2 New permission form ✅

**File**: `app/views/trustee_grants/new.html.erb`

Form fields:
- Select user to trust (dropdown)
- Relationship description (optional)
- Capabilities (checkboxes grouped by category)
- Studio scope:
  - Radio: All studios / Specific studios
  - Multi-select for studio list
- Expiration (optional date picker)

### 3.3 Navigation integration ✅ COMPLETE

**Files**:
- `app/views/users/settings.html.erb` - Added Trustee Grants accordion section
- `app/views/users/settings.md.erb` - Added Trustee Grants section
- `app/views/layouts/_top_right_menu.html.erb` - Added pending badge on Settings link

Features:
- Link from user settings to trustee grants page
- Badge showing pending request count on Settings menu item
- Badge in settings accordion when pending requests exist

---

## Phase 4: Representation Session Integration ✅ COMPLETE

**Goal**: Enable trustee grant trustees to use representation sessions.

### Key Constraints
- **Single session**: A user can only have one active representation session at a time (studio OR trustee grant)
- **Multi-studio**: A trustee grant session can span multiple studios (actions logged per-studio)
- **Immediate capability changes**: Permission modifications apply immediately to active sessions

### 4.1 Extend representation session start ✅ COMPLETE

**Files**:
- `db/migrate/20260206214518_add_trustee_grant_to_representation_sessions.rb` - Added `trustee_grant_id` column
- `app/models/representation_session.rb` - Added `belongs_to :trustee_grant, optional: true` and helper methods
- `app/controllers/representation_sessions_controller.rb` - Added `start_representing_user` action
- `config/routes.rb` - Added route for `represent_user`

Features:
- `trustee_grant_id` column for linking session to grant
- `studio_representation?` and `user_representation?` helper methods
- `represented_user` and `representation_label` methods
- Single session constraint enforced in controller

### 4.2 Multi-studio session behavior ✅ COMPLETE

For trustee grant trustees, the session can span studios:
- User representation sessions have `collective_id = NULL` (not tied to any specific studio)
- Actions in any scoped studio are logged to the same session
- Each action's `semantic_event[:collective_id]` tracks which studio the action occurred in
- Session path links to the trustee grant show page (not a studio-specific URL)

### 4.3 Update representation UI ✅ COMPLETE

**Files**:
- `app/views/trustee_grants/index.html.erb` - "Represent" button in received grants table
- `app/views/trustee_grants/show.html.erb` - "Start Representing" section for active grants
- `app/controllers/trustee_grants_controller.rb` - `start_representing` action
- `config/routes.rb` - Route for `/u/:handle/settings/trustee-grants/:grant_id/represent`
- `app/views/representation_sessions/representing.html.erb` - Updated to display user representation

Features:
- User representation is initiated from the trustee grants settings page
- "Represent" button appears for received active grants where user is the trusted_user
- Creates RepresentationSession linked to the trustee grant
- Session cookies set for `trustee_user_id` and `representation_session_id`

### 4.4 Capability enforcement during session ✅ COMPLETE

**File**: `app/services/action_authorization.rb` (formerly `trustee_action_validator.rb`)

Permission is checked at action time (not cached), so changes take immediate effect. The capability enforcement logic has been consolidated into ActionAuthorization.

**Note**: If a granting user revokes a capability while a session is active, the next action requiring that capability will fail immediately.

### 4.5 Subagent capability configuration ✅ COMPLETE

**Files**:
- `app/services/capability_check.rb` - Added trustee grant actions to `SUBAGENT_GRANTABLE_ACTIONS`
- `app/views/subagents/new.html.erb` - Added capability groups for trustee grant actions
- `app/views/users/settings.html.erb` - Added capability groups in subagent edit form

Trustee grant actions are grantable (not always-allowed) with different defaults:
- **Trustee Grant Responses** (`accept_trustee_grant`, `decline_trustee_grant`) - Enabled by default
- **Trustee Grant Admin** (`create_trustee_grant`, `revoke_trustee_grant`) - Disabled by default

This allows parent users to control whether their subagents can accept/decline trustee grants or create/revoke them.

### 4.6 Integrate enforcement ✅ COMPLETE

**Files**: `app/services/api_helper.rb`, `app/services/action_authorization.rb`

Added capability enforcement:
- `require_capability!(action_name)` method that validates using ActionAuthorization
- `CapabilityError` exception class for capability violations
- Capability checks in `create_note`, `create_decision`, `vote`, `create_votes`

**Note**: Capability is checked at action time, so permission changes apply immediately to active sessions. TrusteeActionValidator logic has been consolidated into ActionAuthorization.

### 4.7 Session history on trustee grant show page ✅ COMPLETE

**Goal**: Allow granting users to see all representation sessions associated with a specific trustee grant.

**Files**:
- `app/models/trustee_grant.rb` - Added `has_many :representation_sessions, dependent: :restrict_with_error`
- `app/models/representation_session.rb` - Updated with custom default_scope, validation, and path logic
- `app/views/trustee_grants/show.html.erb` - Added "Session History" section
- `app/views/trustee_grants/show.md.erb` - Added "Session History" section
- `app/controllers/trustee_grants_controller.rb` - Load `@sessions` in `show` action
- `app/services/api_helper.rb` - Added `start_user_representation_session` method
- `db/migrate/20260207001008_allow_null_collective_id_for_user_representation_sessions.rb`

**Implementation**:
- User representation sessions have NULL collective_id (they can span multiple studios)
- Studio representation sessions require collective_id (they are studio-specific)
- Added validation `collective_presence_matches_session_type` enforcing mutual exclusivity
- Custom default_scope includes both studio sessions (for current collective) and user sessions (NULL collective_id)
- Association uses `dependent: :restrict_with_error` to prevent deleting grants with session history
- Extracted shared session creation logic to `ApiHelper.start_user_representation_session`
- "Session History" section visible to both granting and trusted users on the trustee grant detail page
- Table shows: session ID (linked), started time, duration, action count, status (Active/Ended)
- Empty state if no sessions yet

### 4.8 Markdown API actions and ActionsHelper integration ✅ COMPLETE

**Goal**: Provide full markdown API support for all trustee grant operations.

**Files**:
- `app/services/actions_helper.rb` - Added trustee grant action definitions and route mappings
- `app/controllers/trustee_grants_controller.rb` - Added `current_resource`, `action_available_for_grant?`, action endpoints
- `app/views/trustee_grants/show.md.erb` - Added action links for all available operations
- `config/routes.rb` - Added routes for `describe_start_representation` and `execute_start_representation`
- `test/services/actions_helper_test.rb` - Comprehensive tests for ActionsHelper (30 tests)
- `test/services/action_authorization_test.rb` - Authorization tests for trustee grant actions

**Action Definitions in ActionsHelper**:
- `create_trustee_grant` - Create a new trustee grant
- `accept_trustee_grant` - Accept a pending trustee grant request
- `decline_trustee_grant` - Decline a pending trustee grant request
- `revoke_trustee_grant` - Revoke an active trustee grant
- `start_representation` - Start a representation session for an active grant

**Route Mappings**:
- `/u/:handle/settings/trustee-grants` → `create_trustee_grant`
- `/u/:handle/settings/trustee-grants/new` → `create_trustee_grant`
- `/u/:handle/settings/trustee-grants/:grant_id` → `accept_trustee_grant`, `decline_trustee_grant`, `revoke_trustee_grant`, `start_representation`

**Controller Pattern**:
- `current_resource` returns `@grant` (follows ApplicationController pattern for resource methods)
- `action_available_for_grant?(action_name)` filters actions based on grant state and user role
- `actions_index_show` uses ActionsHelper as source of truth, then filters using `action_available_for_grant?`

**Action Availability Logic**:
| Action | Available When |
|--------|----------------|
| `accept_trustee_grant` | Grant is pending AND user is trusted_user |
| `decline_trustee_grant` | Grant is pending AND user is trusted_user |
| `revoke_trustee_grant` | User is granting_user AND grant is not revoked/declined |
| `start_representation` | Grant is active AND user is trusted_user AND user is current_user |

---

## Phase 5: Notifications ⬚ NOT STARTED

**Goal**: Notify users of trustee grant events and actions.

### 5.1 Notification triggers

| Event | Notify |
|-------|--------|
| Permission requested | trusted_user |
| Permission accepted | granting_user |
| Permission declined | granting_user |
| Permission revoked | trusted_user |
| Session started | granting_user |
| Session ended | granting_user (with summary) |

### 5.2 Implementation

Use existing notification system (`Notification` model, `NotificationRecipient`).

Create notification types:
- `trustee_grant_requested`
- `trustee_grant_accepted`
- `trustee_grant_declined`
- `trustee_grant_revoked`
- `trustee_session_started`
- `trustee_session_ended`

---

## Phase 6: Trio Integration ⬚ NOT STARTED

**Goal**: Enable Trio to request and use delegated permissions.

### 6.1 Trio permission request flow

When a user asks Trio to do something that requires trustee grant:

1. Trio checks if it has active permission from the user
2. If not, Trio can request permission (creates pending TrusteeGrant)
3. User accepts/declines
4. If accepted, Trio starts representation session and acts

### 6.2 Trio uses representation sessions

```ruby
# Trio starts a session when acting on behalf of a user
grant = TrusteeGrant.active.find_by!(
  granting_user: user,
  trustee_user: trio_user
)

session = RepresentationSession.create!(
  tenant: tenant,
  # collective: nil - user representation has no collective
  representative_user: trio_user,
  trustee_grant: grant,
  confirmed_understanding: true,
  began_at: Time.current,
)

# Take actions within session - each action recorded via record_event!
session.record_event!(
  request: request,
  action_name: "create_note",
  resource: note
)

session.end!
```

### 6.3 Trio-specific UI

Add to user settings:
- "Trio Access" section
- Quick toggle: "Allow Trio to act on my behalf"
- Capability presets (conservative, moderate, full)
- Studio scope selection

---

## Phase 7: Replace Impersonation with Representation 🔶 PARTIAL

**Goal**: Migrate from impersonation to representation sessions, ensuring all delegated actions are logged.

**Status**: 7.1-7.3, 7.5-7.6 complete. Only 7.4 (remove impersonation UI) remains.

### 7.1 Auto-create TrusteeGrant for subagents ✅ COMPLETE

When a subagent is created, automatically create a TrusteeGrant:

**File**: `app/models/user.rb`

```ruby
after_create :create_parent_trustee_grant!, if: :subagent?

private

def create_parent_trustee_grant!
  all_permissions = TrusteeGrant::GRANTABLE_ACTIONS.index_with { true }

  TrusteeGrant.create!(
    granting_user: self,              # The subagent grants permission
    trustee_user: parent_user,        # The parent is the trustee
    accepted_at: Time.current,        # Pre-accepted
    permissions: all_permissions,     # All actions allowed
    studio_scope: { "mode" => "all" } # All studios
  )
end
```

### 7.2 Migration for existing subagents ✅ COMPLETE

**File**: `db/migrate/20260207141046_create_trustee_grants_for_existing_subagents.rb`

```ruby
class CreateTrusteeGrantsForSubagents < ActiveRecord::Migration[7.0]
  def up
    User.where(user_type: 'subagent').where.not(parent_id: nil).find_each do |subagent|
      next if TrusteeGrant.exists?(granting_user: subagent, trustee_user_id: subagent.parent_id)

      all_permissions = TrusteeGrant::GRANTABLE_ACTIONS.index_with { true }
      TrusteeGrant.create!(
        granting_user: subagent,
        trustee_user: subagent.parent,
        accepted_at: Time.current,
        permissions: all_permissions,
        studio_scope: { "mode" => "all" }
      )
    end
  end

  def down
    User.where(user_type: 'subagent').find_each do |subagent|
      TrusteeGrant.where(granting_user: subagent).destroy_all
    end
  end
end
```

### 7.3 Update `can_represent?` to check TrusteeGrant ✅ COMPLETE

**File**: `app/models/user.rb`

The `can_represent?(user)` method checks TrusteeGrant:

```ruby
def can_represent?(collective_or_user)
  # ... collective handling ...

  if collective_or_user.is_a?(User)
    user = collective_or_user
    return false if user.archived?

    # Parent can represent their subagent
    return true if is_parent_of?(user)

    # The trustee_user (self) can represent the granting_user (user) if there's an active grant
    grant = TrusteeGrant.active.find_by(
      granting_user: user,
      trustee_user: self
    )
    return grant.present?
  end
end
```

Parent-subagent representation is allowed via `is_parent_of?` check, which then creates a TrusteeGrant session.

### 7.4 Remove impersonation UI ⬚ NOT STARTED

**Files to update**:
- Remove "Impersonate" buttons from user profiles
- Remove impersonation session management from `ApplicationController`
- Replace with "Represent" flow using representation sessions

### 7.5 Update session management ✅ COMPLETE

Session management updated to use representation sessions for parent-subagent flow:

**Files updated**:
- `app/controllers/application_controller.rb` - Handle representation session ending for impersonation path
- `app/controllers/representation_sessions_controller.rb` - Support user representation studios
- `app/controllers/users_controller.rb` - Use representation sessions when impersonating subagents

Impersonation now creates a representation session linked to the TrusteeGrant, ensuring all actions are logged.

### 7.6 Testing the migration ✅ COMPLETE

**Files updated**:
- `test/integration/impersonation_test.rb` - Updated to use representation sessions
- `test/integration/trustee_grant_flow_test.rb` - Tests for representation flow
- `test/models/user_test.rb` - Tests for `is_trusted_as?` method
- `test/models/trustee_grant_test.rb` - Tests for auto-created grants
- `test/controllers/trustee_grants_controller_test.rb` - Controller tests

---

## Phase 8: Simplify TrusteeGrant ✅ COMPLETE

**Goal**: Remove synthetic "trustee" users and simplify the data model for user representation.

### What Changed

1. **Column rename**: `trusted_user_id` → `trustee_user_id` (the actual person is now "the trustee")
2. **Removed synthetic users**: TrusteeGrants no longer create User records of type "trustee"
3. **`effective_user`**: For user representation, returns `trustee_grant.granting_user` directly
4. **Validation**: `trustee_user` cannot be a trustee-type user (only real persons can be trustees)

### Current Data Model

```
TrusteeGrant:
  granting_user  → User (person being represented)
  trustee_user   → User (person doing the representing - NOT type 'trustee')

RepresentationSession (user representation):
  representative_user  → trustee_grant.trustee_user
  effective_user       → trustee_grant.granting_user (via method)
  collective_id        → NULL
  trustee_grant_id     → the grant
```

### Files Updated

- `app/models/trustee_grant.rb` - Removed `create_trustee_user!` callback, renamed column
- `app/models/user.rb` - Updated `create_parent_trustee_grant!`, `can_represent?`
- `app/models/representation_session.rb` - `effective_user` returns `granting_user` for user representation

---

## Critical Files

| File | Purpose |
|------|---------|
| `app/models/trustee_grant.rb` | Core model with capabilities, states, scoping |
| `app/models/user.rb` | Authorization methods |
| `app/models/representation_session.rb` | Session model (works for both studio and user); custom default_scope for tenant/collective filtering |
| `app/controllers/trustee_grants_controller.rb` | CRUD + accept/decline/revoke + start_representing; `current_resource` and `action_available_for_grant?` |
| `app/controllers/representation_sessions_controller.rb` | Extended for trustee grant trustees |
| `app/services/api_helper.rb` | `start_user_representation_session` for shared session creation logic |
| `app/services/actions_helper.rb` | Single source of truth for action definitions and route mappings |
| `app/services/action_authorization.rb` | Authorization checks for actions (includes capability enforcement, formerly in TrusteeActionValidator) |
| `app/services/capability_check.rb` | Subagent capability authorization |
| `app/services/markdown_ui_service.rb` | Action execution with enforcement |
| `app/views/trustee_grants/` | UI templates (HTML and markdown) |
| `app/views/subagents/new.html.erb` | Subagent creation with capability config |
| `test/services/actions_helper_test.rb` | ActionsHelper tests (30 tests) |
| `test/services/action_authorization_test.rb` | Authorization tests including trustee grant actions |
| `app/models/representation_session_event.rb` | Event records for tracking actions during sessions |
| `app/models/concerns/has_representation_session_events.rb` | Concern for models that can be created during representation |
| `db/migrate/20260207001008_allow_null_collective_id_for_user_representation_sessions.rb` | Allow NULL collective_id for user sessions |
| `db/migrate/20260207141046_create_trustee_grants_for_existing_subagents.rb` | Create TrusteeGrants for existing subagents |
| `db/migrate/20260208191548_create_representation_session_events.rb` | Create events table |

---

## Testing Strategy

### Unit Tests
- `TrusteeGrant` state transitions
- `TrusteeGrant` capability and studio scope checks
- `User#can_represent?` for trustee grant trustees
- `User#is_trusted_as?` for representation checks
- `ActionAuthorization` capability enforcement
- Auto-creation of TrusteeGrant when subagent is created

### Integration Tests
- Full flow: request → accept → start session → act → end session
- Declined permission prevents session start
- Revoked permission ends active session
- Studio scope enforcement
- Expiration behavior
- Capability enforcement during actions
- Parent representing subagent via auto-created permission
- Migration of existing subagents to TrusteeGrant

### Manual Tests
- Request trustee grant via UI
- Accept/decline as trusted user
- Start representation session with trustee grant trustee
- Take permitted actions, verify logging
- Attempt unpermitted action, verify denial
- Verify notifications at each step
- Create subagent, verify parent can represent via session
- Verify no impersonation UI remains after migration

---

## Migration Path

1. **Phase 1** ✅ - Add columns, deploy migration. No user-facing changes.
2. **Phase 2** ✅ - Controller endpoints.
3. **Phase 3** ✅ - UI.
4. **Phase 4** ✅ - Representation session integration with RepresentationSessionEvent.
5. **Phase 5** ⬚ - Notifications. Polish.
6. **Phase 6** ⬚ - Trio integration. Requires phases 1-5.
7. **Phase 7** 🔶 - Replace impersonation. 7.4 remaining.
8. **Phase 8** ✅ - Simplify TrusteeGrant. Remove synthetic users.

---

## Resolved Questions

| Question | Decision |
|----------|----------|
| Activity logging | Yes - use `RepresentationSessionEvent` to record all actions during representation |
| Notifications | Yes - notify at key events (request, accept, decline, revoke, session start/end) |
| Acceptance workflow | Yes - trustee_user must accept before grant is active |
| Studio scoping | Yes - implement now with include/exclude modes |
| Session duration | Same 24h limit as studio sessions |
| Multiple studios | A user representation session can span multiple studios (actions in any scoped studio) |
| Concurrent sessions | No - a user can only represent a single entity (user or studio) at a time |
| Nested sessions | Not allowed - if A represents B, A cannot start a session to represent C via B's grants; UI hides options and backend blocks with explicit error |
| Capability changes | Immediate effect - permission changes apply to active sessions |
| Replace impersonation | Yes - all impersonation replaced with representation sessions |
| Parent-subagent representation | Auto-create TrusteeGrant when subagent is created; granting_user=subagent, trustee_user=parent; pre-accepted with full capabilities |
| Synthetic trustee users | **Removed** - TrusteeGrant.trustee_user is now the actual person (not a synthetic user of type 'trustee') |
| Subagent trustee grant actions | Grantable (not always-allowed); Responses enabled by default, Admin actions disabled by default |
| User representation entry point | Trustee grants settings page (`/u/:handle/settings/trustee-grants`) - not studio representation page |
| Session history visibility | On trustee grant show page - granting user can see all sessions and actions taken on their behalf via that grant |
| User representation sessions | Have NULL collective_id (can span studios); studio representation sessions require collective_id; mutually exclusive via validation |
| Grant deletion | Blocked if sessions exist (`dependent: :restrict_with_error`) - preserves audit history |
| Action definitions | ActionsHelper is single source of truth; controllers filter using state-based helpers (e.g., `action_available_for_grant?`) |
| Controller resource pattern | Use `current_resource` (not `current_resource_model`) to return instance; `current_resource_model` returns the class |
