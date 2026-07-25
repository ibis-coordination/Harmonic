# User Types

This document describes the three user types in Harmonic and their roles in the system.

## Overview

| Type | Has OAuth | Has Parent | Purpose |
|------|-----------|------------|---------|
| `human` | Yes | No | Regular human users who authenticate via OAuth or email/password |
| `ai_agent` | No | Yes | AI agents or automated users managed by a parent |
| `collective_identity` | No | No | Synthetic users representing collectives for collective agency |

## User Type Details

### Human

A **human** is a regular human user who authenticates via OAuth (Google, GitHub, etc.) or, where a tenant enables the "identity" auth provider, email/password (`OmniAuthIdentity`, with TOTP 2FA).

**Characteristics:**
- Has `OauthIdentity` records linking them to external providers, and/or an email/password `OmniAuthIdentity`
- Cannot have a `parent_id` (validation enforced)
- Can create and manage ai_agent users
- Can be granted representative permissions to act on behalf of collectives

**Created via:** OAuth authentication flow in `OauthIdentity.find_or_create_from_auth`, or the email/password identity provider where enabled

### AI Agent

A **ai_agent** is an automated user (typically an AI agent) that operates under the authority of a parent person user.

**Characteristics:**
- Must have a `parent_id` pointing to their principal. The principal is usually a human; built-in personas are principaled by their collective's identity user (or the workspace owner, for private workspaces, which mint no identity user).
- Cannot authenticate directly via OAuth
- External agents authenticate via API tokens issued by their parent (`mcp` or `llm_gateway` type); internal runner-managed agents use system-issued internal tokens and cannot hold user-issued keys
- Can be represented by their parent user
- Parent can add ai_agent to collectives where parent has invite permission

**Created via:**
- API: `POST /api/v1/users` (creates ai_agent for authenticated user)
- Service: `ApiHelper#create_ai_agent`

**Representation:** A parent can represent their ai_agent via `User#can_represent?`. When representing:
- `current_user` returns the granting_user (for action attribution)
- Actions are attributed to the granting_user (linked to the ai_agent via TrusteeGrant)
- Parent can stop representation at any time

### Collective Identity

A **collective_identity** is a synthetic user that enables collective agency. Identity users allow a collective to act as a unified entity, and serve as the principal (`parent`) of the collective's built-in persona agents.

**Characteristics:**
- Created automatically when a collective is created (never by users directly)
- Has a generated email like `{uuid}@not-a-real-email.com`
- Cannot have a `parent_id`
- Cannot be a member of the main collective (validation enforced)
- Cannot be the creator of content (validation enforced)

**Usage:**
- Every collective automatically creates an identity user via `Collective#create_identity_user!`
- `Collective.identity_user` points to this user
- `User#collective_identity?` returns true
- `User#identity_collective` returns the associated collective

## Relationship Diagram

```
+-----------------------------------------------------------------+
|                         HUMAN USER                              |
|  - Authenticates via OAuth                                       |
|  - Can create ai_agents                                          |
|  - Can represent collectives                                     |
+---------------------+-------------------+------------------------+
                      |                   |
                      | creates           | can_represent?
                      v                   v
+-----------------------------+   +-----------------------------+
|       AI AGENT USER         |   |       COLLECTIVE            |
|  - parent_id -> human      |   |  - has identity_user        |
|  - No OAuth identity        |   |  - has representative role  |
|  - Parent can represent     |   +--------------+--------------+
+-----------------------------+                  |
                                                 | has
                                                 v
                                  +-----------------------------+
                                  | COLLECTIVE IDENTITY USER    |
                                  |  - Represents collective    |
                                  |  - Created automatically    |
                                  |  - Used in representation   |
                                  +-----------------------------+
```

## Authorization Methods

### `User#can_represent?(collective_or_user)`

Returns true if this user can act on behalf of a collective or user:
- Identity user can represent their own collective
- Collective member with `representative` role can represent
- Collective member can represent if `collective.any_member_can_represent?` is true

### `User#can_edit?(user)`

Returns true if this user can modify another user's profile:
- Users can edit themselves
- Parents can edit their ai_agents

### `User#can_add_ai_agent_to_collective?(ai_agent, collective)`

Returns true if this user can add a ai_agent to a collective:
- Must be the ai_agent's parent
- Must have invite permission in the collective

## Validation Rules

| Rule | Enforced By |
|------|-------------|
| Human cannot have parent_id | `User#ai_agent_must_have_parent` |
| AI Agent must have parent_id | `User#ai_agent_must_have_parent` |
| User cannot be its own parent | `User#ai_agent_must_have_parent` |
| Identity user cannot be member of main collective | `CollectiveMember#identity_users_not_member_of_main_collective` |
| Identity user cannot create content | `Collective#creator_is_not_collective_identity` |

## Related Documentation

- [REPRESENTATION.md](REPRESENTATION.md) - How representation sessions work
- [CLAUDE.md](../CLAUDE.md) - AI coding assistant guidelines
