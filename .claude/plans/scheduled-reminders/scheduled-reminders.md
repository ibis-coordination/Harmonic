# Scheduled Reminders Plan

**Status: ✅ COMPLETED** (2026-01-22)

All phases implemented and tested:
- Phase A: User-Level Webhooks
- Phase B: Scheduled Reminders
- Phase C: Settings Path Consolidation (moved webhooks to `/u/:handle/settings/webhooks`)

---

Reminders are scheduled notifications that do not appear until their scheduled time. This extends the existing notifications system rather than creating a new model.

## Goals

1. Allow users (especially AI agents) to create notifications for their future selves
2. Show scheduled reminders in a dedicated section on the notifications page
3. Allow users to view and delete scheduled reminders before they trigger (no edit - delete and recreate)
4. Integrate with `/whoami` so agents see their upcoming reminders
5. **Trigger webhooks when reminders are delivered** — This is the key feature for AI agents who need to "wake up" and take action at scheduled times

## Design Decisions

### Approach: Extend NotificationRecipient

Rather than adding `scheduled_for` to the Notification model, we add it to **NotificationRecipient**. This allows:
- A single notification to be scheduled differently for different recipients (future flexibility)
- Scheduled reminders to use the existing notification infrastructure
- Clean separation: Notification holds content, NotificationRecipient holds delivery timing

### New Notification Type: "reminder"

Add `"reminder"` to the list of notification types. This allows:
- User preferences for reminders (in_app, email disabled by default)
- Filtering reminders from other notifications if desired
- Clear semantic meaning

### Batching by Timestamp

When multiple reminders are scheduled for the exact same time, they are batched into a single webhook/notification:
- Reminders with identical `scheduled_for` values are grouped
- One webhook event contains all reminders in the batch
- Prevents blast of many webhooks/emails at the same instant

### User-Level Webhooks (New Feature)

Current webhooks are studio-level or tenant-level. Reminders are personal, so we need user-level webhooks:
- Add `user_id` column to webhooks table
- A webhook with `user_id` set only receives events for that user
- Users can configure their own webhook endpoints
- Parents can configure webhook endpoints for their subagents

### Events for Webhook Integration

When a reminder is delivered, we create a `reminders.delivered` event (note: plural, because of batching). This is critical for AI agents who rely on webhooks to "wake up" and take action.

**Event flow:**
1. User creates reminder → No event (just stores Notification + NotificationRecipient)
2. Reminder becomes due → `ReminderDeliveryJob` batches by timestamp and creates `reminders.delivered` event
3. Event triggers `WebhookDispatcher` → Webhook sent to user's configured endpoint
4. AI agent receives webhook → Agent wakes up and can take action

**Webhook payload for batched reminders:**
```json
{
  "type": "reminders.delivered",
  "actor": { "id": "...", "handle": "agent-name" },
  "data": {
    "reminders": [
      { "id": "...", "title": "Check on PR", "body": "...", "scheduled_for": "..." },
      { "id": "...", "title": "Follow up", "body": null, "scheduled_for": "..." }
    ],
    "count": 2
  }
}
```

This enables agents to schedule future actions by creating reminders that will trigger webhooks at the specified time.

## Database Changes

### Migration: Add scheduled_for to notification_recipients

```ruby
class AddScheduledForToNotificationRecipients < ActiveRecord::Migration[7.0]
  def change
    add_column :notification_recipients, :scheduled_for, :datetime
    add_index :notification_recipients, :scheduled_for, where: "scheduled_for IS NOT NULL"
  end
end
```

### Migration: Add event_id nullable constraint (if needed)

Check if `event_id` is already nullable. If not:

```ruby
class MakeEventIdNullableOnNotifications < ActiveRecord::Migration[7.0]
  def change
    change_column_null :notifications, :event_id, true
  end
end
```

### Migration: Add user_id to webhooks

```ruby
class AddUserIdToWebhooks < ActiveRecord::Migration[7.0]
  def change
    add_reference :webhooks, :user, type: :uuid, foreign_key: true, index: true
  end
end
```

## Model Changes

### Webhook

```ruby
# Add user association
belongs_to :user, optional: true

# Add scope for user-level webhooks
scope :for_user, ->(user) { where(user_id: user.id) }

# Validation: user webhooks should not have superagent_id
validate :user_or_superagent_not_both

private

def user_or_superagent_not_both
  if user_id.present? && superagent_id.present?
    errors.add(:base, "Webhook cannot be both user-level and studio-level")
  end
end
```

### NotificationRecipient

```ruby
# Add scopes
scope :scheduled, -> { where.not(scheduled_for: nil).where("scheduled_for > ?", Time.current) }
scope :due, -> { where.not(scheduled_for: nil).where("scheduled_for <= ?", Time.current) }
scope :immediate, -> { where(scheduled_for: nil) }

# Add method
def scheduled?
  scheduled_for.present? && scheduled_for > Time.current
end

def due?
  scheduled_for.present? && scheduled_for <= Time.current
end
```

### Notification

```ruby
# Add to NOTIFICATION_TYPES
NOTIFICATION_TYPES = %w[mention comment participation system reminder].freeze

# Ensure event is optional
belongs_to :event, optional: true
```

### TenantUser (notification preferences)

Add default preferences for reminders (email disabled by default):

```ruby
DEFAULT_NOTIFICATION_PREFERENCES = {
  "mention" => { "in_app" => true, "email" => true },
  "comment" => { "in_app" => true, "email" => false },
  "participation" => { "in_app" => true, "email" => false },
  "system" => { "in_app" => true, "email" => true },
  "reminder" => { "in_app" => true, "email" => false },  # NEW - email disabled by default
}
```

Note: Email is disabled by default because reminders are primarily for AI agents who receive webhooks, not emails. Users can enable email if desired.

## Service Changes

### ReminderService (new)

```ruby
class ReminderService
  def self.create!(user:, title:, body: nil, scheduled_for:, url: nil)
    tenant = Tenant.current

    notification = Notification.create!(
      tenant: tenant,
      notification_type: "reminder",
      title: title,
      body: body&.truncate(200),
      url: url,
    )

    channels = user.tenant_user_for(tenant)&.notification_channels_for("reminder") || ["in_app"]

    channels.each do |channel|
      NotificationRecipient.create!(
        notification: notification,
        user: user,
        channel: channel,
        status: "pending",
        scheduled_for: scheduled_for,
      )
    end

    notification
  end

  def self.delete!(notification_recipient)
    notification = notification_recipient.notification
    notification_recipient.destroy!

    # If no recipients left, destroy the notification too
    notification.destroy! if notification.notification_recipients.empty?
  end

  def self.scheduled_for(user)
    NotificationRecipient
      .joins(:notification)
      .where(user: user, channel: "in_app")
      .where(notifications: { notification_type: "reminder" })
      .scheduled
      .includes(:notification)
      .order(:scheduled_for)
  end
end
```

### NotificationService modifications

Modify `create_and_deliver!` to handle scheduled notifications:

```ruby
def self.create_and_deliver!(event:, recipient:, notification_type:, title:, body: nil, url: nil, channels: ["in_app"], scheduled_for: nil)
  # ... existing notification creation ...

  channels.each do |channel|
    nr = NotificationRecipient.create!(
      notification: notification,
      user: recipient,
      channel: channel,
      status: "pending",
      scheduled_for: scheduled_for,  # NEW
    )

    # Only enqueue job if not scheduled for the future
    if scheduled_for.nil? || scheduled_for <= Time.current
      NotificationDeliveryJob.perform_later(nr.id)
    end
  end

  notification
end
```

## Background Job: ReminderDeliveryJob

A periodic job that finds and delivers due reminders. Critically, this job creates an Event to trigger webhooks. Reminders with the same timestamp are batched together.

```ruby
class ReminderDeliveryJob < ApplicationJob
  queue_as :default

  MAX_DELIVERIES_PER_USER_PER_MINUTE = 5

  def perform
    # Group due reminders by user and scheduled_for timestamp
    due_reminders = NotificationRecipient
      .joins(:notification)
      .where(notifications: { notification_type: "reminder" })
      .due
      .where(status: "pending")
      .includes(:notification, :user)
      .limit(100)  # Burst protection
      .order(:scheduled_for)

    # Group by user_id and scheduled_for for batching
    batches = due_reminders.group_by { |nr| [nr.user_id, nr.scheduled_for] }

    batches.each do |(user_id, scheduled_for), reminders|
      deliver_batch(reminders)
    end
  end

  private

  def deliver_batch(reminders)
    return if reminders.empty?

    first = reminders.first
    user = first.user
    tenant = first.notification.tenant

    # Loop prevention: check recent deliveries for this user
    recent_deliveries = NotificationRecipient
      .joins(:notification)
      .where(user: user)
      .where(notifications: { notification_type: "reminder" })
      .where(status: "delivered")
      .where("notification_recipients.delivered_at > ?", 1.minute.ago)
      .count

    if recent_deliveries >= MAX_DELIVERIES_PER_USER_PER_MINUTE
      Rails.logger.warn("Reminder loop detected for user #{user.id}, rate limiting batch")
      reminders.each { |nr| nr.update!(status: "rate_limited") }
      return
    end

    # Set context for event creation
    Tenant.with_current(tenant) do
      # Find a superagent context (use user's default or first available)
      superagent = user.superagent_memberships
        .where(tenant: tenant)
        .where(archived_at: nil)
        .first&.superagent

      unless superagent
        Rails.logger.warn("User #{user.id} has no superagent membership, cannot deliver reminders")
        return
      end

      Superagent.with_current(superagent) do
        # Create single batched event to trigger webhooks
        EventService.record!(
          event_type: "reminders.delivered",
          actor: user,
          subject: first.notification,  # Use first notification as subject
          metadata: {
            reminders: reminders.map do |nr|
              {
                id: nr.notification.id,
                title: nr.notification.title,
                body: nr.notification.body,
                scheduled_for: nr.scheduled_for.iso8601,
              }
            end,
            count: reminders.size,
          }
        )

        # Deliver each notification (in-app)
        reminders.each do |nr|
          NotificationDeliveryJob.perform_now(nr.id)
        end
      end
    end
  end
end
```

Schedule this to run every minute via Sidekiq-Scheduler or similar:

```yaml
# config/sidekiq.yml
:schedule:
  reminder_delivery:
    cron: '* * * * *'
    class: ReminderDeliveryJob
```

## WebhookDispatcher Changes

Modify `find_matching_webhooks` to include user-level webhooks:

```ruby
def self.find_matching_webhooks(event)
  webhooks = Webhook.where(tenant_id: event.tenant_id, enabled: true)

  # For user-specific events (like reminders), also check user-level webhooks
  if event.actor_id.present? && user_scoped_event?(event.event_type)
    webhooks = webhooks.where(
      "superagent_id IS NULL OR superagent_id = ? OR user_id = ?",
      event.superagent_id,
      event.actor_id
    )
  else
    webhooks = webhooks.where(
      "superagent_id IS NULL OR superagent_id = ?",
      event.superagent_id
    )
  end

  webhooks.select { |webhook| webhook.subscribed_to?(event.event_type) }
end

def self.user_scoped_event?(event_type)
  event_type.start_with?("reminder")
end
```

## User Webhook Management

### Routes

All user webhook routes are under `/u/:handle/settings/webhooks`. The `/settings` path redirects to `/u/:handle/settings` for the current user.

```ruby
# User settings redirects (in routes.rb)
get 'settings' => 'users#redirect_to_settings'
get 'settings/webhooks' => 'users#redirect_to_settings_webhooks'

# User/Subagent webhook routes (parent can manage subagent webhooks)
# These are defined as member routes on the users resource
get 'settings/webhooks' => 'user_webhooks#index', on: :member
get 'settings/webhooks/actions' => 'user_webhooks#actions_index', on: :member
get 'settings/webhooks/actions/create' => 'user_webhooks#describe_create', on: :member
post 'settings/webhooks/actions/create' => 'user_webhooks#execute_create', on: :member
get 'settings/webhooks/actions/delete' => 'user_webhooks#describe_delete', on: :member
post 'settings/webhooks/actions/delete' => 'user_webhooks#execute_delete', on: :member
```

**Result**: All routes are accessed via `/u/:handle/settings/webhooks`. Users access their own webhooks at `/u/their-handle/settings/webhooks`, and parents access subagent webhooks at `/u/subagent-handle/settings/webhooks`.

### UserWebhooksController

```ruby
class UserWebhooksController < ApplicationController
  before_action :require_login
  before_action :set_target_user
  before_action :authorize_webhook_management

  def index
    @webhooks = Webhook.for_user(@target_user).where(tenant: current_tenant)

    respond_to do |format|
      format.html { render layout: "application" }
      format.md { render "user_webhooks/index" }
    end
  end

  def execute_create
    url = params[:url]
    events = Array(params[:events]).presence || ["reminders.delivered"]

    if url.blank?
      return render_error("URL is required")
    end

    webhook = Webhook.create!(
      tenant: current_tenant,
      user: @target_user,
      created_by: current_user,
      name: params[:name] || "#{@target_user.handle} webhook",
      url: url,
      events: events,
      enabled: true,
    )

    respond_to do |format|
      format.html { redirect_to settings_webhooks_path, notice: "Webhook created" }
      format.md { render plain: "Webhook created with ID: #{webhook.truncated_id}" }
    end
  end

  def execute_delete
    webhook = Webhook.for_user(@target_user)
      .where(tenant: current_tenant)
      .find_by(truncated_id: params[:id])

    if webhook.nil?
      return render_error("Webhook not found")
    end

    webhook.destroy!

    respond_to do |format|
      format.html { redirect_to settings_webhooks_path, notice: "Webhook deleted" }
      format.md { render plain: "Webhook deleted" }
    end
  end

  private

  def set_target_user
    if params[:handle]
      @target_user = User.find_by!(handle: params[:handle])
    else
      @target_user = current_user
    end
  end

  def authorize_webhook_management
    # User can manage their own webhooks
    return if @target_user == current_user

    # Parent can manage subagent webhooks
    return if @target_user.parent == current_user

    render_error("You don't have permission to manage webhooks for this user", status: :forbidden)
  end
end
```

### Views

**user_webhooks/index.md.erb**

```erb
# Webhooks for <%= @target_user.handle %>

<% if @webhooks.any? %>
| ID | Name | URL | Events | Enabled |
|----|------|-----|--------|---------|
<% @webhooks.each do |webhook| %>
| <%= webhook.truncated_id %> | <%= webhook.name %> | <%= webhook.url.truncate(40) %> | <%= webhook.events.join(", ") %> | <%= webhook.enabled? ? "Yes" : "No" %> |
<% end %>
<% else %>
No webhooks configured.
<% end %>

## Actions

- [Create Webhook](<%= @target_user == current_user ? "/settings/webhooks/actions/create" : "/u/#{@target_user.handle}/webhooks/actions/create" %>)
- [Delete Webhook](<%= @target_user == current_user ? "/settings/webhooks/actions/delete" : "/u/#{@target_user.handle}/webhooks/actions/delete" %>)
```

## Controller Changes

### NotificationsController

Add new actions:

```ruby
# GET /notifications - modify to separate scheduled from delivered
def index
  @notifications = current_user
    .notification_recipients
    .in_app
    .immediate  # Only show non-scheduled
    .where(dismissed_at: nil)
    .includes(:notification)
    .order(created_at: :desc)
    .limit(50)

  @scheduled_reminders = ReminderService.scheduled_for(current_user)

  # ... rest of existing code
end

# GET /notifications/actions/create_reminder
def describe_create_reminder
  respond_to do |format|
    format.md { render plain: reminder_action_description }
  end
end

# POST /notifications/actions/create_reminder
def execute_create_reminder
  title = params[:title]
  body = params[:body]
  scheduled_for = parse_scheduled_time(params[:scheduled_for])

  if title.blank?
    return render_error("Title is required")
  end

  if scheduled_for.nil? || scheduled_for <= Time.current
    return render_error("scheduled_for must be a future time")
  end

  notification = ReminderService.create!(
    user: current_user,
    title: title,
    body: body,
    scheduled_for: scheduled_for,
  )

  respond_to do |format|
    format.html { redirect_to notifications_path, notice: "Reminder scheduled" }
    format.json { render json: { success: true, id: notification.id } }
    format.md { render plain: "Reminder scheduled for #{scheduled_for.strftime('%Y-%m-%d %H:%M')}" }
  end
end

# GET /notifications/actions/delete_reminder
def describe_delete_reminder
  # ...
end

# POST /notifications/actions/delete_reminder
def execute_delete_reminder
  nr = current_user.notification_recipients.find_by(id: params[:id])

  if nr.nil?
    return render_error("Reminder not found")
  end

  ReminderService.delete!(nr)

  respond_to do |format|
    format.html { redirect_to notifications_path, notice: "Reminder deleted" }
    format.json { render json: { success: true } }
    format.md { render plain: "Reminder deleted" }
  end
end

private

def parse_scheduled_time(value)
  return nil if value.blank?

  # Support multiple formats
  case value
  when /^\d+$/ # Unix timestamp
    Time.at(value.to_i)
  when /^\d{4}-\d{2}-\d{2}/ # ISO 8601
    Time.parse(value)
  else
    Chronic.parse(value) # Natural language (requires chronic gem)
  end
rescue ArgumentError, TypeError
  nil
end

def reminder_action_description
  <<~MD
    # Create Reminder

    Schedule a notification for your future self.

    ## Parameters

    | Parameter | Required | Description |
    |-----------|----------|-------------|
    | title | Yes | The reminder text (max 255 chars) |
    | body | No | Additional details (max 200 chars) |
    | scheduled_for | Yes | When to deliver. Accepts: ISO 8601 datetime, Unix timestamp, or natural language like "tomorrow at 9am" |

    ## Examples

    - `scheduled_for=2024-01-15T09:00:00Z` (ISO 8601)
    - `scheduled_for=1705312800` (Unix timestamp)
    - `scheduled_for=tomorrow at 9am` (natural language)
  MD
end
```

## Routes

```ruby
# Add to existing notification routes
get 'notifications/actions/create_reminder' => 'notifications#describe_create_reminder'
post 'notifications/actions/create_reminder' => 'notifications#execute_create_reminder'
get 'notifications/actions/delete_reminder' => 'notifications#describe_delete_reminder'
post 'notifications/actions/delete_reminder' => 'notifications#execute_delete_reminder'
```

## View Changes

### notifications/index.html.erb

Add scheduled reminders section above the notifications list:

```erb
<% if @scheduled_reminders.any? %>
  <section class="scheduled-reminders">
    <h2>Scheduled Reminders</h2>
    <ul>
      <% @scheduled_reminders.each do |nr| %>
        <li>
          <div class="reminder-content">
            <strong><%= nr.notification.title %></strong>
            <% if nr.notification.body.present? %>
              <p><%= nr.notification.body %></p>
            <% end %>
            <time><%= nr.scheduled_for.strftime("%b %d, %Y at %I:%M %p") %></time>
          </div>
          <div class="reminder-actions">
            <%= button_to "Delete",
                notifications_actions_delete_reminder_path(id: nr.id),
                method: :post,
                class: "btn-icon",
                data: { confirm: "Delete this reminder?" } %>
          </div>
        </li>
      <% end %>
    </ul>
  </section>
<% end %>
```

### notifications/index.md.erb

Add scheduled reminders section:

```erb
<% if @scheduled_reminders.any? %>
## Scheduled Reminders

| Scheduled For | Title | Body |
|---------------|-------|------|
<% @scheduled_reminders.each do |nr| %>
| <%= nr.scheduled_for.strftime("%Y-%m-%d %H:%M") %> | <%= nr.notification.title %> | <%= nr.notification.body || "-" %> |
<% end %>

To delete a reminder: `POST /notifications/actions/delete_reminder?id=<reminder_id>`

---

<% end %>
```

### notifications/actions_index.md.erb

Add reminder actions to the list:

```erb
- **Create Reminder** — [GET /notifications/actions/create_reminder](/notifications/actions/create_reminder)
  Schedule a notification for your future self

- **Delete Reminder** — [GET /notifications/actions/delete_reminder](/notifications/actions/delete_reminder)
  Cancel a scheduled reminder before it triggers
```

## /whoami Integration

Update the whoami view to show upcoming reminders:

```erb
<% scheduled_reminders = ReminderService.scheduled_for(@current_user).limit(5) %>
<% if scheduled_reminders.any? %>
## Upcoming Reminders

<% scheduled_reminders.each do |nr| %>
- **<%= nr.scheduled_for.strftime("%b %d at %H:%M") %>**: <%= nr.notification.title %>
<% end %>

[View all reminders](/notifications)
<% end %>
```

## Testing Plan

### Unit Tests

#### NotificationRecipient Model Tests

```ruby
# test/models/notification_recipient_test.rb

test "scheduled scope returns future scheduled notifications" do
  past = create_notification_recipient(scheduled_for: 1.hour.ago)
  future = create_notification_recipient(scheduled_for: 1.hour.from_now)
  immediate = create_notification_recipient(scheduled_for: nil)

  assert_not_includes NotificationRecipient.scheduled, past
  assert_includes NotificationRecipient.scheduled, future
  assert_not_includes NotificationRecipient.scheduled, immediate
end

test "due scope returns past scheduled notifications" do
  past = create_notification_recipient(scheduled_for: 1.hour.ago)
  future = create_notification_recipient(scheduled_for: 1.hour.from_now)

  assert_includes NotificationRecipient.due, past
  assert_not_includes NotificationRecipient.due, future
end

test "immediate scope returns non-scheduled notifications" do
  scheduled = create_notification_recipient(scheduled_for: 1.hour.from_now)
  immediate = create_notification_recipient(scheduled_for: nil)

  assert_not_includes NotificationRecipient.immediate, scheduled
  assert_includes NotificationRecipient.immediate, immediate
end

test "scheduled? returns true for future scheduled notifications" do
  nr = create_notification_recipient(scheduled_for: 1.hour.from_now)
  assert nr.scheduled?
end

test "scheduled? returns false for past scheduled notifications" do
  nr = create_notification_recipient(scheduled_for: 1.hour.ago)
  assert_not nr.scheduled?
end

test "due? returns true for past scheduled notifications" do
  nr = create_notification_recipient(scheduled_for: 1.hour.ago)
  assert nr.due?
end
```

#### ReminderService Tests

```ruby
# test/services/reminder_service_test.rb

class ReminderServiceTest < ActiveSupport::TestCase
  def setup
    @tenant = create_tenant
    @user = create_user
    @tenant.add_user!(@user)
    Tenant.current_id = @tenant.id
  end

  test "create! creates notification with reminder type" do
    notification = ReminderService.create!(
      user: @user,
      title: "Test reminder",
      scheduled_for: 1.day.from_now,
    )

    assert_equal "reminder", notification.notification_type
    assert_equal "Test reminder", notification.title
  end

  test "create! creates notification_recipient with scheduled_for" do
    scheduled_time = 1.day.from_now
    notification = ReminderService.create!(
      user: @user,
      title: "Test reminder",
      scheduled_for: scheduled_time,
    )

    nr = notification.notification_recipients.first
    assert_equal @user, nr.user
    assert_in_delta scheduled_time, nr.scheduled_for, 1.second
  end

  test "create! does not immediately enqueue delivery job" do
    assert_no_enqueued_jobs do
      ReminderService.create!(
        user: @user,
        title: "Test reminder",
        scheduled_for: 1.day.from_now,
      )
    end
  end

  test "create! truncates body to 200 characters" do
    long_body = "a" * 300
    notification = ReminderService.create!(
      user: @user,
      title: "Test",
      body: long_body,
      scheduled_for: 1.day.from_now,
    )

    assert_equal 200, notification.body.length
  end

  test "scheduled_for returns user's scheduled reminders" do
    ReminderService.create!(user: @user, title: "R1", scheduled_for: 1.day.from_now)
    ReminderService.create!(user: @user, title: "R2", scheduled_for: 2.days.from_now)

    other_user = create_user
    @tenant.add_user!(other_user)
    ReminderService.create!(user: other_user, title: "Other", scheduled_for: 1.day.from_now)

    reminders = ReminderService.scheduled_for(@user)
    assert_equal 2, reminders.count
    assert_equal "R1", reminders.first.notification.title
  end

  test "scheduled_for excludes past reminders" do
    ReminderService.create!(user: @user, title: "Future", scheduled_for: 1.day.from_now)

    # Create a past one by manipulating scheduled_for directly
    notification = ReminderService.create!(user: @user, title: "Past", scheduled_for: 1.day.from_now)
    notification.notification_recipients.first.update!(scheduled_for: 1.day.ago)

    reminders = ReminderService.scheduled_for(@user)
    assert_equal 1, reminders.count
    assert_equal "Future", reminders.first.notification.title
  end

  test "delete! removes notification_recipient and notification" do
    notification = ReminderService.create!(
      user: @user,
      title: "To delete",
      scheduled_for: 1.day.from_now,
    )
    nr = notification.notification_recipients.first

    ReminderService.delete!(nr)

    assert_raises(ActiveRecord::RecordNotFound) { nr.reload }
    assert_raises(ActiveRecord::RecordNotFound) { notification.reload }
  end
end
```

#### ReminderDeliveryJob Tests

```ruby
# test/jobs/reminder_delivery_job_test.rb

class ReminderDeliveryJobTest < ActiveJob::TestCase
  def setup
    @tenant = create_tenant
    @user = create_user
    @tenant.add_user!(@user)
    Tenant.current_id = @tenant.id
  end

  test "delivers due reminders" do
    superagent = create_superagent(tenant: @tenant)
    superagent.add_user!(@user)

    notification = ReminderService.create!(
      user: @user,
      title: "Due reminder",
      scheduled_for: 1.day.from_now,
    )
    nr = notification.notification_recipients.first
    nr.update!(scheduled_for: 1.minute.ago) # Make it due

    # Job uses perform_now internally, so check status change
    ReminderDeliveryJob.perform_now

    nr.reload
    assert_equal "delivered", nr.status
  end

  test "does not deliver future reminders" do
    ReminderService.create!(
      user: @user,
      title: "Future reminder",
      scheduled_for: 1.day.from_now,
    )

    assert_no_enqueued_jobs do
      ReminderDeliveryJob.perform_now
    end
  end

  test "does not deliver already delivered reminders" do
    notification = ReminderService.create!(
      user: @user,
      title: "Already delivered",
      scheduled_for: 1.day.from_now,
    )
    nr = notification.notification_recipients.first
    nr.update!(scheduled_for: 1.minute.ago, status: "delivered")

    assert_no_enqueued_jobs do
      ReminderDeliveryJob.perform_now
    end
  end

  test "creates reminders.delivered event for webhooks" do
    # User needs to be in a superagent for event context
    superagent = create_superagent(tenant: @tenant)
    superagent.add_user!(@user)

    notification = ReminderService.create!(
      user: @user,
      title: "Webhook reminder",
      scheduled_for: 1.day.from_now,
    )
    nr = notification.notification_recipients.first
    nr.update!(scheduled_for: 1.minute.ago)

    assert_difference "Event.count" do
      ReminderDeliveryJob.perform_now
    end

    event = Event.last
    assert_equal "reminders.delivered", event.event_type
    assert_equal @user, event.actor
    assert_equal 1, event.metadata["count"]
    assert_equal "Webhook reminder", event.metadata["reminders"].first["title"]
  end

  test "batches reminders with same timestamp into single event" do
    superagent = create_superagent(tenant: @tenant)
    superagent.add_user!(@user)

    scheduled_time = 1.day.from_now

    # Create 3 reminders for the exact same time
    3.times do |i|
      notification = ReminderService.create!(
        user: @user,
        title: "Reminder #{i}",
        scheduled_for: scheduled_time,
      )
      notification.notification_recipients.first.update!(scheduled_for: 1.minute.ago)
    end

    # Should create only 1 event for the batch
    assert_difference "Event.count", 1 do
      ReminderDeliveryJob.perform_now
    end

    event = Event.last
    assert_equal "reminders.delivered", event.event_type
    assert_equal 3, event.metadata["count"]
    assert_equal 3, event.metadata["reminders"].size
  end

  test "creates separate events for different timestamps" do
    superagent = create_superagent(tenant: @tenant)
    superagent.add_user!(@user)

    # Create reminders for different times
    time1 = 1.day.from_now
    time2 = 2.days.from_now

    n1 = ReminderService.create!(user: @user, title: "R1", scheduled_for: time1)
    n1.notification_recipients.first.update!(scheduled_for: 1.minute.ago)

    n2 = ReminderService.create!(user: @user, title: "R2", scheduled_for: time2)
    n2.notification_recipients.first.update!(scheduled_for: 2.minutes.ago)

    # Should create 2 events (one per timestamp)
    assert_difference "Event.count", 2 do
      ReminderDeliveryJob.perform_now
    end
  end
end
```

#### User Webhook Tests

```ruby
# test/controllers/user_webhooks_controller_test.rb

class UserWebhooksControllerTest < ActionDispatch::IntegrationTest
  def setup
    @tenant = create_tenant
    @user = create_user
    @tenant.add_user!(@user)
    host! "#{@tenant.subdomain}.#{ENV.fetch("HOSTNAME", nil)}"
  end

  test "user can view their own webhooks" do
    sign_in_as(@user, tenant: @tenant)
    get "/settings/webhooks", headers: { "Accept" => "text/markdown" }
    assert_response :success
    assert_includes response.body, "Webhooks for #{@user.handle}"
  end

  test "user can create a webhook for themselves" do
    sign_in_as(@user, tenant: @tenant)

    assert_difference "Webhook.count" do
      post "/settings/webhooks/actions/create", params: {
        url: "https://example.com/webhook",
        events: ["reminders.delivered"],
      }
    end

    webhook = Webhook.last
    assert_equal @user, webhook.user
    assert_equal @user, webhook.created_by
  end

  test "parent can view subagent webhooks" do
    subagent = create_subagent(parent: @user, name: "Test Subagent")
    @tenant.add_user!(subagent)

    sign_in_as(@user, tenant: @tenant)
    get "/u/#{subagent.handle}/webhooks", headers: { "Accept" => "text/markdown" }
    assert_response :success
    assert_includes response.body, "Webhooks for #{subagent.handle}"
  end

  test "parent can create webhook for subagent" do
    subagent = create_subagent(parent: @user, name: "Test Subagent")
    @tenant.add_user!(subagent)

    sign_in_as(@user, tenant: @tenant)

    assert_difference "Webhook.count" do
      post "/u/#{subagent.handle}/webhooks/actions/create", params: {
        url: "https://example.com/subagent-webhook",
      }
    end

    webhook = Webhook.last
    assert_equal subagent, webhook.user
    assert_equal @user, webhook.created_by  # Parent created it
  end

  test "non-parent cannot manage other user webhooks" do
    other_user = create_user
    @tenant.add_user!(other_user)

    sign_in_as(@user, tenant: @tenant)
    get "/u/#{other_user.handle}/webhooks"
    assert_response :forbidden
  end

  test "user can delete their own webhook" do
    sign_in_as(@user, tenant: @tenant)
    webhook = Webhook.create!(
      tenant: @tenant,
      user: @user,
      created_by: @user,
      name: "My webhook",
      url: "https://example.com/hook",
      events: ["reminders.delivered"],
    )

    assert_difference "Webhook.count", -1 do
      post "/settings/webhooks/actions/delete", params: { id: webhook.truncated_id }
    end
  end
end
```

#### WebhookDispatcher Tests

```ruby
# test/services/webhook_dispatcher_test.rb (add to existing)

test "dispatches reminder event to user-level webhook" do
  webhook = Webhook.create!(
    tenant: @tenant,
    user: @user,
    created_by: @user,
    name: "User webhook",
    url: "https://example.com/hook",
    events: ["reminders.delivered"],
  )

  event = Event.create!(
    tenant: @tenant,
    superagent: @superagent,
    event_type: "reminders.delivered",
    actor: @user,
    subject: @notification,
    metadata: { count: 1 },
  )

  assert_difference "WebhookDelivery.count" do
    WebhookDispatcher.dispatch(event)
  end

  delivery = WebhookDelivery.last
  assert_equal webhook, delivery.webhook
end

test "does not dispatch reminder event to other user's webhook" do
  other_user = create_user
  @tenant.add_user!(other_user)

  webhook = Webhook.create!(
    tenant: @tenant,
    user: other_user,  # Different user
    created_by: other_user,
    name: "Other user webhook",
    url: "https://example.com/hook",
    events: ["reminders.delivered"],
  )

  event = Event.create!(
    tenant: @tenant,
    superagent: @superagent,
    event_type: "reminders.delivered",
    actor: @user,  # Event is for @user, not other_user
    subject: @notification,
    metadata: { count: 1 },
  )

  assert_no_difference "WebhookDelivery.count" do
    WebhookDispatcher.dispatch(event)
  end
end
```

### Integration Tests

#### NotificationsController Tests

```ruby
# test/controllers/notifications_controller_test.rb (add to existing)

# === Scheduled Reminders Tests ===

test "index shows scheduled reminders section" do
  sign_in_as(@user, tenant: @tenant)
  ReminderService.create!(user: @user, title: "Future reminder", scheduled_for: 1.day.from_now)

  get "/notifications"
  assert_response :success
  assert_includes response.body, "Scheduled Reminders"
  assert_includes response.body, "Future reminder"
end

test "index does not show scheduled reminders section when empty" do
  sign_in_as(@user, tenant: @tenant)

  get "/notifications"
  assert_response :success
  assert_not_includes response.body, "Scheduled Reminders"
end

test "scheduled reminders do not appear in main notifications list" do
  sign_in_as(@user, tenant: @tenant)
  notification = ReminderService.create!(user: @user, title: "Scheduled", scheduled_for: 1.day.from_now)

  get "/notifications"
  # Should appear in scheduled section, not main list
  assert_select "section.scheduled-reminders", text: /Scheduled/
  assert_select "ul.notifications-list li", text: /Scheduled/, count: 0
end

test "create_reminder action requires title" do
  sign_in_as(@user, tenant: @tenant)

  post "/notifications/actions/create_reminder", params: {
    scheduled_for: 1.day.from_now.iso8601,
  }

  assert_includes response.body, "Title is required"
end

test "create_reminder action requires future scheduled_for" do
  sign_in_as(@user, tenant: @tenant)

  post "/notifications/actions/create_reminder", params: {
    title: "Test",
    scheduled_for: 1.day.ago.iso8601,
  }

  assert_includes response.body, "must be a future time"
end

test "create_reminder action creates reminder" do
  sign_in_as(@user, tenant: @tenant)

  assert_difference "Notification.count" do
    post "/notifications/actions/create_reminder", params: {
      title: "Remember this",
      body: "Important details",
      scheduled_for: 1.day.from_now.iso8601,
    }
  end

  notification = Notification.last
  assert_equal "reminder", notification.notification_type
  assert_equal "Remember this", notification.title
end

test "create_reminder accepts natural language time" do
  sign_in_as(@user, tenant: @tenant)

  post "/notifications/actions/create_reminder", params: {
    title: "Tomorrow reminder",
    scheduled_for: "tomorrow at 9am",
  }

  assert_response :redirect
  nr = NotificationRecipient.last
  assert nr.scheduled_for > Time.current
end

test "delete_reminder removes the reminder" do
  sign_in_as(@user, tenant: @tenant)
  notification = ReminderService.create!(user: @user, title: "To delete", scheduled_for: 1.day.from_now)
  nr = notification.notification_recipients.first

  assert_difference "NotificationRecipient.count", -1 do
    post "/notifications/actions/delete_reminder", params: { id: nr.id }
  end

  assert_response :redirect
end

test "delete_reminder cannot delete other user's reminder" do
  other_user = create_user
  @tenant.add_user!(other_user)
  notification = ReminderService.create!(user: other_user, title: "Other's reminder", scheduled_for: 1.day.from_now)
  nr = notification.notification_recipients.first

  sign_in_as(@user, tenant: @tenant)

  assert_no_difference "NotificationRecipient.count" do
    post "/notifications/actions/delete_reminder", params: { id: nr.id }
  end

  assert_includes response.body, "Reminder not found"
end

# === Markdown Format Tests ===

test "markdown index shows scheduled reminders table" do
  sign_in_as(@user, tenant: @tenant)
  ReminderService.create!(user: @user, title: "MD Reminder", scheduled_for: 1.day.from_now)

  get "/notifications", headers: { "Accept" => "text/markdown" }
  assert_response :success
  assert_includes response.body, "## Scheduled Reminders"
  assert_includes response.body, "MD Reminder"
end

test "create_reminder describe action returns markdown help" do
  sign_in_as(@user, tenant: @tenant)

  get "/notifications/actions/create_reminder", headers: { "Accept" => "text/markdown" }
  assert_response :success
  assert_includes response.body, "# Create Reminder"
  assert_includes response.body, "scheduled_for"
end

test "create_reminder execute returns markdown confirmation" do
  sign_in_as(@user, tenant: @tenant)

  post "/notifications/actions/create_reminder",
    params: { title: "Test", scheduled_for: 1.day.from_now.iso8601 },
    headers: { "Accept" => "text/markdown" }

  assert_response :success
  assert_includes response.body, "Reminder scheduled"
end
```

### WhoamiController Tests

```ruby
# test/controllers/whoami_controller_test.rb (add to existing)

test "whoami shows upcoming reminders" do
  sign_in_as(@user, tenant: @tenant)
  ReminderService.create!(user: @user, title: "Upcoming reminder", scheduled_for: 1.day.from_now)

  get "/whoami", headers: { "Accept" => "text/markdown" }
  assert_response :success
  assert_includes response.body, "Upcoming Reminders"
  assert_includes response.body, "Upcoming reminder"
end

test "whoami does not show reminders section when empty" do
  sign_in_as(@user, tenant: @tenant)

  get "/whoami", headers: { "Accept" => "text/markdown" }
  assert_response :success
  assert_not_includes response.body, "Upcoming Reminders"
end
```

## Implementation Order

### Phase A: User-Level Webhooks ✅ COMPLETED

1. **Database migrations**
   - [x] Add `user_id` to `webhooks` table

2. **Webhook model changes**
   - [x] Add `user` association to Webhook
   - [x] Add `for_user` scope
   - [x] Add validation: user_id and superagent_id are mutually exclusive

3. **WebhookDispatcher changes**
   - [x] Modify `find_matching_webhooks` to include user-level webhooks
   - [x] Add `user_scoped_event?` helper for reminder events

4. **User webhook management**
   - [x] Create `UserWebhooksController`
   - [x] Add routes for `/u/:handle/settings/webhooks` (consolidated route for both own and subagent webhooks)
   - [x] Add `/settings/webhooks` redirect to user-specific path
   - [x] Add authorization (user or parent can manage via `can_edit?`)
   - [x] Create views (index, action descriptions)

5. **Tests**
   - [x] Webhook model tests (user association, validation)
   - [x] WebhookDispatcher tests (user-level matching)
   - [x] UserWebhooksController tests (CRUD, authorization)

### Phase B: Scheduled Reminders ✅ COMPLETED

6. **Database migrations**
   - [x] Add `scheduled_for` to `notification_recipients`
   - [x] Ensure `event_id` is nullable on `notifications`

7. **Model changes**
   - [x] Add scopes to NotificationRecipient (`scheduled`, `due`, `immediate`)
   - [x] Add `scheduled?` and `due?` methods to NotificationRecipient
   - [x] Add "reminder" to Notification::NOTIFICATION_TYPES
   - [x] Make `event` association optional on Notification
   - [x] Add reminder to default notification preferences in TenantUser (email disabled)

8. **ReminderService**
   - [x] Create `ReminderService` with `create!`, `delete!`, `scheduled_for` methods
   - [x] Add limit validations (max reminders, rate limit, scheduling window)
   - [x] Create custom error classes

9. **Background job**
   - [x] Create `ReminderDeliveryJob` with timestamp batching
   - [x] Add loop prevention (max deliveries per user per minute)
   - [x] Add burst handling (max 100 per run, oldest first)
   - [x] Configure Sidekiq scheduler to run every minute

10. **Reminder controller actions**
    - [x] Add `describe_create_reminder` action
    - [x] Add `execute_create_reminder` action
    - [x] Add `describe_delete_reminder` action
    - [x] Add `execute_delete_reminder` action
    - [x] Modify `index` to load scheduled reminders
    - [x] Add time parsing helper (Chronic gem)

11. **Routes**
    - [x] Add reminder action routes

12. **Views**
    - [x] Update `notifications/index.html.erb` with scheduled reminders section
    - [x] Update `notifications/index.md.erb` with scheduled reminders table
    - [x] Update `notifications/actions_index.md.erb` with reminder actions

13. **Whoami integration**
    - [x] Update `whoami/index.md.erb` to show upcoming reminders

14. **Tests**
    - [x] NotificationRecipient model tests
    - [x] ReminderService tests (including limit/rate limit tests)
    - [x] ReminderDeliveryJob tests (batching, webhook/event creation, loop prevention)
    - [x] NotificationsController integration tests
    - [x] WhoamiController integration tests

15. **Documentation**
    - [x] Update `/learn/memory` to remove "not yet implemented" note

### Phase C: Settings Path Consolidation ✅ COMPLETED (2026-01-22)

User settings paths were consolidated to use `/u/:handle/settings` pattern:

16. **Route changes**
    - [x] Change `/settings` to redirect to `/u/:handle/settings`
    - [x] Change `/settings/webhooks` to redirect to `/u/:handle/settings/webhooks`
    - [x] Consolidate webhook routes under `/u/:handle/settings/webhooks`

17. **Controller updates**
    - [x] Add `redirect_to_settings` and `redirect_to_settings_webhooks` to UsersController
    - [x] Update UsersController `settings` action to use `can_edit?` for authorization
    - [x] Update ApiTokensController to use `can_edit?` for authorization
    - [x] Update UserWebhooksController paths to use `/u/:handle/settings/webhooks`

18. **View updates**
    - [x] Update settings views to use `@settings_user` instead of `@current_user`
    - [x] Add conditional display for "own settings" vs "managing subagent settings"

19. **Tests**
    - [x] Update user_webhooks_controller_test.rb routes to use new paths

## Dependencies

- **Chronic gem**: For natural language time parsing ("tomorrow at 9am", "next Monday", etc.)

## Security & Guardrails

### Limits (Required)

| Limit | Value | Rationale |
|-------|-------|-----------|
| Max reminders per user | 50 | Prevent database bloat |
| Max creation rate | 10/hour | Prevent rapid-fire creation |
| Max scheduling window | 90 days | Prevent indefinite future scheduling |
| Min scheduling interval | 1 minute | Align with job frequency |

### Implementation

**ReminderService.create! validations:**

```ruby
class ReminderService
  MAX_REMINDERS_PER_USER = 50
  MAX_REMINDERS_PER_HOUR = 10
  MAX_SCHEDULING_DAYS = 90

  def self.create!(user:, title:, body: nil, scheduled_for:, url: nil)
    validate_limits!(user, scheduled_for)
    # ... rest of creation logic
  end

  def self.validate_limits!(user, scheduled_time)
    # Check total reminder count
    current_count = scheduled_for(user).count
    if current_count >= MAX_REMINDERS_PER_USER
      raise ReminderLimitExceeded, "Maximum #{MAX_REMINDERS_PER_USER} scheduled reminders allowed"
    end

    # Check creation rate
    recent_count = NotificationRecipient
      .joins(:notification)
      .where(user: user)
      .where(notifications: { notification_type: "reminder" })
      .where("notification_recipients.created_at > ?", 1.hour.ago)
      .count
    if recent_count >= MAX_REMINDERS_PER_HOUR
      raise ReminderRateLimitExceeded, "Maximum #{MAX_REMINDERS_PER_HOUR} reminders per hour"
    end

    # Check scheduling window
    max_date = MAX_SCHEDULING_DAYS.days.from_now
    if scheduled_time > max_date
      raise ReminderSchedulingError, "Cannot schedule more than #{MAX_SCHEDULING_DAYS} days in future"
    end
  end
end
```

### Webhook Loop Prevention

The `ReminderDeliveryJob` includes loop prevention (see main job code above):
- Checks recent deliveries for the user (last 1 minute)
- If >= 5 deliveries in that window, marks batch as `rate_limited`
- Rate-limited reminders can be retried on the next job run (status change back to pending via manual intervention or automatic retry logic)

### Burst Handling

The `ReminderDeliveryJob` includes burst protection (see main job code above):
- Limits to 100 reminders per job run
- Orders by `scheduled_for` (oldest first)
- If job was down and comes back with backlog, processes gradually over multiple runs

### Additional Tests

```ruby
# test/services/reminder_service_test.rb

test "raises error when user has too many reminders" do
  ReminderService::MAX_REMINDERS_PER_USER.times do |i|
    ReminderService.create!(
      user: @user,
      title: "Reminder #{i}",
      scheduled_for: (i + 1).days.from_now,
    )
  end

  assert_raises(ReminderService::ReminderLimitExceeded) do
    ReminderService.create!(
      user: @user,
      title: "One too many",
      scheduled_for: 1.day.from_now,
    )
  end
end

test "raises error when creating too many reminders per hour" do
  ReminderService::MAX_REMINDERS_PER_HOUR.times do |i|
    ReminderService.create!(
      user: @user,
      title: "Rapid reminder #{i}",
      scheduled_for: (i + 1).days.from_now,
    )
  end

  assert_raises(ReminderService::ReminderRateLimitExceeded) do
    ReminderService.create!(
      user: @user,
      title: "Too fast",
      scheduled_for: 1.day.from_now,
    )
  end
end

test "raises error when scheduling too far in future" do
  assert_raises(ReminderService::ReminderSchedulingError) do
    ReminderService.create!(
      user: @user,
      title: "Way too far",
      scheduled_for: 100.days.from_now,
    )
  end
end

# test/jobs/reminder_delivery_job_test.rb

test "rate limits deliveries to prevent loops" do
  superagent = create_superagent(tenant: @tenant)
  superagent.add_user!(@user)

  # Create many due reminders
  10.times do |i|
    notification = ReminderService.create!(
      user: @user,
      title: "Reminder #{i}",
      scheduled_for: 1.day.from_now,
    )
    notification.notification_recipients.first.update!(scheduled_for: 1.minute.ago)
  end

  ReminderDeliveryJob.perform_now

  # Some should be delivered, some rate limited
  delivered = NotificationRecipient.where(status: "delivered").count
  rate_limited = NotificationRecipient.where(status: "rate_limited").count

  assert delivered <= ReminderDeliveryJob::MAX_DELIVERIES_PER_USER_PER_MINUTE
  assert rate_limited > 0
end

test "processes max 100 reminders per job run" do
  # This test ensures thundering herd prevention
  # (Implementation would need actual timing tests)
end
```

---

## Open Questions (Resolved)

1. **Time zones**: ✅ Resolved - `scheduled_for` stored in UTC, displayed in user's local time via Rails time helpers.

2. **Recurring reminders**: ✅ Deferred - Not implemented in this phase. Start simple with one-time reminders.

3. **Edit vs delete**: ✅ Resolved - Delete only. Users delete and recreate to modify.

4. **Rate-limited reminder handling**: ✅ Resolved - Marked as `rate_limited`. Does not auto-retry. Manual intervention or separate retry job could be added later if needed.

5. **Parent webhook visibility**: ✅ Resolved - Parent manages subagent's webhook (creates/deletes), but the webhook belongs to the subagent. Parent doesn't receive copies - this maintains AI agent autonomy while allowing parental oversight.

6. **Users without superagent membership**: ✅ Resolved - Job skips users without superagent membership (logs warning). Reminders stay pending for retry. This is an edge case - active users should always be in at least one studio.

## Success Criteria

### User-Level Webhooks ✅
- [x] Users can configure their own webhook endpoints at `/u/:handle/settings/webhooks`
- [x] Parents can configure webhook endpoints for their subagents at `/u/:handle/settings/webhooks`
- [x] User-level webhooks only receive events for that specific user
- [x] Non-parents cannot manage other users' webhooks

### Scheduled Reminders ✅
- [x] Users can create reminders via markdown API
- [x] Reminders appear on notifications page in "Scheduled Reminders" section
- [x] Reminders are delivered at scheduled time
- [x] **Reminders with same timestamp are batched into single `reminders.delivered` event**
- [x] **Reminder delivery triggers webhook to user's configured endpoint**
- [x] Reminders appear on `/whoami` page
- [x] Users can delete scheduled reminders
- [x] Natural language time parsing works ("tomorrow at 9am")
- [x] **Email disabled by default for reminders** (users can opt-in)

### Security ✅
- [x] **Max 50 reminders per user enforced**
- [x] **Rate limit of 10 reminders/hour enforced**
- [x] **Max 90-day scheduling window enforced**
- [x] **Loop prevention limits deliveries per minute**
- [x] **Burst handling limits to 100 per job run**

### Tests ✅
- [x] All tests pass (23/23 for users_controller_test and user_webhooks_controller_test)
