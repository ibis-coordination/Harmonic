# Representation System

This document describes how users can act on behalf of studios or other users through representation sessions.

## Overview

Representation enables two distinct use cases:

1. **Studio Representation (Collective Agency)**: A designated representative acts as the studio itself, with actions attributed to the studio's proxy user. Used when a studio needs to participate in other studios.

2. **User Representation (Delegation)**: A trusted user acts on behalf of another user via a TrusteeGrant. Used when one person (e.g., a parent) needs to act for another (e.g., their subagent).

Both types use the same `RepresentationSession` model but with different configurations.

## Types of Representation

### Studio Representation

When a user represents a studio:
- They act through the studio's proxy user (`superagent.proxy_user`)
- Actions are attributed to the studio
- The session has a `superagent_id` but no `trustee_grant_id`
- Used for collective agency (studio acting in other studios)

### User Representation

When a user represents another user:
- They act as the granting user (the person who granted permission)
- Actions are attributed to the granting user
- The session has a `trustee_grant_id` but no `superagent_id`
- Requires an active TrusteeGrant

```
┌─────────────────────────────────────────────────────────────────┐
│                    RepresentationSession                         │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  Studio Representation          User Representation              │
│  ─────────────────────          ───────────────────              │
│  superagent_id: present         superagent_id: nil               │
│  trustee_grant_id: nil          trustee_grant_id: present        │
│                                                                  │
│  effective_user:                effective_user:                  │
│    superagent.proxy_user          trustee_grant.granting_user    │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

## Key Concepts

### Who Can Represent a Studio?

A user can represent a studio if any of these conditions are met:

1. **Representative Role**: User has the `representative` role in the studio
2. **Any Member Setting**: Studio has `any_member_can_represent?` enabled
3. **Is Proxy**: User is the studio's proxy user itself

Checked via `SuperagentMember#can_represent?`:
```ruby
def can_represent?
  archived_at.nil? && (has_role?('representative') || superagent.any_member_can_represent?)
end
```

### Who Can Represent a User?

A user can represent another user if:

1. **Parent of Subagent**: The trustee is the parent of a subagent (auto-granted on subagent creation)
2. **Active TrusteeGrant**: An active TrusteeGrant exists where the current user is the `trustee_user`

Checked via `User#can_represent?(user)`:
```ruby
# Parent can represent their subagent
return true if is_parent_of?(user)

# Check for active trustee grant
grant = TrusteeGrant.active.find_by(granting_user: user, trustee_user: self)
return grant.present?
```

## Representation Session Lifecycle

```
                    ┌─────────────┐
                    │   CREATED   │
                    │ (not begun) │
                    └──────┬──────┘
                           │
                           │ begin!
                           ▼
                    ┌─────────────┐
              ┌─────│   ACTIVE    │─────┐
              │     │             │     │
              │     └─────────────┘     │
              │                         │
              │ end!                    │ 24 hours elapsed
              ▼                         ▼
       ┌─────────────┐           ┌─────────────┐
       │    ENDED    │           │   EXPIRED   │
       │             │           │             │
       └─────────────┘           └─────────────┘
```

### States

| State | `active?` | `expired?` | Description |
|-------|-----------|------------|-------------|
| Created | false | false | Session exists but hasn't begun |
| Active | true | false | User is actively representing |
| Ended | false | true | User explicitly stopped representing |
| Expired | false | true | 24 hours elapsed without ending |

### Starting a Studio Representation Session

**Route:** `POST /studios/:studio_handle/represent`

**Requirements:**
- User must have `can_represent?` permission on the studio
- User must not have an active session already
- User must confirm understanding (checkbox)

**What happens:**
1. Creates `RepresentationSession` record with `superagent_id`
2. Calls `begin!` to set `began_at`
3. Sets session cookies: `representation_session_id`, `representing_studio`
4. Redirects to `/representing` dashboard

### Starting a User Representation Session

**Route:** `POST /u/:handle/settings/trustee-grants/:grant_id/represent`

**Requirements:**
- TrusteeGrant must be active (accepted, not expired, not revoked)
- Current user must be the grant's `trustee_user`
- User must not have an active session already

**What happens:**
1. Creates `RepresentationSession` record with `trustee_grant_id` (no `superagent_id`)
2. Sets session cookies: `representation_session_id`, `representing_user`
3. Redirects to `/representing` dashboard

### During Representation

While a session is active:

- `current_user` returns the effective user (proxy user or granting user)
- Actions are attributed to the effective user
- Every action creates a `RepresentationSessionEvent` record
- Session is scoped to appropriate paths (`/representing`, `/studios/`, or `/scenes/`)

### Recording Activity

Actions during representation are automatically recorded via `RepresentationSession#record_event!`:

```ruby
current_representation_session.record_event!(
  request: request,
  action_name: "create_note",
  resource: note,
  context_resource: nil  # optional parent resource
)
```

Events are stored in the `representation_session_events` table as individual records, grouped by `request_id` for bulk operations.

**Supported Action Names:**
| Action Name | Description |
|-------------|-------------|
| `create_note` | New note created |
| `update_note` | Note modified |
| `add_comment` | Comment added to a resource |
| `confirm_read` | User confirmed reading a note |
| `create_decision` | New decision created |
| `update_decision_settings` | Decision settings modified |
| `vote` | Voted on decision |
| `add_options` | Options added to decision |
| `create_commitment` | New commitment created |
| `update_commitment_settings` | Commitment settings modified |
| `join_commitment` | Joined commitment |
| `pin_*` / `unpin_*` | Pinned/unpinned resource |
| `send_heartbeat` | Heartbeat sent |

**Supported Resource Types:**
- Primary: `Note`, `Decision`, `Commitment`, `Heartbeat`
- Secondary: `NoteHistoryEvent`, `Option`, `Vote`, `CommitmentParticipant`

### Stopping a Session

**Routes:**
- Studio: `DELETE /studios/:studio_handle/represent`
- User: `DELETE /representing`

**What happens:**
1. Calls `end!` to set `ended_at`
2. Clears session cookies
3. Redirects with link to session record

## API Representation

Representation is also supported via API tokens using headers:

### Headers

| Header | Description |
|--------|-------------|
| `X-Representation-Session-ID` | Session ID (full UUID or 8-char truncated) |
| `X-Representing-Studio` | Studio handle (required for studio representation) |
| `X-Representing-User` | User handle (required for user representation) |

### Flow

1. Start a representation session (via API or browser)
2. Include `X-Representation-Session-ID` header in subsequent requests
3. Include matching `X-Representing-*` header for security validation
4. Actions are recorded to the session

### Active Session Conflict

If an active representation session exists but the header is not provided:
- Returns `409 Conflict` with the active session ID
- Forces explicit intent to act as representative

## TrusteeGrant System

TrusteeGrants enable user-to-user delegation with granular permissions.

### Workflow

1. **Granting User** creates a TrusteeGrant (pending state)
2. **Trustee User** accepts the grant (active state)
3. **Trustee User** starts a representation session
4. Actions are recorded and attributed to the granting user
5. Session ends, activity is viewable

### Grant Permissions

Grants can specify which actions are allowed:

```ruby
TrusteeGrant::GRANTABLE_ACTIONS = [
  "create_note", "update_note", "create_decision", "vote",
  "create_commitment", "join_commitment", "add_comment",
  "pin_note", "unpin_note", # ... etc
]
```

### Studio Scoping

Grants can restrict which studios the trustee can act in:

| Mode | Description |
|------|-------------|
| `all` | All studios (default) |
| `include` | Only listed studios |
| `exclude` | All except listed studios |

### Parent-Subagent Grants

When a subagent is created, an auto-accepted TrusteeGrant is created:
- Granting user: the subagent
- Trustee user: the parent
- Permissions: all actions
- Studio scope: all studios

## Viewing Representation Sessions

### Studio Session Record

Each studio representation session has a permanent record at:
```
/studios/{studio_handle}/r/{truncated_id}
```

### User Session Record

User representation sessions are viewed via the trustee grant:
```
/u/{granting_user_handle}/settings/trustee-grants/{grant_truncated_id}
```

### Activity Log Format

The `human_readable_events_log` method groups events by request_id:

| Time | Action | Resource | Studio | Count |
|------|--------|----------|--------|-------|
| 2:30 PM | created | Test Note | Engineering | 1 |
| 2:35 PM | voted on | Q4 Budget | Engineering | 3 |

### Representatives View

Studios can view their representatives at:
```
/studios/{studio_handle}/representation
```

This shows:
- Users with `representative` role
- Whether `any_member_can_represent` is enabled
- Active representation sessions
- History of past sessions

## Edge Cases

### Session Expiration

Sessions automatically expire after 24 hours even if not explicitly ended. Expired sessions:
- Cannot record new activity
- Show as expired in the UI
- Still have their activity log preserved

### Role Revoked During Session

If a user's `representative` role is removed while they have an active session:
- Next request detects `can_represent?` returns false
- Session is ended gracefully
- User is returned to their person identity

### Grant Revoked During Session

If a TrusteeGrant is revoked while a session is active:
- Next request detects `grant.active?` returns false
- Session cookies are cleared
- User is returned to their own identity

### Permission Changes During Session

Permission changes on a TrusteeGrant take immediate effect:
- If an action permission is removed, the next attempt fails
- If studio scope is changed, access is updated immediately

### Accessing Pages Outside Scope

During representation, users are confined to appropriate paths. Attempting to access other areas:
- Redirects to `/representing` dashboard

### Studio Scope Enforcement

For user representation, access to a studio requires both:
1. The grant's `studio_scope` must allow the studio
2. The granting user must be a member of the studio

## Database Schema

### RepresentationSession

| Column | Type | Description |
|--------|------|-------------|
| `id` | uuid | Primary key |
| `truncated_id` | string | 8-char ID for URLs |
| `tenant_id` | uuid | FK to tenant |
| `superagent_id` | uuid | FK to studio (null for user representation) |
| `trustee_grant_id` | uuid | FK to grant (null for studio representation) |
| `representative_user_id` | uuid | The person doing the representing |
| `began_at` | timestamp | When session started |
| `ended_at` | timestamp | When session ended (null if active) |
| `confirmed_understanding` | boolean | User confirmed checkbox |

**Validation:** Exactly one of `superagent_id` or `trustee_grant_id` must be present (XOR).

### RepresentationSessionEvent

Tracks individual actions during a session:

| Column | Type | Description |
|--------|------|-------------|
| `id` | uuid | Primary key |
| `tenant_id` | uuid | FK to tenant |
| `superagent_id` | uuid | Session's superagent (may be null) |
| `representation_session_id` | uuid | FK to session |
| `action_name` | string | Action performed (e.g., "create_note") |
| `resource_type` | string | Polymorphic resource type |
| `resource_id` | uuid | Polymorphic resource ID |
| `context_resource_type` | string | Optional parent resource type |
| `context_resource_id` | uuid | Optional parent resource ID |
| `resource_superagent_id` | uuid | Studio where resource exists |
| `request_id` | string | Groups events from same request |
| `created_at` | timestamp | When event occurred |

### TrusteeGrant

| Column | Type | Description |
|--------|------|-------------|
| `id` | uuid | Primary key |
| `truncated_id` | string | 8-char ID for URLs |
| `tenant_id` | uuid | FK to tenant |
| `granting_user_id` | uuid | User granting permission |
| `trustee_user_id` | uuid | User receiving permission |
| `permissions` | jsonb | Hash of action_name => boolean |
| `studio_scope` | jsonb | Studio access configuration |
| `accepted_at` | timestamp | When grant was accepted |
| `declined_at` | timestamp | When grant was declined |
| `revoked_at` | timestamp | When grant was revoked |
| `expires_at` | timestamp | Optional expiration |

## Related Documentation

- [USER_TYPES.md](USER_TYPES.md) - User types including superagent proxy users
- [PHILOSOPHY.md](../PHILOSOPHY.md) - Collective agency concepts
