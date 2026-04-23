# Trustee Grants: Remaining Work

## Context

The trustee grants system allows users to delegate specific capabilities to other users (including AI agents). The core system is fully implemented — model, controller, views, acceptance workflow, representation session integration, capability enforcement, and impersonation replacement are all complete.

See the completed plan at `.claude/plans/completed/2026/02/TRUSTEE_GRANTS.md` for full history.

## Remaining Work

### 1. Notifications

Notify users of trustee grant lifecycle events. TODOs exist in `trustee_grant.rb` (lines 78, 85, 94) and `trustee_grants_controller.rb` (line 130).

**Events to notify:**

| Event | Recipient |
|-------|-----------|
| Grant requested | trustee_user |
| Grant accepted | granting_user |
| Grant declined | granting_user |
| Grant revoked | trustee_user |
| Session started | granting_user |
| Session ended | granting_user (with action summary) |

Use existing `Notification` model. Current types are `%w[mention comment participation system reminder]` — add new types for trustee grant events.

### 2. Trio Integration

Enable Trio (AI ensemble agent) to request and use delegated permissions via trustee grants.

- Trio checks for active grant before acting on behalf of a user
- If no grant exists, Trio can request one (creates pending TrusteeGrant)
- Add "Trio Access" section to user settings with capability presets and collective scope selection
- TrioController already exists with `trio_enabled?` gate

### 3. Rename `studio_scope` Column

The `studio_scope` JSONB column and its `"studio_ids"` key still use old "studio" terminology. An alias method `collective_scope` and method `allows_collective?` already exist as a bridge.

- Rename column: `studio_scope` → `collective_scope`
- Rename JSONB key: `"studio_ids"` → `"collective_ids"`
- Remove alias methods (lines 115-116 in trustee_grant.rb)
- Update comments referencing the planned rename (lines 114, 121, 508)
