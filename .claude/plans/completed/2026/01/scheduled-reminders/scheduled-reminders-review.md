# Scheduled Reminders Code Review

**Date**: 2026-01-23
**Reviewer**: Claude (Code Review Agent)
**Feature**: Scheduled Reminders + User-Level Webhooks

---

## Summary

This document tracks issues identified during code review of the scheduled reminders feature. The implementation is comprehensive and well-tested, with the core reminder functionality working correctly. However, several issues need to be addressed before the feature is production-ready.

---

## Critical Issues

### 1. Missing `/settings/webhooks/actions/*` Routes (Bug)

**Location**: [config/routes.rb](config/routes.rb), [user_webhooks/index.md.erb](app/views/user_webhooks/index.md.erb)

**Problem**: The view template uses `/settings/webhooks/actions/create` and `/settings/webhooks/actions/delete` as links for the current user, but these routes don't exist. Only `/settings` and `/settings/webhooks` redirect to the user-specific paths.

**Impact**: Users cannot access webhook action pages via the `/settings/webhooks/actions/*` URLs shown in the markdown UI. The MCP server returns 404 errors.

**Evidence**:
```erb
<%
base_path = @target_user == @current_user ? "/settings/webhooks" : "/u/#{@target_user.handle}/webhooks"
-%>
...
* [`create(...)`](<%= base_path %>/actions/create) - Create a new webhook
```

When `base_path` is `/settings/webhooks`, the link becomes `/settings/webhooks/actions/create`, which 404s.

**Fix Options**:
- **Option A**: Add redirect routes for `/settings/webhooks/actions/*` paths
- **Option B**: Change the view to always use the user-specific path `/u/:handle/settings/webhooks`

**Priority**: Critical - Feature is broken for markdown UI

---

### 2. Test Failures in Existing Tests

**Location**: [test/controllers/whoami_controller_test.rb](test/controllers/whoami_controller_test.rb), [test/controllers/motto_controller_test.rb](test/controllers/motto_controller_test.rb)

**Problem**: 9 test failures and 1 error in the full test suite:

**Whoami Controller (2 failures, 1 error)**:
- `test_unauthenticated_user_can_access_whoami_page` - Redirects to login instead of showing page
- `test_unauthenticated_markdown_whoami_shows_not_logged_in_message` - Same issue
- `test_whoami_shows_subagent_parent_info` - `unknown attribute 'scope' for ApiToken`

**Motto Controller (7 failures)**:
- All tests fail because unauthenticated users are redirected to login

**Impact**: CI will fail. These may be pre-existing issues or regressions from the current changes.

**Investigation Needed**:
- Check if `require_login` was accidentally added to `/whoami` and `/motto` controllers
- Fix the ApiToken test that references a non-existent `scope` attribute

**Priority**: Critical - Blocks CI

---

## High Priority Issues

### 3. Missing Webhooks Link in Settings Page

**Location**: [settings.html.erb](app/views/users/settings.html.erb), [settings.md.erb](app/views/users/settings.md.erb)

**Problem**: The user settings page has no navigation link to the webhooks section. Users have no way to discover that user webhooks exist.

**Impact**: Poor discoverability. Users must know the URL `/u/:handle/settings/webhooks` to find the feature.

**Fix**: Add a "Webhooks" section or link in the settings page actions list:
```erb
* [Webhooks](<%= @settings_user.path %>/settings/webhooks) - Manage personal webhooks for reminders
```

**Priority**: High - Feature discoverability

---

### 4. View Template Path Inconsistency for User Webhooks

**Location**: [user_webhooks/index.md.erb](app/views/user_webhooks/index.md.erb)

**Problem**: The `base_path` logic is confusing and leads to the routing bug in issue #1:

```erb
base_path = @target_user == @current_user ? "/settings/webhooks" : "/u/#{@target_user.handle}/webhooks"
```

Also, the path for "other user" case is `/u/#{@target_user.handle}/webhooks` but should be `/u/#{@target_user.handle}/settings/webhooks`.

**Fix**: Use consistent user-specific paths:
```erb
base_path = "/u/#{@target_user.handle}/settings/webhooks"
```

**Priority**: High - Part of bug #1

---

### 5. Webhook Path Method Returns Incorrect Path

**Location**: [webhook.rb:42-49](app/models/webhook.rb#L42-L49)

**Problem**: The `path` method for user webhooks returns `/u/#{handle}/webhooks` instead of `/u/#{handle}/settings/webhooks`:

```ruby
def path
  if user_id.present?
    tu = TenantUser.find_by(tenant_id: tenant_id, user_id: user_id)
    "/u/#{tu&.handle}/webhooks"  # Wrong - missing /settings/
  else
    # ...
  end
end
```

**Impact**: Any code that uses `webhook.path` for user webhooks will generate incorrect URLs.

**Fix**: Change to `/u/#{tu&.handle}/settings/webhooks`

**Priority**: High - Incorrect URLs

---

## Medium Priority Issues

### 6. Potential Race Condition in ReminderDeliveryJob

**Location**: [reminder_delivery_job.rb:44-57](app/jobs/reminder_delivery_job.rb#L44-L57)

**Problem**: The rate limiting check and update are not atomic:

```ruby
recent_deliveries = NotificationRecipient
  .where(...)
  .where("notification_recipients.delivered_at > ?", 1.minute.ago)
  .count

if recent_deliveries >= MAX_DELIVERIES_PER_USER_PER_MINUTE
  reminders.each { |nr| nr.update!(status: "rate_limited") }
  return
end
```

If multiple job workers run concurrently, they could both pass the check before either marks reminders as rate_limited.

**Impact**: Could allow more than `MAX_DELIVERIES_PER_USER_PER_MINUTE` in edge cases.

**Mitigation**: The job runs on a cron schedule (every minute) and the rate limit is per-user, so concurrent issues are unlikely but possible.

**Fix Options**:
- Use pessimistic locking on the rate limit check
- Use Redis-based distributed rate limiting
- Accept the edge case as unlikely

**Priority**: Medium - Edge case only

---

### 7. Missing HTML Views for User Webhooks

**Location**: [app/views/user_webhooks/](app/views/user_webhooks/)

**Problem**: Only markdown views exist for user webhooks (`index.md.erb`). No HTML views exist, so browser users will see raw markdown or errors.

**Impact**: Feature is only usable via markdown API, not through regular browser UI.

**Fix**: Create `index.html.erb` with proper HTML template matching the pattern of other settings pages.

**Priority**: Medium - Affects browser users

---

### 8. No Edit Webhook Action for User Webhooks

**Location**: [user_webhooks_controller.rb](app/controllers/user_webhooks_controller.rb), [actions_helper.rb:339-354](app/services/actions_helper.rb#L339-L354)

**Problem**: User webhooks only have create and delete actions, but no update/edit action. Studio webhooks have `update_webhook` but user webhooks don't.

**Impact**: Users must delete and recreate webhooks to change their URL or events.

**Note**: The plan document explicitly says "no edit - delete and recreate" for reminders, but this limitation on webhooks may be unintended.

**Priority**: Medium - Missing functionality

---

### 9. ReminderService Uses `user.tenant_user` Without Specifying Tenant

**Location**: [reminder_service.rb:40](app/services/reminder_service.rb#L40)

**Problem**: The code calls `user.tenant_user` which relies on the current tenant context, but if the user belongs to multiple tenants, this could return the wrong tenant_user.

```ruby
channels = user.tenant_user&.notification_channels_for("reminder") || ["in_app"]
```

**Impact**: Could potentially use notification preferences from the wrong tenant.

**Fix**: Use the tenant from the method's context:
```ruby
channels = user.tenant_user_for(tenant)&.notification_channels_for("reminder") || ["in_app"]
```

**Priority**: Medium - Edge case for multi-tenant users

---

## Low Priority Issues

### 10. Sorbet Type Signature Issues in Controllers

**Location**: [notifications_controller.rb:1](app/controllers/notifications_controller.rb#L1), [user_webhooks_controller.rb:1](app/controllers/user_webhooks_controller.rb#L1)

**Problem**: These controllers are marked `# typed: false` which disables Sorbet type checking.

**Impact**: No type safety for these controllers.

**Recommendation**: Consider upgrading to `# typed: true` and adding signatures.

**Priority**: Low - Consistency improvement

---

### 11. `parse_scheduled_time` Fallback Could Be Confusing

**Location**: [notifications_controller.rb:217-233](app/controllers/notifications_controller.rb#L217-L233)

**Problem**: The fallback case uses `Time.parse(value).utc` which may parse unexpected formats:

```ruby
else
  # Try parsing as a general datetime string
  Time.parse(value).utc
end
```

For example, `Time.parse("January")` returns the first of January in the current year.

**Impact**: Users might accidentally create reminders at unexpected times.

**Fix**: Consider being more strict about accepted formats or adding validation for the parsed result.

**Priority**: Low - Edge case

---

### 12. No Test for Rate-Limited Reminders Retry

**Location**: [reminder_delivery_job.rb](app/jobs/reminder_delivery_job.rb), [reminder_delivery_job_test.rb](test/jobs/reminder_delivery_job_test.rb)

**Problem**: When reminders are marked as `rate_limited`, there's no mechanism or test showing how they get retried.

**Impact**: Rate-limited reminders may stay in that state forever.

**Consideration**: The plan document says "Does not auto-retry. Manual intervention or separate retry job could be added later if needed."

**Priority**: Low - Known limitation, documented

---

### 13. Scheduled Reminders Count Towards Unread Count

**Location**: Manual testing via MCP

**Observation**: When a reminder is created, the unread notification count increases immediately (from 1 to 2 in testing), even though the reminder hasn't triggered yet.

**Expected Behavior**: The unread count should probably only include delivered notifications, not scheduled reminders.

**Investigation Needed**: Check if this is intentional or a bug in how `NotificationService.unread_count_for` calculates the count.

**Priority**: Low - UX polish

---

## Suggested Test Additions

### Integration Tests Needed

1. **Test webhook execution via markdown API** - End-to-end test of creating webhook, creating reminder, running job, and verifying webhook delivery
2. **Test rate limiting in ReminderDeliveryJob** - More thorough test of rate limit behavior
3. **Test natural language time parsing edge cases** - Test edge cases like "January", "noon", "5pm"

### Missing Test Coverage

1. Test that `/settings/webhooks` redirects correctly (currently broken)
2. Test that user webhooks appear in the correct tenant only
3. Test that reminder delivery correctly triggers `reminders.delivered` event and webhook

---

## Summary of Required Changes

### Must Fix Before Merge (Critical/High)

| # | Issue | Priority | Effort |
|---|-------|----------|--------|
| 1 | Missing `/settings/webhooks/actions/*` routes | Critical | Low |
| 2 | Test failures in whoami/motto controllers | Critical | Medium |
| 3 | Missing webhooks link in settings page | High | Low |
| 4 | View template path inconsistency | High | Low |
| 5 | Webhook.path returns incorrect path | High | Low |

### Should Fix (Medium)

| # | Issue | Priority | Effort |
|---|-------|----------|--------|
| 6 | Race condition in rate limiting | Medium | Medium |
| 7 | Missing HTML views for user webhooks | Medium | Medium |
| 8 | No edit webhook action | Medium | Low |
| 9 | ReminderService tenant_user lookup | Medium | Low |

### Nice to Have (Low)

| # | Issue | Priority | Effort |
|---|-------|----------|--------|
| 10 | Sorbet typing in controllers | Low | Medium |
| 11 | Strict time parsing | Low | Low |
| 12 | Rate-limited retry mechanism | Low | Medium |
| 13 | Unread count includes scheduled | Low | Low |

---

## Approval Status

**Status**: 🔴 Changes Required

The implementation is solid overall, but the critical routing bug (#1) and test failures (#2) must be fixed before merging. The high-priority issues should also be addressed as they affect usability.
