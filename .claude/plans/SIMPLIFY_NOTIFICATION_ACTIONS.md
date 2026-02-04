# Plan: Simplify Notification Actions to Dismiss Only

## Goal
Remove "mark as read" functionality and keep only "dismiss". Add a bulk "dismiss all" action.

## Files to Modify

### 1. Model: `app/models/notification_recipient.rb`
- Remove `read!` method (lines 28-30)
- Remove `read?` method (lines 42-45)
- Update `unread` scope (line 14) to only check `dismissed_at: nil` (remove `read_at: nil`)

### 2. Service: `app/services/notification_service.rb`
- Rename `mark_all_read_for` to `dismiss_all_for` (lines 50-59)
- Change implementation to set `dismissed_at` and `status: "dismissed"` instead of `read_at` and `status: "read"`

### 3. Actions Helper: `app/services/actions_helper.rb`
- Remove `mark_read` action definition (lines 396-403)
- Rename `mark_all_read` to `dismiss_all` (lines 412-417), update description
- Update `/notifications` route actions (lines 707, 709) to remove `mark_read` and rename `mark_all_read`

### 4. Controller: `app/controllers/notifications_controller.rb`
- Remove `describe_mark_read` and `execute_mark_read` methods (lines 40-71)
- Rename `describe_mark_all_read` → `describe_dismiss_all` (lines 106-108)
- Rename `execute_mark_all_read` → `execute_dismiss_all` (lines 110-124)
- Update to call `NotificationService.dismiss_all_for`

### 5. Routes: `config/routes.rb`
- Remove mark_read routes (lines 107-108)
- Rename mark_all_read routes to dismiss_all (lines 111-112)

### 6. Views

**HTML: `app/views/notifications/index.html.erb`**
- Remove `read?` conditionals for styling (line 76)
- Remove unread indicator conditional (lines 78-80)
- Remove "mark as read" button (lines 97-99)
- Update "Mark all read" button to "Dismiss all"

**Markdown: `app/views/notifications/index.md.erb`**
- Remove `read?` status column (line 23)
- Remove `mark_read` action link
- Rename `mark_all_read` to `dismiss_all` in actions list (lines 29, 31)

### 7. Tests

**Model test: `test/models/notification_recipient_test.rb`**
- Remove `read! marks recipient as read` test (lines 76-100)
- Update `unread` scope test to only expect `dismissed_at: nil` check

**Controller test: `test/controllers/notifications_controller_test.rb`**
- Remove `mark_read marks notification as read` test (lines 84-111)
- Remove `mark_read returns error for non-existent notification` test (lines 113-121)
- Rename/update `mark_all_read` tests to `dismiss_all` (lines 152-186, 294-312)

**Service test: `test/services/notification_service_test.rb`**
- Rename `mark_all_read_for` tests to `dismiss_all_for` (lines 98-128, 165-199)
- Update expectations to check `dismissed_at` instead of `read_at`

## Database Consideration
The `read_at` column and `"read"` status will become unused. We can leave them for now (no migration needed) or add a cleanup migration later.

## Verification
1. Run `./scripts/run-tests.sh` to ensure all tests pass
2. Run `docker compose exec web bundle exec rubocop` for lint check
3. Manual test: Navigate to `/notifications` in browser, verify only "dismiss" and "dismiss all" actions appear
