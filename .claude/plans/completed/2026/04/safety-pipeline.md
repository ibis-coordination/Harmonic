# Plan: Safety Pipeline

**Status: Implemented** (on `safety-pipeline` branch, not yet merged to `main`)

## Context

A feature audit identified three absent table-stakes safety features: content reporting/flagging, user blocking/muting, and moderation tooling. The app already has Rack::Attack rate limiting (`config/initializers/rack_attack.rb`) and admin tools for suspending users, but there was no way for **users** to report bad content or block other users, and no way for **admins** to see and act on reports.

This plan builds the pipeline: users report/block → reports land in admin queue → admins act (suspend, security reset). The admin response tool (account security reset — force password reset + revoke sessions) completes the pipeline.

See also:
- [Content Reporting Design](content-reporting-design.md) — detailed architecture for the reporting feature
- [Sys Admin Ops plan](../05/sys-admin-improvements.md) — operational tooling track

## Features (in implementation order)

### 1. Security log bug fix (app admin) ✓

**Commit**: `64358f7`

Fixed field name mismatches between what `SecurityAuditLog` writes and what the security dashboard view reads — blank Event Type column, wrong badge colors, blank Details column. Two-part fix: view updated to match actual log field names, and `severity` added to the JSON payload so it's persisted and readable.

### 2. User blocking ✓

**Commits**: `6c41cba` through `0ac3178`

Users can block other users. Blocked users' content is hidden, blocked users cannot interact with the blocker's content. Block/unblock actions follow the standard actions pattern. Admins see block counts on user detail pages. Block button is in the kebab menu on user profiles. Blocks are tenant-wide (no collective_id).

Key files:
- `app/models/user_block.rb` — model with tenant scoping, self-block validation
- `app/services/api_helper.rb` — `block_user` / `unblock_user` business logic
- `app/services/actions_helper.rb` — action definitions with block-aware conditional visibility
- `app/controllers/users_controller.rb` — block/unblock actions
- `db/migrate/*_create_user_blocks.rb` — migration

### 3. Content deletion (soft delete) ✓

**Commit**: `4a21c13`

Soft delete with text scrubbing via `SoftDeletable` concern. Content creators and admins can delete notes, decisions, and commitments. Deleted content shows a tombstone message. `content_snapshot` method preserves text fields before scrubbing (used by content reporting for evidence preservation).

Key files:
- `app/models/concerns/soft_deletable.rb` — concern with `soft_delete!`, `content_snapshot`, scoping
- `app/controllers/*_controller.rb` — delete actions on each resource controller

### 4. Content reporting ✓

**Commit**: `bfae1a8`

Users can report harmful content for moderator review. Reports follow the actions pattern — `report_content` action on each resource controller (notes, decisions, commitments). No standalone `ContentReportsController`. Content snapshot preserved at report time. "Also block" option on report form. Admin queue at `/app-admin/reports` with review, delete-from-report, and user history.

See [Content Reporting Design](content-reporting-design.md) for full architecture details.

Key files:
- `app/services/api_helper.rb` — `report_content` business logic
- `app/services/actions_helper.rb` — action definition + `REPORT_CONTENT_CONDITION` lambda
- `app/models/content_report.rb` — model with validations
- `app/controllers/app_admin_controller.rb` — admin queue, detail, review, delete-from-report
- `test/controllers/admin_access_control_test.rb` — route-enumerating access control tests

### 5. Account security reset ✓

**Commit**: `64358f7`

Combined force password reset + revoke all sessions into a single admin action. When an admin triggers `account_security_reset`:
1. Revokes all sessions via `sessions_revoked_at` timestamp (forces re-login on next request)
2. Deletes all API tokens (user + child AI agents)
3. Invalidates password and sends reset email (if user has password identity)
4. Logs to `SecurityAuditLog`

Key files:
- `app/controllers/app_admin_controller.rb` — `execute_account_security_reset`
- `app/models/user.rb` — `revoke_all_sessions!` method
- `app/controllers/application_controller.rb` — session revocation check in `check_session_timeout`
- `db/migrate/*_add_sessions_revoked_at_to_users.rb` — migration

## Admin Workflow (how the pieces connect)

1. **User reports content** → Report created with `status: pending`, content snapshot preserved
2. **User blocks author** (optional, via "also block" checkbox) → Immediate personal protection
3. **Admin sees report** in `/app-admin/reports` queue (pending count on dashboard)
4. **Admin reviews report** → views content snapshot, reporter info, reported user's history
5. **Admin decides action**:
   - **Dismiss** — false alarm, mark report as `dismissed`
   - **Action** — mark report as `actioned`, then:
     - **Delete content** — soft-delete directly from report detail page
     - **Suspend user** — navigate to user's admin page
     - **Account security reset** — force password reset + revoke all sessions (if account compromised)

## Security invariants

- **Admin controller boundaries are inviolable**: `SystemAdminController` (sys_admin only), `AppAdminController` (app_admin only), `TenantAdminController` (tenant admin only). No exceptions. Enforced by `AdminAccessControlTest` which enumerates all routes.
- **Tenant safety**: All models use standard tenant scoping. `UserBlock` is tenant-scoped but not collective-scoped (blocks apply across all collectives in a tenant).
- **No `.unscoped`**: All admin queries use `unscoped_for_admin` or `tenant_scoped_only`.

## Future work

- **Collective-level moderation** — collective admins moderating reports for their collective's content (separate feature in `TenantAdminController`, not an exception in `AppAdminController`)
- **Reporter notification** — notify the reporter when their report is resolved
- **Report-a-user** — report a user's pattern of behavior, not just individual content
