# Trustee Grants Implementation Plan

## Goal

Complete the trustee grants system to allow users to delegate specific capabilities to other users (including AI agents like Trio). This enables:

1. **User-to-user trustee grant** - Alice can grant Bob permission to act on her behalf
2. **User-to-agent trustee grant** - A user can grant Trio permission to create notes, vote, etc. on their behalf
3. **Transparency** - All delegated actions are attributed to a trustee user and logged in representation sessions

## Current State

### What Exists
- `TrusteeGrant` model with core fields:
  - `granting_user` → the person delegating authority
  - `trusted_user` → the person/agent receiving authority
  - `trustee_user` → user of type `trustee` representing the relationship (auto-created)
  - `permissions` JSONB → intended for granular grants (currently empty)
  - `expires_at` → time-limited grants
  - `relationship_phrase` → e.g., "{trusted_user} acts for {granting_user}"
- `RepresentationSession` model - currently used for studio representation
- `grant_permissions!` and `revoke_permissions!` methods
- Test helper `create_trustee_grant`

### What's Missing
1. **Permission schema** - No defined structure for what can be granted
2. **Studio scoping** - Permissions need to be limited to specific studios
3. **Acceptance workflow** - Trusted user must accept the grant
4. **Authorization checks** - TODO at `User#can_represent?:140` for trustee grant trustees
5. **Controllers/routes** - No CRUD endpoints for TrusteeGrant
6. **UI** - No way for users to grant/manage permissions
7. **Notifications** - No alerts when trustee takes actions
8. **Enforcement** - No middleware to check permissions at action time

## Design Decisions

### Unified Representation Model

**Key insight**: Use `RepresentationSession` for BOTH studio representation AND user representation.

The existing `RepresentationSession` model already supports this:
- `trustee_user` - can be either a studio's trustee OR a trustee grant trustee
- `representative_user` - the person doing the acting
- `superagent` - the studio context (for user representation, this is the studio where actions occur)

**Flow comparison:**

| Step | Studio Representation | User Representation |
|------|----------------------|---------------------|
| Authorization | Studio role grants `can_represent?` | `TrusteeGrant` grants access |
| Session start | `POST /studios/:handle/represent` | Same, but using trustee grant trustee |
| During session | Actions logged, attributed to studio trustee | Actions logged, attributed to trustee grant trustee |
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
│                           TRUSTEE PERMISSION                                  │
│  (Standing authorization - can exist without active session)                  │
│                                                                               │
│  granting_user ─────────────────────────────────────> trusted_user            │
│       │              "allows to act on my behalf"          │                  │
│       │                                                    │                  │
│       │  States: pending → active (accepted)               │                  │
│       │          pending → declined                        │                  │
│       │          active  → revoked                         │                  │
│       │          active  → expired                         │                  │
│       │                                                    │                  │
│       └──────────────┬─────────────────────────────────────┘                  │
│                      │                                                        │
│                      ▼                                                        │
│              ┌──────────────┐                                                 │
│              │ trustee_user │  (user of type 'trustee' for attribution)       │
│              │ "Alice via   │                                                 │
│              │  Bob"        │                                                 │
│              └──────────────┘                                                 │
└─────────────────────────────────────────────────────────────────────────────┘
                                       │
                                       │ when trusted_user wants to act
                                       ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                         REPRESENTATION SESSION                               │
│  (Active session - created when user starts representing)                    │
│                                                                              │
│  ┌───────────────────┐         ┌───────────────────┐                         │
│  │ representative_   │ acts as │ trustee_user      │                         │
│  │ user              │────────>│ (from permission) │                         │
│  │ (the trusted_user)│         │                   │                         │
│  └───────────────────┘         └───────────────────┘                         │
│                                        │                                     │
│  Within studio context:                │                                     │
│  ┌───────────────────┐                 │                                     │
│  │ superagent        │<────────────────┘                                     │
│  │ (where actions    │   actions recorded in activity_log                    │
│  │  happen)          │                                                       │
│  └───────────────────┘                                                       │
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

Trustee user:                       Trustee user:
  superagent.trustee_user             permission.trustee_user
  (represents the studio)             (represents the trustee grant)

Session creation:                   Session creation:
  Same RepresentationSession          Same RepresentationSession
  model for both                      model for both

Activity logging:                   Activity logging:
  Same - all actions logged           Same - all actions logged
  in activity_log JSONB               in activity_log JSONB

Attribution:                        Attribution:
  Actions by "Studio Name"            Actions by "Bob via Alice"
```

---

## Phase 1: Schema & Model Updates

**Goal**: Extend TrusteeGrant with acceptance workflow, studio scoping, and capability definitions.

### 1.1 Database migration

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

### 1.2 Add capability constants and state methods

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
def allows_studio?(superagent)
  scope = studio_scope || { "mode" => "all" }
  case scope["mode"]
  when "all"
    true
  when "include"
    scope["studio_ids"]&.include?(superagent.id)
  when "exclude"
    !scope["studio_ids"]&.include?(superagent.id)
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

### 1.3 Implement authorization check

**File**: `app/models/user.rb`

Complete the TODO at line 140:

```ruby
def can_represent?(superagent_or_user)
  if superagent_or_user.is_a?(Superagent)
    # ... existing superagent logic ...
  elsif superagent_or_user.is_a?(User)
    user = superagent_or_user
    return can_impersonate?(user) if can_impersonate?(user)

    # Check for trustee grant trustee grants
    return false unless self.trustee?
    return false if self.superagent_trustee?  # Superagent trustees handled above

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

### 1.4 Tests

**File**: `test/models/trustee_grant_test.rb`

- Test state transitions (pending → active, pending → declined, active → revoked)
- Test capability checks
- Test studio scoping
- Test expiration logic
- Test authorization flow via `User#can_represent?`

---

## Phase 2: Controller & Routes

**Goal**: Create endpoints for managing trustee grants with acceptance workflow.

### 2.1 Routes

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

### 2.2 Controller

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
    @available_studios = current_user.superagents
  end

  def create
    @permission = TrusteeGrant.new(permission_params)
    @permission.granting_user = current_user

    if @permission.save
      # TODO: Send notification to trusted_user
      redirect_to trustee_grants_path, notice: "Trustee Grant request sent"
    else
      @available_users = available_users_for_trustee grant
      @available_studios = current_user.superagents
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

### 2.3 Markdown UI support

Add `respond_to` blocks for markdown format in all actions.

---

## Phase 3: User Interface

**Goal**: Build UI for granting and managing permissions.

### 3.1 Index view

**File**: `app/views/trustee_grants/index.html.erb`

Sections:
1. **Pending requests** - Accept/decline buttons for incoming requests
2. **Active trustee grants I've received** - Who can act on my behalf
3. **Active trustee grants I've granted** - Who I can act for (with revoke)
4. **Grant new trustee grant** button

### 3.2 New permission form

**File**: `app/views/trustee_grants/new.html.erb`

Form fields:
- Select user to trust (dropdown)
- Relationship description (optional)
- Capabilities (checkboxes grouped by category)
- Studio scope:
  - Radio: All studios / Specific studios
  - Multi-select for studio list
- Expiration (optional date picker)

### 3.3 Navigation integration

- Link from user profile/settings to trustee grants page
- Badge on nav when pending requests exist

---

## Phase 4: Representation Session Integration

**Goal**: Enable trustee grant trustees to use representation sessions.

### Key Constraints
- **Single session**: A user can only have one active representation session at a time (studio OR trustee grant)
- **Multi-studio**: A trustee grant session can span multiple studios (actions logged per-studio)
- **Immediate capability changes**: Permission modifications apply immediately to active sessions

### 4.1 Extend representation session start

**File**: `app/controllers/representation_sessions_controller.rb`

Modify `create` to handle trustee grant trustees:

```ruby
def create
  # Enforce single session constraint
  existing = RepresentationSession.active.find_by(representative_user: current_user)
  if existing
    raise "Already representing #{existing.trustee_user.display_name}. End that session first."
  end

  if using_trustee grant_trustee?
    permission = find_active_permission
    raise "No active permission" unless permission
    raise "Studio not in scope" unless permission.allows_studio?(@current_superagent)

    @trustee = permission.trustee_user
  else
    @trustee = @current_superagent.trustee_user
  end

  @session = RepresentationSession.create!(
    tenant: @current_tenant,
    superagent: @current_superagent,  # Initial studio context
    representative_user: current_user,
    trustee_user: @trustee,
    confirmed_understanding: true,
    began_at: Time.current,
    activity_log: { 'activity' => [] }
  )

  # Set session cookies...
end
```

### 4.2 Multi-studio session behavior

For trustee grant trustees, the session can span studios:
- Session is created in one studio context
- Actions in other scoped studios are still logged to the same session
- `superagent_id` on the session is the "home" studio, but `semantic_event[:superagent_id]` tracks where each action occurred

### 4.3 Update representation UI

Show both:
- "Represent this studio" (existing)
- "Act on behalf of [User]" for each active trustee grant

Disable options when already in a session (show "Currently representing X")

### 4.4 Capability enforcement during session

**File**: `app/services/trustee_action_validator.rb`

Permission is checked at action time (not cached), so changes take immediate effect:

```ruby
class TrusteeActionValidator
  CAPABILITY_MAP = {
    "create_note" => "create_notes",
    "create_decision" => "create_decisions",
    "create_commitment" => "create_commitments",
    "vote" => "vote",
    "commit" => "commit",
    "create_comment" => "comment",
    "pin" => "pin",
    "unpin" => "pin",
  }.freeze

  def initialize(user, superagent:)
    @user = user
    @superagent = superagent
  end

  def can_perform?(action_name)
    return true unless @user.trustee?
    return true if @user.superagent_trustee?  # Studio trustees have full access

    permission = TrusteeGrant.find_by(trustee_user: @user)
    return false unless permission&.active?
    return false unless permission.allows_studio?(@superagent)

    required_capability = CAPABILITY_MAP[action_name]
    return true unless required_capability  # Read/navigate always allowed

    permission.has_capability?(required_capability)
  end
end
```

**Note**: If a granting user revokes a capability while a session is active, the next action requiring that capability will fail immediately.

### 4.5 Integrate enforcement

**Files**: `app/services/markdown_ui_service.rb`, `app/services/api_helper.rb`

Check permissions before executing actions.

---

## Phase 5: Notifications

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

## Phase 6: Trio Integration

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
permission = TrusteeGrant.active.find_by!(
  granting_user: user,
  trusted_user: trio_user
)

session = RepresentationSession.create!(
  tenant: tenant,
  superagent: current_studio,
  representative_user: trio_user,
  trustee_user: permission.trustee_user,
  confirmed_understanding: true,
  began_at: Time.current,
  activity_log: { 'activity' => [] }
)

# Take actions within session
# All actions logged automatically

session.end!
```

### 6.3 Trio-specific UI

Add to user settings:
- "Trio Access" section
- Quick toggle: "Allow Trio to act on my behalf"
- Capability presets (conservative, moderate, full)
- Studio scope selection

---

## Phase 7: Replace Impersonation with Representation

**Goal**: Migrate from impersonation to representation sessions, ensuring all delegated actions are logged.

### 7.1 Auto-create TrusteeGrant for subagents

When a subagent is created, automatically create a TrusteeGrant:

**File**: `app/models/user.rb`

```ruby
after_create :create_parent_trustee_grant!, if: :subagent?

private

def create_parent_trustee_grant!
  TrusteeGrant.create!(
    tenant: tenant,
    granting_user: self,              # The subagent grants permission
    trusted_user: parent,             # The parent receives permission
    accepted_at: Time.current,        # Pre-accepted
    permissions: TrusteeGrant::CAPABILITIES.keys.index_with { true },  # All capabilities
    studio_scope: { "mode" => "all" },  # All studios
    relationship_phrase: "#{parent.display_name} acts for #{display_name}",
  )
  # Note: trustee_user is auto-created by TrusteeGrant#create_trustee_user! callback
end
```

### 7.2 Migration for existing subagents

**File**: `db/migrate/YYYYMMDD_create_trustee_grants_for_subagents.rb`

```ruby
class CreateTrusteeGrantsForSubagents < ActiveRecord::Migration[7.0]
  def up
    User.where(user_type: 'subagent').where.not(parent_id: nil).find_each do |subagent|
      next if TrusteeGrant.exists?(granting_user: subagent, trusted_user: subagent.parent)

      TrusteeGrant.create!(
        tenant: subagent.tenant,
        granting_user: subagent,
        trusted_user: subagent.parent,
        accepted_at: Time.current,
        permissions: TrusteeGrant::CAPABILITIES.keys.index_with { true },
        studio_scope: { "mode" => "all" },
        relationship_phrase: "#{subagent.parent.display_name} acts for #{subagent.display_name}",
      )
    end
  end

  def down
    # TrusteeGrants for subagents are identified by granting_user being a subagent
    User.where(user_type: 'subagent').find_each do |subagent|
      TrusteeGrant.where(granting_user: subagent).destroy_all
    end
  end
end
```

### 7.3 Update `can_impersonate?` to use representation

**File**: `app/models/user.rb`

Deprecate `can_impersonate?` and redirect to representation:

```ruby
# DEPRECATED: Use can_represent? and representation sessions instead
def can_impersonate?(user)
  Rails.logger.warn("DEPRECATION: can_impersonate? is deprecated. Use can_represent? instead.")
  can_represent?(user)
end

def can_represent?(superagent_or_user)
  if superagent_or_user.is_a?(Superagent)
    # ... existing superagent logic ...
  elsif superagent_or_user.is_a?(User)
    user = superagent_or_user

    # Check for active TrusteeGrant where:
    # - granting_user is the user being represented
    # - trusted_user is self (the person wanting to represent)
    permission = TrusteeGrant.active.find_by(
      granting_user: user,
      trusted_user: self
    )
    permission.present?
  else
    false
  end
end
```

### 7.4 Remove impersonation UI

**Files to update**:
- Remove "Impersonate" buttons from user profiles
- Remove impersonation session management from `ApplicationController`
- Replace with "Represent" flow using representation sessions

### 7.5 Update session management

Current impersonation uses session cookies directly. Replace with representation session flow:

**Before (impersonation)**:
```ruby
session[:impersonating_user_id] = subagent.id
# Actions attributed to subagent, no logging
```

**After (representation)**:
```ruby
permission = TrusteeGrant.active.find_by!(granting_user: subagent, trusted_user: current_user)
representation_session = RepresentationSession.create!(
  tenant: current_tenant,
  superagent: current_superagent,
  representative_user: current_user,  # The parent
  trustee_user: permission.trustee_user,  # The trustee grant trustee
  confirmed_understanding: true,
  began_at: Time.current,
  activity_log: { 'activity' => [] }
)
# All actions logged in activity_log
```

### 7.6 Testing the migration

1. Create subagent via API
2. Verify TrusteeGrant auto-created
3. Parent starts representation session
4. Actions logged to session
5. Session ends, activity visible
6. Verify old impersonation code paths are removed

---

## Critical Files

| File | Purpose |
|------|---------|
| `app/models/trustee_grant.rb` | Core model with capabilities, states, scoping |
| `app/models/user.rb` | Authorization methods |
| `app/models/representation_session.rb` | Session model (works for both studio and user) |
| `app/controllers/trustee_grants_controller.rb` | CRUD + accept/decline/revoke |
| `app/controllers/representation_sessions_controller.rb` | Extended for trustee grant trustees |
| `app/services/trustee_action_validator.rb` | Permission enforcement |
| `app/services/markdown_ui_service.rb` | Action execution with enforcement |
| `app/views/trustee_grants/` | UI templates |

---

## Testing Strategy

### Unit Tests
- `TrusteeGrant` state transitions
- `TrusteeGrant` capability and studio scope checks
- `User#can_represent?` for trustee grant trustees
- `TrusteeActionValidator` permission checks
- Auto-creation of TrusteeGrant when subagent is created
- `can_impersonate?` deprecation warning

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

1. **Phase 1** - Add columns, deploy migration. No user-facing changes.
2. **Phase 2** - Controller endpoints. Feature flagged.
3. **Phase 3** - UI. Feature flagged, opt-in.
4. **Phase 4** - Representation session integration. Users can start using.
5. **Phase 5** - Notifications. Polish.
6. **Phase 6** - Trio integration. Requires phases 1-5.
7. **Phase 7** - Replace impersonation. Auto-create permissions for subagents, deprecate `can_impersonate?`.

---

## Resolved Questions

| Question | Decision |
|----------|----------|
| Activity logging | Yes - use representation sessions for all trustee actions |
| Notifications | Yes - notify at key events (request, accept, decline, revoke, session start/end) |
| Acceptance workflow | Yes - trusted user must accept before permission is active |
| Studio scoping | Yes - implement now with include/exclude modes |
| Session duration | Same 24h limit as studio sessions |
| Multiple studios | A trustee grant trustee session can span multiple studios (actions in any scoped studio) |
| Concurrent sessions | No - a user can only represent a single entity (user or studio) at a time |
| Capability changes | Immediate effect - permission changes apply to active sessions |
| Replace impersonation | Yes - all impersonation replaced with representation sessions |
| Parent-subagent representation | Auto-create TrusteeGrant when subagent is created; granting_user=subagent, trusted_user=parent; pre-accepted with full capabilities |
| User type mixing | Never - user types (person, subagent, trustee) are mutually exclusive; each trustee grant creates a new trustee user |
