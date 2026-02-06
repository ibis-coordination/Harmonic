# Representation System

This document describes how users can act on behalf of studios through representation sessions.

## Overview

Representation enables **collective agency**—the ability for a studio to act as a unified entity through designated representatives. When a user represents a studio:

1. They impersonate the studio's trustee user
2. Their actions are attributed to the studio
3. All activity is recorded in a representation session
4. Other studio members can see what actions were taken on the studio's behalf

## Key Concepts

### Impersonation vs Representation

These terms are related but distinct:

- **Impersonation** (`can_impersonate?`): The mechanical ability to act *as* another user
- **Representation** (`can_represent?`): The permission to act *on behalf of* a studio

**Flow:**
```
can_represent?(studio)
    → grants ability to
can_impersonate?(studio.trustee_user)
    → creates
RepresentationSession
```

### Who Can Represent?

A user can represent a studio if any of these conditions are met:

1. **Representative Role**: User has the `representative` role in the studio
2. **Any Member Setting**: Studio has `any_member_can_represent?` enabled
3. **Is Trustee**: User is the studio's trustee user itself

Checked via `StudioUser#can_represent?`:
```ruby
def can_represent?
  archived_at.nil? && (has_role?('representative') || studio.any_member_can_represent?)
end
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

### Starting a Session

**Route:** `POST /studios/:studio_handle/represent`

**Requirements:**
- User must have `can_represent?` permission
- User must not have an active session already
- User must confirm understanding (checkbox)

**What happens:**
1. Creates `RepresentationSession` record
2. Calls `begin!` to initialize activity log
3. Sets session cookies: `trustee_user_id`, `representation_session_id`
4. Redirects to `/representing` dashboard

### During Representation

While a session is active:

- `current_user` returns the trustee user (not the person)
- Actions are attributed to the trustee user
- Every action records a semantic event in the session's activity log
- Session is scoped to studio paths (`/representing` or `/studios/`)

### Recording Activity

Actions during representation are automatically recorded via `RepresentationSession#record_activity!`:

```ruby
current_representation_session.record_activity!(
  request: request,
  semantic_event: {
    timestamp: Time.current,
    event_type: 'create',
    studio_id: current_studio.id,
    main_resource: {
      type: 'Note',
      id: note.id,
      truncated_id: note.truncated_id,
    },
    sub_resources: [],
  }
)
```

**Supported Event Types:**
| Event Type | Description |
|------------|-------------|
| `create` | New resource created |
| `update` | Existing resource modified |
| `confirm` | User confirmed reading a note |
| `add_options` | Options added to decision |
| `vote` | Voted on decision |
| `commit` | Joined commitment |
| `pin` | Pinned resource |
| `unpin` | Unpinned resource |

**Supported Resource Types:**
- Main: `Heartbeat`, `Note`, `Decision`, `Commitment`
- Sub: `NoteHistoryEvent`, `Option`, `Vote`, `CommitmentParticipant`

### Stopping a Session

**Route:** `DELETE /studios/:studio_handle/represent`

**What happens:**
1. Calls `end!` to set `ended_at`
2. Clears session cookies
3. Redirects to studio with link to session record

## Viewing Representation Sessions

### Session Record

Each representation session has a permanent record at:
```
/studios/{studio_handle}/r/{truncated_id}
```

The record shows:
- Who represented (the person, not the trustee)
- When the session started and ended
- Duration and action count
- Human-readable activity log
- Comments from studio members

### Activity Log Format

The `human_readable_activity_log` method converts raw events to displayable format:

| Time | Action | Resource | Studio |
|------|--------|----------|--------|
| 2:30 PM | created | Test Note | Engineering |
| 2:35 PM | voted on | Q4 Budget | Engineering |

Consecutive votes on the same decision are deduplicated (shows only final vote).

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
- Next request detects `can_impersonate?` returns false
- Session is ended gracefully
- User is returned to their person identity

### Accessing Pages Outside Studio Scope

During representation, users are confined to studio-scoped paths. Attempting to access other areas:
- Clears the representation session
- Returns user to person identity
- Redirects appropriately

## Database Schema

### RepresentationSession

| Column | Type | Description |
|--------|------|-------------|
| `id` | uuid | Primary key |
| `truncated_id` | string | 8-char ID for URLs |
| `tenant_id` | uuid | FK to tenant |
| `studio_id` | uuid | FK to studio being represented |
| `representative_user_id` | uuid | The person doing the representing |
| `trustee_user_id` | uuid | The studio's trustee user |
| `began_at` | timestamp | When session started |
| `ended_at` | timestamp | When session ended (null if active) |
| `confirmed_understanding` | boolean | User confirmed checkbox |
| `activity_log` | jsonb | Array of semantic events |

### RepresentationSessionAssociation

Tracks all resources touched during a session:

| Column | Type | Description |
|--------|------|-------------|
| `representation_session_id` | uuid | FK to session |
| `resource_id` | uuid | ID of touched resource |
| `resource_type` | string | Type of resource |
| `resource_studio_id` | uuid | Studio where resource exists |

## Related Documentation

- [USER_TYPES.md](USER_TYPES.md) - User types including trustee users
- [PHILOSOPHY.md](../PHILOSOPHY.md) - Collective agency concepts
