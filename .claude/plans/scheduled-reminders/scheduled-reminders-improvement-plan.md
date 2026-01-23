# Scheduled Reminders Improvement Plan

**Date**: 2026-01-23
**Based on**: [scheduled-reminders-review.md](scheduled-reminders-review.md)
**Status**: Draft

---

## Overview

This plan addresses all 13 issues identified in the code review, organized into implementation phases by priority.

---

## Phase 1: Critical Fixes (Must complete before merge)

### 1.1 Fix Missing `/settings/webhooks/actions/*` Routes

**Issue**: #1 - Routes return 404

**Files to modify**:
- `config/routes.rb`

**Implementation**:
Add redirect routes for all `/settings/webhooks/*` paths to match the existing `/settings` redirect pattern:

```ruby
# In routes.rb, add after the existing /settings redirects:
get '/settings/webhooks/actions' => redirect { |_, req| "/u/#{req.env['warden'].user&.handle}/settings/webhooks/actions" }
get '/settings/webhooks/actions/create' => redirect { |_, req| "/u/#{req.env['warden'].user&.handle}/settings/webhooks/actions/create" }
post '/settings/webhooks/actions/create' => 'user_webhooks#execute_create_redirect'
get '/settings/webhooks/actions/delete' => redirect { |_, req| "/u/#{req.env['warden'].user&.handle}/settings/webhooks/actions/delete" }
post '/settings/webhooks/actions/delete' => 'user_webhooks#execute_delete_redirect'
```

**Alternative approach** (simpler): Update the view template to always use user-specific paths instead of adding redirect routes. This is cleaner but requires updating both the view and ensuring the MCP server handles it correctly.

**Tests to add**:
- Test that GET `/settings/webhooks/actions/create` redirects correctly
- Test that POST `/settings/webhooks/actions/create` works

---

### 1.2 Fix Test Failures in Whoami/Motto Controllers

**Issue**: #2 - 9 test failures, 1 error

**Files to investigate**:
- `app/controllers/whoami_controller.rb`
- `app/controllers/motto_controller.rb`
- `test/controllers/whoami_controller_test.rb`

**Investigation steps**:

1. Check if `before_action :require_login!` was added to these controllers during the feature work
2. Review recent changes to `ApplicationController` that might affect authentication
3. Fix the `ApiToken` test that references non-existent `scope` attribute

**Implementation for whoami/motto auth fix**:
These pages should be accessible without login. Ensure these controllers have:
```ruby
skip_before_action :require_login!, only: [:index]
# OR
before_action :require_login!, except: [:index]
```

**Implementation for ApiToken test fix**:
Update `test/controllers/whoami_controller_test.rb:80` to remove the `scope` attribute from ApiToken creation or use the correct attribute name.

**Tests to verify**:
- Run `rails test test/controllers/whoami_controller_test.rb`
- Run `rails test test/controllers/motto_controller_test.rb`
- Run full test suite to ensure no regressions

---

## Phase 2: High Priority Fixes

### 2.1 Add Webhooks Link to Settings Page

**Issue**: #3 - No discoverability

**Files to modify**:
- `app/views/users/settings.html.erb`
- `app/views/users/settings.md.erb`

**Implementation for HTML**:
Add a new section after "API Tokens" or in the actions area:
```erb
<% if @current_tenant.api_enabled? %>
  <h2>Webhooks</h2>
  <p>Webhooks allow you to receive notifications at an external URL. Useful for AI agents that need to "wake up" at scheduled times.</p>
  <%= link_to 'Manage Webhooks', "#{@settings_user.path}/settings/webhooks", class: 'button' %>
<% end %>
```

**Implementation for Markdown**:
Add to the actions list:
```erb
* [Webhooks](<%= @settings_user.path %>/settings/webhooks) - Manage personal webhooks for reminders
```

---

### 2.2 Fix View Template Path Inconsistency

**Issue**: #4 - Confusing base_path logic

**Files to modify**:
- `app/views/user_webhooks/index.md.erb`

**Implementation**:
Replace the conditional `base_path` with a consistent user-specific path:
```erb
<%
# Always use the full user-specific path for consistency
base_path = "/u/#{@target_user.handle}/settings/webhooks"
-%>
```

This eliminates the need for redirect routes in issue #1 (alternative approach).

---

### 2.3 Fix Webhook#path Method

**Issue**: #5 - Returns incorrect path for user webhooks

**Files to modify**:
- `app/models/webhook.rb`

**Implementation**:
Change line ~47 from:
```ruby
"/u/#{tu&.handle}/webhooks"
```
To:
```ruby
"/u/#{tu&.handle}/settings/webhooks"
```

**Tests to add**:
- Update existing `path returns user path for user webhooks` test to expect the correct path

---

## Phase 3: Medium Priority Improvements

### 3.1 Address Race Condition in Rate Limiting

**Issue**: #6 - Non-atomic rate limit check

**Files to modify**:
- `app/jobs/reminder_delivery_job.rb`

**Option A: Accept the edge case** (Recommended for now)
- Add a comment documenting the known limitation
- The job runs on a cron schedule and concurrent delivery for the same user is unlikely
- Monitor in production and add distributed locking if issues arise

**Option B: Add pessimistic locking**
```ruby
# Wrap the rate check and update in a transaction with row locking
NotificationRecipient.transaction do
  recent_deliveries = NotificationRecipient
    .lock("FOR UPDATE")
    .where(...)
    .count
  # ... rest of logic
end
```

**Option C: Use Redis-based rate limiting**
- Use `Redis.incr` with TTL for a distributed rate limit counter
- More complex but fully race-condition-safe

---

### 3.2 Add HTML Views for User Webhooks

**Issue**: #7 - Only markdown views exist

**Files to create**:
- `app/views/user_webhooks/index.html.erb`
- `app/views/user_webhooks/actions_index.html.erb` (optional)

**Implementation**:
Create HTML templates matching the style of other settings pages. Use the existing `settings.html.erb` and `superagent_webhooks` views as patterns.

```erb
<h1>Webhooks for <%= @target_user.handle %></h1>

<% if @target_user != @current_user %>
  <p class="notice">You are managing webhooks for <strong><%= @target_user.name %></strong>.</p>
<% end %>

<% if @webhooks.empty? %>
  <p>No webhooks configured.</p>
  <p>Webhooks allow you to receive notifications at an external URL.</p>
<% else %>
  <table>
    <tr>
      <th>Name</th>
      <th>URL</th>
      <th>Events</th>
      <th>Status</th>
      <th>Actions</th>
    </tr>
    <% @webhooks.each do |webhook| %>
      <tr>
        <td><%= webhook.name %></td>
        <td><code><%= truncate(webhook.url, length: 40) %></code></td>
        <td><%= webhook.events.join(", ") %></td>
        <td><%= webhook.enabled? ? "Enabled" : "Disabled" %></td>
        <td>
          <%= button_to 'Delete', "#{@target_user.path}/settings/webhooks/actions/delete?id=#{webhook.truncated_id}", method: :post, data: { confirm: "Delete this webhook?" } %>
        </td>
      </tr>
    <% end %>
  </table>
<% end %>

<h2>Create Webhook</h2>
<%= form_with url: "#{@target_user.path}/settings/webhooks/actions/create", method: :post do |f| %>
  <div>
    <%= f.label :name, "Name (optional)" %>
    <%= f.text_field :name %>
  </div>
  <div>
    <%= f.label :url, "Webhook URL" %>
    <%= f.text_field :url, required: true %>
  </div>
  <%= f.submit "Create Webhook" %>
<% end %>
```

---

### 3.3 Add Edit Webhook Action (Optional)

**Issue**: #8 - No way to edit webhooks

**Files to modify**:
- `app/controllers/user_webhooks_controller.rb`
- `app/services/actions_helper.rb`
- `config/routes.rb`

**Implementation**:
1. Add routes:
```ruby
get 'settings/webhooks/actions/update' => 'user_webhooks#describe_update', on: :member
post 'settings/webhooks/actions/update' => 'user_webhooks#execute_update', on: :member
```

2. Add controller methods following the pattern of `describe_create`/`execute_create`

3. Add to `ActionsHelper::ACTION_DEFINITIONS`:
```ruby
"update_user_webhook" => {
  description: "Update a user webhook",
  params_string: "(id, url, name, events, enabled)",
  params: [
    { name: "id", type: "string", required: true, description: "The webhook ID" },
    { name: "url", type: "string", description: "The webhook URL" },
    { name: "name", type: "string", description: "The webhook name" },
    { name: "events", type: "array", description: "Event types to subscribe to" },
    { name: "enabled", type: "boolean", description: "Whether the webhook is active" },
  ],
}
```

**Note**: This could be deferred if the delete-and-recreate workflow is acceptable.

---

### 3.4 Fix ReminderService Tenant User Lookup

**Issue**: #9 - May use wrong tenant's notification preferences

**Files to modify**:
- `app/services/reminder_service.rb`

**Implementation**:
Change line ~40 from:
```ruby
channels = user.tenant_user&.notification_channels_for("reminder") || ["in_app"]
```
To:
```ruby
tenant = Tenant.find(Tenant.current_id)
tenant_user = user.tenant_users.find_by(tenant: tenant)
channels = tenant_user&.notification_channels_for("reminder") || ["in_app"]
```

Or add a helper method to User:
```ruby
# In user.rb
def tenant_user_for(tenant)
  tenant_users.find_by(tenant: tenant)
end

# In reminder_service.rb
tenant = Tenant.find(Tenant.current_id)
channels = user.tenant_user_for(tenant)&.notification_channels_for("reminder") || ["in_app"]
```

---

## Phase 4: Low Priority Polish

### 4.1 Add Sorbet Types to Controllers

**Issue**: #10 - Controllers use `# typed: false`

**Files to modify**:
- `app/controllers/notifications_controller.rb`
- `app/controllers/user_webhooks_controller.rb`

**Implementation**:
1. Change header to `# typed: true`
2. Add `extend T::Sig` and method signatures
3. Run `srb tc` to verify

**Defer**: This is a nice-to-have and can be done in a separate PR.

---

### 4.2 Improve Time Parsing Strictness

**Issue**: #11 - Lenient parsing could confuse users

**Files to modify**:
- `app/controllers/notifications_controller.rb`

**Implementation**:
Replace the fallback `Time.parse` with more explicit validation:

```ruby
def parse_scheduled_time(value)
  return nil if value.blank?

  # Try ISO 8601
  if value.match?(/^\d{4}-\d{2}-\d{2}/)
    return Time.iso8601(value).utc rescue nil
  end

  # Try Unix timestamp
  if value.match?(/^\d{9,10}$/)
    return Time.at(value.to_i).utc
  end

  # Try relative time (1h, 2d, 1w, 30m)
  if (match = value.match(/^(\d+)([mhdw])$/i))
    # ... existing relative time logic
  end

  # No fallback - return nil for unrecognized formats
  nil
end
```

Then in the controller action, return an error for nil:
```ruby
scheduled_time = parse_scheduled_time(params[:scheduled_for])
if scheduled_time.nil?
  return render_error("Invalid scheduled_for format. Use ISO 8601, Unix timestamp, or relative time (1h, 2d, 1w)")
end
```

---

### 4.3 Document Rate-Limited Reminders Behavior

**Issue**: #12 - No retry mechanism

**Implementation**:
Add a comment in `reminder_delivery_job.rb` documenting the behavior:

```ruby
# Rate-limited reminders:
# - When a user exceeds MAX_DELIVERIES_PER_USER_PER_MINUTE, excess reminders
#   are marked as "rate_limited" and not delivered.
# - These are NOT automatically retried. Manual intervention or a separate
#   retry job would be needed.
# - Consider adding a scheduled job to retry rate_limited reminders after
#   a cooldown period if this becomes an issue in production.
```

Also document in the plan file that this is a known limitation.

---

### 4.4 Fix Unread Count for Scheduled Reminders

**Issue**: #13 - Scheduled reminders increase unread count

**Files to investigate**:
- `app/services/notification_service.rb` (or wherever `unread_count_for` is defined)
- `app/controllers/notifications_controller.rb`

**Implementation**:
Modify the unread count query to exclude scheduled (future) reminders:

```ruby
def self.unread_count_for(user)
  NotificationRecipient
    .where(user: user)
    .unread
    .immediate  # Add this scope to exclude scheduled reminders
    .count
end
```

The `immediate` scope already exists in `NotificationRecipient`:
```ruby
scope :immediate, -> { where(scheduled_for: nil) }
```

**Alternative**: Only exclude reminders that are `scheduled_for > Time.current`:
```ruby
.where("scheduled_for IS NULL OR scheduled_for <= ?", Time.current)
```

---

## Implementation Order

### Batch 1: Critical (Do First)
1. Fix `/settings/webhooks/actions/*` routes (1.1)
2. Fix test failures (1.2)

### Batch 2: High Priority
3. Add webhooks link to settings (2.1)
4. Fix view template paths (2.2)
5. Fix Webhook#path method (2.3)

### Batch 3: Medium Priority
6. Document/address race condition (3.1)
7. Add HTML views for webhooks (3.2)
8. Fix tenant_user lookup (3.4)
9. (Optional) Add edit webhook action (3.3)

### Batch 4: Low Priority (Can defer)
10. Improve time parsing (4.2)
11. Fix unread count (4.4)
12. Document rate limiting (4.3)
13. Add Sorbet types (4.1)

---

## Testing Checklist

After implementing fixes, verify:

- [ ] Full test suite passes (`./scripts/run-tests.sh`)
- [ ] Sorbet type check passes (`bundle exec srb tc`)
- [ ] RuboCop passes (`bundle exec rubocop`)

### Manual Testing via MCP Server

- [ ] Navigate to `/notifications` - see scheduled reminders section
- [ ] Create reminder with relative time (`1h`) - works
- [ ] Create reminder with ISO 8601 time - works
- [ ] Delete reminder - works
- [ ] Navigate to `/settings/webhooks` - redirects correctly
- [ ] Create webhook via `/settings/webhooks/actions/create` - works
- [ ] Navigate to `/u/:handle/settings` - shows webhooks link
- [ ] Navigate to `/whoami` without auth - shows "not logged in" message

---

## Estimated Effort

| Phase | Issues | Estimated Time |
|-------|--------|----------------|
| Phase 1 | 1.1, 1.2 | 1-2 hours |
| Phase 2 | 2.1, 2.2, 2.3 | 30 minutes |
| Phase 3 | 3.1-3.4 | 2-3 hours |
| Phase 4 | 4.1-4.4 | 1-2 hours |

**Total**: 4-7 hours

---

## Approval Criteria

The feature is ready for merge when:

1. ✅ All critical issues (Phase 1) are resolved
2. ✅ All high priority issues (Phase 2) are resolved
3. ✅ Full test suite passes
4. ✅ Manual testing checklist passes
5. ⬜ Medium/low priority issues documented as follow-up work (optional)
