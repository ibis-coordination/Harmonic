# Scheduled Reminders Improvement Plan

**Date**: 2026-01-23
**Revised**: 2026-01-22
**Based on**: [scheduled-reminders-review.md](scheduled-reminders-review.md)
**Status**: Draft

---

## Overview

This plan addresses all 13 issues identified in the code review, organized into implementation batches by priority and dependency.

**Key changes from v1**:
- Consolidated routing fixes (former 1.1 and 2.2) into a single approach
- Added investigation steps before implementing fixes
- Reorganized batches to minimize context switching
- Added end-to-end verification steps

---

## Batch 1: Investigate and Fix Test Failures (Blocking CI)

**Issues addressed**: #2

This must be done first because failing tests block CI and may reveal deeper issues that affect other fixes.

### 1.1 Investigation Steps

Run these commands and capture output before implementing any fixes:

```bash
# Run the specific failing tests
docker compose exec web bundle exec rails test test/controllers/whoami_controller_test.rb
docker compose exec web bundle exec rails test test/controllers/motto_controller_test.rb

# Check what changed recently in these controllers
git log --oneline -10 -- app/controllers/whoami_controller.rb
git log --oneline -10 -- app/controllers/motto_controller.rb
git log --oneline -10 -- app/controllers/application_controller.rb

# Check the current authentication setup
grep -n "require_login" app/controllers/whoami_controller.rb
grep -n "require_login" app/controllers/motto_controller.rb
grep -n "before_action" app/controllers/application_controller.rb | head -20
```

### 1.2 Expected Findings and Fixes

**Scenario A: `require_login!` was added to these controllers**

These pages should be accessible without login. Fix by ensuring:
```ruby
# In whoami_controller.rb and motto_controller.rb
skip_before_action :require_login!, only: [:index]
```

**Scenario B: `ApplicationController` changed default behavior**

If a global `before_action :require_login!` was added, these controllers need explicit skip.

**Scenario C: ApiToken `scope` attribute error**

The test at `whoami_controller_test.rb:80` references a non-existent `scope` attribute.

Investigation:
```bash
# Check ApiToken model for available attributes
grep -n "attribute\|column" app/models/api_token.rb
rails runner "puts ApiToken.column_names.join(', ')"
```

Fix: Update the test to use correct attribute names or remove the invalid attribute.

### 1.3 Verification

```bash
# After fixes, verify all tests pass
docker compose exec web bundle exec rails test test/controllers/whoami_controller_test.rb
docker compose exec web bundle exec rails test test/controllers/motto_controller_test.rb

# Run full test suite to check for regressions
./scripts/run-tests.sh
```

### 1.4 If Tests Reveal Deeper Issues

If investigation reveals the test failures are symptoms of a larger problem:
1. Document the root cause
2. Assess whether it affects the scheduled reminders feature
3. Create a separate issue/plan if the scope expands significantly
4. Do not proceed to Batch 2 until tests pass

---

## Batch 2: Fix All Path/Routing Issues (Consolidated)

**Issues addressed**: #1, #4, #5

These are all related to incorrect URL paths for user webhooks. Fix them together to ensure consistency.

### 2.1 Chosen Approach: Update Views to Use User-Specific Paths

Instead of adding redirect routes (complex, error-prone), update views to always generate correct paths. This is cleaner and eliminates the routing complexity.

### 2.2 Fix View Template Paths

**File**: `app/views/user_webhooks/index.md.erb`

Change the `base_path` logic from:
```erb
<%
base_path = @target_user == @current_user ? "/settings/webhooks" : "/u/#{@target_user.handle}/webhooks"
-%>
```

To:
```erb
<%
# Always use the full user-specific path for consistency
base_path = "/u/#{@target_user.handle}/settings/webhooks"
-%>
```

Also fix the "other user" path which is missing `/settings/`:
- Wrong: `/u/#{@target_user.handle}/webhooks`
- Correct: `/u/#{@target_user.handle}/settings/webhooks`

### 2.3 Fix Webhook#path Method

**File**: `app/models/webhook.rb`

Change line ~47 from:
```ruby
"/u/#{tu&.handle}/webhooks"
```

To:
```ruby
"/u/#{tu&.handle}/settings/webhooks"
```

### 2.4 Verify No Other Path References

```bash
# Search for any other incorrect webhook path patterns
grep -rn "/webhooks" app/views/user_webhooks/
grep -rn "settings/webhooks" app/ | grep -v ".erb:" | grep -v "routes.rb"
```

### 2.5 Update Tests

Update `test/models/webhook_test.rb` (or wherever path tests exist) to expect the correct path:
```ruby
test "path returns user settings path for user webhooks" do
  webhook = create_user_webhook(user: @user)
  assert_equal "/u/#{@user.handle}/settings/webhooks", webhook.path
end
```

### 2.6 Verification

```bash
# Run webhook-related tests
docker compose exec web bundle exec rails test test/models/webhook_test.rb
docker compose exec web bundle exec rails test test/controllers/user_webhooks_controller_test.rb
```

---

## Batch 3: Add Discoverability

**Issues addressed**: #3

### 3.1 Add Webhooks Link to Settings Page

**Files to modify**:
- `app/views/users/settings.html.erb`
- `app/views/users/settings.md.erb`

**Implementation for HTML** (add after API Tokens section):
```erb
<% if @current_tenant.api_enabled? %>
  <section class="settings-section">
    <h2>Webhooks</h2>
    <p>Receive notifications at an external URL when events occur. Useful for AI agents that need to "wake up" at scheduled times.</p>
    <%= link_to "Manage Webhooks", "/u/#{@settings_user.handle}/settings/webhooks", class: "button" %>
  </section>
<% end %>
```

**Implementation for Markdown** (add to actions list):
```erb
## Webhooks

* [Manage Webhooks](/u/<%= @settings_user.handle %>/settings/webhooks) - Configure personal webhooks for reminders and notifications
```

---

## Batch 4: Investigate and Fix Tenant User Lookup

**Issues addressed**: #9

### 4.1 Investigation: Verify Current Implementation

The original plan document shows `user.tenant_user_for(tenant)` being used, but the review says the code uses `user.tenant_user`. Verify what the code actually does:

```bash
# Check current implementation
grep -n "tenant_user" app/services/reminder_service.rb
grep -n "def tenant_user" app/models/user.rb
```

### 4.2 If Fix Is Needed

**File**: `app/services/reminder_service.rb`

Change from:
```ruby
channels = user.tenant_user&.notification_channels_for("reminder") || ["in_app"]
```

To:
```ruby
tenant = Tenant.find(Tenant.current_id)
channels = user.tenant_user_for(tenant)&.notification_channels_for("reminder") || ["in_app"]
```

Verify `tenant_user_for` exists on User model. If not, add it:
```ruby
# In app/models/user.rb
def tenant_user_for(tenant)
  tenant_users.find_by(tenant: tenant)
end
```

### 4.3 If Already Correct

If investigation shows the code already uses `tenant_user_for(tenant)`, update the review document to mark this issue as "Not Applicable" and move on.

---

## Batch 5: Medium Priority Improvements

**Issues addressed**: #6, #7, #8

### 5.1 Document Race Condition (Accept for Now)

**Issue**: #6 - Non-atomic rate limit check in `ReminderDeliveryJob`

**Decision**: Accept the edge case for now. The job runs on a cron schedule and concurrent delivery for the same user is unlikely.

**File**: `app/jobs/reminder_delivery_job.rb`

Add comment documenting the limitation:
```ruby
# NOTE: Rate limiting check is not atomic. In rare cases of concurrent job
# execution, slightly more than MAX_DELIVERIES_PER_USER_PER_MINUTE could be
# delivered. This is acceptable because:
# 1. The job runs on a cron schedule (not triggered by events)
# 2. Concurrent execution for the same user is unlikely
# 3. The consequence (a few extra deliveries) is minor
# If this becomes an issue, consider Redis-based distributed rate limiting.
```

### 5.2 Add HTML Views for User Webhooks

**Issue**: #7 - Only markdown views exist

**File to create**: `app/views/user_webhooks/index.html.erb`

```erb
<% content_for :title, "Webhooks for #{@target_user.handle}" %>

<h1>Webhooks</h1>

<% if @target_user != @current_user %>
  <div class="notice">
    You are managing webhooks for <strong><%= @target_user.name || @target_user.handle %></strong>.
  </div>
<% end %>

<% if @webhooks.empty? %>
  <p>No webhooks configured.</p>
  <p>Webhooks allow you to receive notifications at an external URL when events occur.</p>
<% else %>
  <table class="data-table">
    <thead>
      <tr>
        <th>Name</th>
        <th>URL</th>
        <th>Events</th>
        <th>Status</th>
        <th>Actions</th>
      </tr>
    </thead>
    <tbody>
      <% @webhooks.each do |webhook| %>
        <tr>
          <td><%= webhook.name %></td>
          <td><code><%= truncate(webhook.url, length: 40) %></code></td>
          <td><%= webhook.events.join(", ") %></td>
          <td><%= webhook.enabled? ? "Enabled" : "Disabled" %></td>
          <td>
            <%= button_to "Delete",
                "/u/#{@target_user.handle}/settings/webhooks/actions/delete",
                params: { id: webhook.truncated_id },
                method: :post,
                data: { turbo_confirm: "Delete this webhook?" },
                class: "button button--danger button--small" %>
          </td>
        </tr>
      <% end %>
    </tbody>
  </table>
<% end %>

<h2>Create Webhook</h2>

<%= form_with url: "/u/#{@target_user.handle}/settings/webhooks/actions/create", method: :post, class: "form" do |f| %>
  <div class="form-group">
    <%= f.label :name, "Name (optional)" %>
    <%= f.text_field :name, placeholder: "My webhook" %>
  </div>
  <div class="form-group">
    <%= f.label :url, "Webhook URL" %>
    <%= f.url_field :url, required: true, placeholder: "https://example.com/webhook" %>
  </div>
  <div class="form-group">
    <%= f.label :events, "Events (comma-separated, default: reminders.delivered)" %>
    <%= f.text_field :events, placeholder: "reminders.delivered" %>
  </div>
  <%= f.submit "Create Webhook", class: "button button--primary" %>
<% end %>

<p><%= link_to "Back to Settings", "/u/#{@target_user.handle}/settings" %></p>
```

### 5.3 Edit Webhook Action (Optional - Defer)

**Issue**: #8 - No way to edit webhooks

**Decision**: Defer to a follow-up PR. The delete-and-recreate workflow is acceptable for now, and editing webhooks was not in the original requirements.

Document in the review that this is intentionally deferred.

---

## Batch 6: Low Priority Polish (Defer to Follow-up PR)

**Issues addressed**: #10, #11, #12, #13

These should be tracked as follow-up work but not block the current merge.

### 6.1 Improve Time Parsing Strictness (#11)

Create a follow-up issue to make time parsing more strict and provide better error messages.

### 6.2 Fix Unread Count (#13)

Create a follow-up issue to exclude scheduled reminders from unread count. Requires investigation to confirm the behavior.

### 6.3 Document Rate-Limited Retry (#12)

Already addressed in 5.1. No additional work needed.

### 6.4 Add Sorbet Types (#10)

Create a follow-up issue for adding type signatures to new controllers.

---

## Testing Checklist

### Automated Tests

- [ ] Full test suite passes: `./scripts/run-tests.sh`
- [ ] Sorbet type check passes: `docker compose exec web bundle exec srb tc`
- [ ] RuboCop passes: `docker compose exec web bundle exec rubocop`

### Manual Testing via MCP Server

**Authentication**:
- [ ] Navigate to `/whoami` without auth - shows "not logged in" message (not redirect)
- [ ] Navigate to `/motto` without auth - shows motto page (not redirect)

**Reminders**:
- [ ] Navigate to `/notifications` - see scheduled reminders section (if any exist)
- [ ] Create reminder with relative time (`1h`) - works
- [ ] Create reminder with ISO 8601 time - works
- [ ] Delete reminder - works

**Webhooks**:
- [ ] Navigate to `/u/:handle/settings` - shows webhooks link
- [ ] Navigate to `/u/:handle/settings/webhooks` - shows webhook management page
- [ ] Create webhook - works
- [ ] Delete webhook - works

### End-to-End Verification

To verify the complete flow works:

1. Create a user webhook pointing to a test endpoint (e.g., webhook.site)
2. Create a reminder scheduled for 2 minutes in the future
3. Wait for `ReminderDeliveryJob` to run (runs every minute)
4. Verify the webhook was called with `reminders.delivered` event
5. Verify the reminder appears in delivered notifications

---

## Follow-up Issues to Create

After completing this work, create GitHub issues for:

1. **Strict time parsing for reminders** - Improve error messages, reject ambiguous formats
2. **Exclude scheduled reminders from unread count** - UX polish
3. **Add Sorbet types to notifications/webhooks controllers** - Code quality
4. **Add edit webhook action for user webhooks** - Feature enhancement (optional)

---

## Approval Criteria

The feature is ready for merge when:

1. [ ] All tests pass (Batch 1 complete)
2. [ ] All path/routing issues fixed (Batch 2 complete)
3. [ ] Discoverability added (Batch 3 complete)
4. [ ] Tenant user lookup verified/fixed (Batch 4 complete)
5. [ ] Manual testing checklist passes
6. [ ] Follow-up issues created for deferred work

Medium priority items (Batch 5) can be merged in a follow-up PR if time is constrained.
