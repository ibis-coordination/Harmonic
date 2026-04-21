# Plan: Safety Pipeline (Reporting, Blocking, Moderation)

## Context

A feature audit identified three absent table-stakes safety features: content reporting/flagging, user blocking/muting, and moderation tooling. The app already has Rack::Attack rate limiting (`config/initializers/rack_attack.rb`) and admin tools for suspending users, but there is no way for **users** to report bad content or block other users, and no way for **admins** to see and act on reports.

This plan builds the pipeline: users report/block → reports land in admin queue → admins act (suspend, force reset, revoke sessions). The admin response tools (force password reset, revoke sessions) and the security log bug fix are included here because they complete the pipeline.

See also: [Sys Admin Ops plan](sys-admin-improvements.md) for the operational tooling track.

## Features (in implementation order)

### 1. Security log bug fix (app admin)

**Problem**: The security dashboard at `/app-admin/security` shows blank Event Type column and wrong badge colors.

**Root cause**: Field name mismatches between what `SecurityAuditLog` writes and what the view reads:
- Log writes `event`, view reads `event_type` → blank Event Type column
- `severity` is never written to the JSON payload — it's only used to route the Ruby log level in `log_event` (line 314-319). The view reads `event["severity"]` which is always nil, so badge coloring is broken.
- Email field works via fallback but primary key `user_email` never matches
- Details column reads `event["details"]` / `event["message"]`, but most events don't write either field — login failures write `reason`, admin actions write `action`, etc. → blank Details column for most events

**Fix**: Two-part fix:
1. **View** (`security_dashboard.html.erb`): Change to match actual log field names
2. **Log writer** (`security_audit_log.rb`): Add `severity` to the JSON payload in `log_event` so it's persisted and readable

**Files to modify**:
- `app/views/app_admin/security_dashboard.html.erb` (lines 39-56)
- `app/services/security_audit_log.rb` (line 307 — add `severity:` to payload hash)

**Changes in view**:
- Line 39: `event[:event_type]` → `event[:event] || event["event"]`
- Line 41: Map severity to badge — `error` → danger, `warn` → warning, default → muted. For old events without severity, derive from event type (e.g., `login_failure`, `ip_blocked` → warning).
- Line 47: Simplify to `event[:email] || event["email"]`
- Line 56: Build a smarter details string from available fields — show `reason` for login failures, `action` for admin events, `request_path` for rate limiting, etc. Fall back to a compact display of remaining non-standard fields.

**Changes in log writer**:
- Line 307-311: Add `severity: severity.to_s` to the payload hash so it's persisted in the JSON. This won't affect existing log entries (they'll just lack the field, handled by the view fallback).

---

### 2. User blocking

**What**: Users can block other users. Blocked users cannot view the blocker's profile, comment on their content, or @mention them. Admins can see blocks on the user detail page.

**New model: `UserBlock`**
- `blocker_id` (references users, not null)
- `blocked_id` (references users, not null)
- `tenant_id` (references tenants, not null)
- `reason` (text, nullable — optional note for the blocker's own reference)
- `created_at`, `updated_at`
- Unique index on `[blocker_id, blocked_id, tenant_id]`
- Index on `[blocked_id, tenant_id]` (for checking "am I blocked by this person?")
- **No collective_id** — blocks are tenant-wide (if you block someone, it applies across all collectives in that tenant)

**Migration**: `db/migrate/TIMESTAMP_create_user_blocks.rb`

**Model file**: `app/models/user_block.rb`
- Tenant-scoped (standard `belongs_to :tenant`, `before_validation :set_tenant_id` pattern)
- `belongs_to :blocker, class_name: "User"`
- `belongs_to :blocked, class_name: "User"`
- Validation: cannot block yourself
- Class method: `UserBlock.between?(user_a, user_b)` — returns true if either has blocked the other (for bidirectional checks)

**User model additions** (`app/models/user.rb`):
- `has_many :blocks_given, class_name: "Block", foreign_key: :blocker_id`
- `has_many :blocks_received, class_name: "Block", foreign_key: :blocked_id`
- `def blocked?(other_user)` — checks if self has blocked other_user in current tenant
- `def blocked_by?(other_user)` — checks if other_user has blocked self in current tenant

**Controller**: `app/controllers/blocks_controller.rb`
- `create` — block a user (POST `/blocks`, params: `blocked_id`)
- `destroy` — unblock a user (DELETE `/blocks/:id`)
- `index` — list your blocks (GET `/blocks`, linked from user settings)

**ApplicationController enforcement** (`app/controllers/application_controller.rb`):
- Not a blanket before_action (too broad). Instead, add a helper method `check_not_blocked_by!(user)` that controllers call where needed.
- `NotesController#show`, `UsersController#show`, comment creation actions — call the check.
- Returns 404 (not 403) to avoid revealing that the block exists.

**View integration**:
- User profile (`app/views/users/show.html.erb`): Add "Block user" option in the more-button menu (except for self)
- User settings: Add "Blocked users" section listing blocks with unblock buttons
- App admin show_user (`app/views/app_admin/show_user.html.erb`): Show blocks given/received counts in user info section

**Routes** (`config/routes.rb`):
```
resources :blocks, only: [:index, :create, :destroy]
```

---

### 3. Content reporting

**What**: Users can report notes, comments, decisions, and commitments. Reports go into an admin review queue at `/app-admin/reports`. Admins can dismiss, resolve, or escalate (suspend user).

**New model: `ContentReport`**
- `reporter_id` (references users, not null)
- `reportable_type` (string, not null — polymorphic: Note, Decision, Commitment)
- `reportable_id` (bigint, not null)
- `tenant_id` (references tenants, not null)
- `reason` (string, not null — enum: `harassment`, `spam`, `inappropriate`, `misinformation`, `other`)
- `description` (text, nullable — free-text details from reporter)
- `status` (string, not null, default `pending` — enum: `pending`, `reviewed`, `dismissed`, `actioned`)
- `reviewed_by_id` (references users, nullable — admin who reviewed)
- `reviewed_at` (datetime, nullable)
- `admin_notes` (text, nullable — admin's internal notes)
- `created_at`, `updated_at`
- Index on `[tenant_id, status]` (for admin queue filtering)
- Index on `[reportable_type, reportable_id]` (for checking if content has reports)
- Index on `[reporter_id, reportable_type, reportable_id, tenant_id]` unique (prevent duplicate reports)

**Migration**: `db/migrate/TIMESTAMP_create_content_reports.rb`

**Model file**: `app/models/content_report.rb`
- Tenant-scoped (standard pattern)
- `belongs_to :reporter, class_name: "User"`
- `belongs_to :reportable, polymorphic: true`
- `belongs_to :reviewed_by, class_name: "User", optional: true`
- Validation: cannot report your own content
- Scope: `pending` → `where(status: "pending")`
- `def review!(admin:, status:, notes: nil)` — mark as reviewed

**Reportable concern**: `app/models/concerns/reportable.rb`
- `has_many :reports, as: :reportable`
- `def reported?` — has any pending reports
- Include in `Note`, `Decision`, `Commitment`

**User-facing controller**: `app/controllers/reports_controller.rb`
- `new` — report form (GET `/reports/new?reportable_type=Note&reportable_id=123`)
- `create` — submit report (POST `/reports`)
- Confirm submission with flash message ("Thank you for reporting. Our team will review this.")

**Admin controller additions** (`app/controllers/app_admin_controller.rb`):
- `reports` — list pending/all reports (GET `/app-admin/reports`)
- `show_report` — report detail with content preview and reporter info (GET `/app-admin/reports/:id`)
- `execute_review_report` — mark as dismissed/actioned with notes (POST `/app-admin/reports/:id/review`)
- Log review actions via `SecurityAuditLog.log_admin_action`

**View integration**:
- Content views (notes/show, decisions/show, commitments/show): Add "Report" option in more-button menu
- Comments: Add small "Report" link/icon per comment
- App admin dashboard: Add "Pending reports" count badge
- New views: `app/views/app_admin/reports.html.erb`, `app/views/app_admin/show_report.html.erb`
- New view: `app/views/reports/new.html.erb` (report form)

**Routes** (`config/routes.rb`):
```ruby
# User-facing
resources :reports, only: [:new, :create]

# App admin
get 'app-admin/reports' => 'app_admin#reports'
get 'app-admin/reports/:id' => 'app_admin#show_report'
post 'app-admin/reports/:id/review' => 'app_admin#execute_review_report'
```

---

### 4. Force password reset (app admin)

**What**: Admin action to invalidate a user's password and send them a reset link. Useful when responding to a report that reveals a compromised account.

**Files to modify**:
- `config/routes.rb` — add routes after line 234
- `app/controllers/app_admin_controller.rb` — add describe/execute actions
- `app/views/app_admin/show_user.html.erb` — add button in Actions accordion

**Implementation**:
- Find user's `OmniAuthIdentity` (skip if user has no password identity)
- **Order matters**: `update_password!` calls `clear_reset_password_token!` internally (`omni_auth_identity.rb:63`), so we must invalidate the password FIRST, then generate the reset token:
  1. Invalidate current password: `identity.password = SecureRandom.hex(32); identity.password_confirmation = identity.password; identity.save!`
  2. Generate reset token: `raw_token = identity.generate_reset_password_token!`
  3. Send reset email: `PasswordResetMailer.reset_password_instructions(identity, raw_token).deliver_later`
- Log via `SecurityAuditLog.log_admin_action`
- Checkbox option: "Send reset email to user" (default checked)

**Routes**:
```
get  'app-admin/users/:id/actions/force_password_reset' => 'app_admin#describe_force_password_reset'
post 'app-admin/users/:id/actions/force_password_reset' => 'app_admin#execute_force_password_reset'
```

---

### 5. Revoke all sessions (app admin)

**What**: Force-logout a user from all devices and revoke all API tokens. Key escalation tool when acting on reports.

**Problem**: Sessions use `cookie_store` (no server-side session table), so we can't delete sessions directly.

**Approach**: Add a `sessions_revoked_at` timestamp to `users`. On each request, `check_session_timeout` compares `session[:logged_in_at]` against this timestamp — if the session predates the revocation, force logout.

**Migration**: `db/migrate/TIMESTAMP_add_sessions_revoked_at_to_users.rb`

**Files to modify**:
- `config/routes.rb` — add routes after line 234
- `app/models/user.rb` — add `revoke_all_sessions!` method (near `suspend!` at line 410)
- `app/controllers/application_controller.rb` — add revocation check in `check_session_timeout` (after line 962, before idle timeout)
- `app/controllers/app_admin_controller.rb` — add describe/execute actions
- `app/views/app_admin/show_user.html.erb` — add button in Actions accordion

**User model method**:
```ruby
def revoke_all_sessions!
  update!(sessions_revoked_at: Time.current)
  ApiToken.for_user_across_tenants(self).where(deleted_at: nil).find_each(&:delete!)
end
```

**ApplicationController check** (insert after absolute timeout check, before idle timeout):
```ruby
if session[:logged_in_at].present? && current_human_user&.sessions_revoked_at.present?
  if Time.at(session[:logged_in_at]) < current_human_user.sessions_revoked_at
    SecurityAuditLog.log_logout(user: current_human_user, ip: request.remote_ip, reason: "sessions_revoked")
    reset_session
    flash[:alert] = "Your session has been revoked. Please log in again."
    redirect_to "/login"
    return
  end
end
```

**Routes**:
```
get  'app-admin/users/:id/actions/revoke_all_sessions' => 'app_admin#describe_revoke_all_sessions'
post 'app-admin/users/:id/actions/revoke_all_sessions' => 'app_admin#execute_revoke_all_sessions'
```

---

## Admin Workflow (how the pieces connect)

1. **User reports content** → Report created with `status: pending`
2. **Admin sees report** in `/app-admin/reports` queue (or badge count on dashboard)
3. **Admin reviews report** → views the content, reporter info, and reported user's history
4. **Admin decides action**:
   - **Dismiss** — false alarm, mark report as `dismissed`
   - **Action** — mark report as `actioned`, then navigate to the user and:
     - **Suspend** (existing) — immediate lockout
     - **Force password reset** (feature 4) — if account may be compromised
     - **Revoke sessions** (feature 5) — force re-login on all devices
5. **Meanwhile**, the reporter (and others) can **block** the offending user immediately for personal protection, without waiting for admin action.

## Verification

1. **Security log fix**: Visit `/app-admin/security`, confirm Event Type shows values, badges use correct colors, details column populated
2. **Blocking**: As user A, block user B. Verify B cannot see A's profile (gets 404). Verify A sees B in blocked users list. Verify admin sees block counts on user detail page.
3. **Reporting**: As user A, report a note by user B. Verify report appears in `/app-admin/reports`. Review the report as admin. Verify status updates.
4. **Force password reset**: Click on a test user, force reset, verify old password stops working and reset email arrives
5. **Revoke sessions**: Log in as test user in two browsers, admin revokes sessions, verify both forced to re-login on next request; verify API tokens deleted

Run targeted tests after each feature:
```bash
docker compose exec web bundle exec rails test test/models/block_test.rb
docker compose exec web bundle exec rails test test/models/report_test.rb
docker compose exec web bundle exec rails test test/controllers/blocks_controller_test.rb
docker compose exec web bundle exec rails test test/controllers/reports_controller_test.rb
docker compose exec web bundle exec rails test test/controllers/app_admin_controller_test.rb
docker compose exec web bundle exec rails test test/controllers/application_controller_test.rb
docker compose exec web bundle exec rails test test/models/user_test.rb
```
