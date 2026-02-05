# Plan: Group Notifications by Superagent with Collapsible Accordions

## Goal
Display notifications grouped by superagent (studio) in collapsible accordions, with a "dismiss all" button for each group.

## Key Insights
- **Relationship chain**: Superagent → Event → Notification → NotificationRecipient
- **Existing accordion pattern**: Uses `<details>/<summary>` HTML with `.pulse-accordion*` CSS classes
- **Reminders**: No event/superagent - shown in their own "Reminders" accordion section

## Files to Modify

### 1. Controller: `app/controllers/notifications_controller.rb`
- Group `@notification_recipients` by superagent after loading
- Pass grouped data to view: `@notifications_by_superagent`
- Add `describe_dismiss_for_superagent` and `execute_dismiss_for_superagent` actions

### 2. Service: `app/services/notification_service.rb`
- Add `dismiss_all_for_superagent(user, tenant:, superagent_id:)` method
- Uses join on events to filter by superagent

### 3. Routes: `config/routes.rb`
- Add routes for `dismiss_for_superagent` action

### 4. Actions Helper: `app/services/actions_helper.rb`
- Add `dismiss_for_superagent` action definition with `superagent_id` param
- Add to `/notifications` route actions

### 5. HTML View: `app/views/notifications/index.html.erb`
- Replace flat list with accordion groups
- Each group: superagent name header + dismiss all button + list of notifications
- Use existing `.pulse-accordion` CSS pattern
- "Other" group for notifications without superagent (reminders, etc.)

### 6. Markdown View: `app/views/notifications/index.md.erb`
- Add `## Studio: {name}` sections
- Include `dismiss_for_superagent` action links per group

### 7. JavaScript: `app/javascript/controllers/notification_actions_controller.ts`
- Add `dismissForSuperagent(event)` method
- Read `data-superagent-id` from button
- POST to `/notifications/actions/dismiss_for_superagent`
- Remove all notifications in that accordion group from DOM

### 8. Tests
- Controller test for `dismiss_for_superagent` action
- Service test for `dismiss_all_for_superagent`
- Update manual test checklist

## Implementation Details

### Grouping Logic (Controller)
**Note**: Due to default_scope on Event model filtering by superagent_id, we cannot use
`nr.notification.event&.superagent` directly. Instead, we query the data in separate steps
using `unscoped` to bypass the default_scope:

```ruby
# Query event_id directly from notifications table (bypasses Event default_scope)
notification_ids = @notification_recipients.map(&:notification_id)
notification_event_map = Notification.unscoped.where(id: notification_ids).pluck(:id, :event_id).to_h

# Query superagent_id from events (bypasses default_scope)
event_ids = notification_event_map.values.compact
event_superagent_map = Event.unscoped.where(id: event_ids).pluck(:id, :superagent_id).to_h

# Load superagents
superagent_ids = event_superagent_map.values.compact.uniq
superagents = Superagent.unscoped.where(id: superagent_ids).index_by(&:id)

# Build lookup and group
@superagent_for_nr = {}
@notification_recipients.each do |nr|
  event_id = notification_event_map[nr.notification_id]
  superagent_id = event_id ? event_superagent_map[event_id] : nil
  @superagent_for_nr[nr.id] = superagent_id ? superagents[superagent_id] : nil
end

@notifications_by_superagent = @notification_recipients.group_by do |nr|
  @superagent_for_nr[nr.id]
end
```

### Service Method
**Note**: Using `joins(notification: :event)` is affected by Event's default_scope.
Instead, we query in separate steps with `unscoped`:

```ruby
def self.dismiss_all_for_superagent(user, tenant:, superagent_id:)
  # Bypass default_scope by querying directly with unscoped
  event_ids = Event.unscoped.where(superagent_id: superagent_id, tenant: tenant).pluck(:id)
  notification_ids = Notification.unscoped.where(event_id: event_ids, tenant: tenant).pluck(:id)

  NotificationRecipient
    .where(user: user, tenant: tenant)
    .where(notification_id: notification_ids)
    .in_app.unread.not_scheduled
    .update_all(dismissed_at: Time.current, status: "dismissed")
end
```

### Accordion HTML Structure
```erb
<% @notifications_by_superagent.each do |superagent, recipients| %>
  <details class="pulse-accordion" open data-superagent-group="<%= superagent&.id || 'reminders' %>">
    <summary class="pulse-accordion-header">
      <span class="pulse-accordion-title">
        <%= superagent&.name || "Reminders" %>
        (<%= recipients.size %>)
      </span>
      <button data-action="click->notification-actions#dismissForSuperagent"
              data-superagent-id="<%= superagent&.id || 'reminders' %>">
        Dismiss all
      </button>
    </summary>
    <div class="pulse-accordion-content">
      <!-- notification items -->
    </div>
  </details>
<% end %>
```

### Service Method for Reminders (no superagent)
```ruby
def self.dismiss_all_reminders(user, tenant:)
  NotificationRecipient
    .joins(:notification)
    .where(user: user, tenant: tenant)
    .where(notifications: { event_id: nil })  # No event = reminders
    .in_app.unread.not_scheduled
    .update_all(dismissed_at: Time.current, status: "dismissed")
end
```

## Verification
1. Run `./scripts/run-tests.sh` - all tests pass
2. Run `docker compose exec web bundle exec rubocop` on changed files
3. Manual test in browser:
   - Navigate to `/notifications`
   - Verify notifications grouped by studio in accordions
   - Verify accordions collapse/expand
   - Click "Dismiss all" for one group - only that group's notifications dismissed
   - Verify global "Dismiss all" still works
