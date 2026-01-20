# Notifications & Webhooks System - Architecture Design

## Overview

Build a unified event system that delivers notifications to users and webhooks to external systems. This is a prerequisite for the server-side AI agents feature (approval requests, cost alerts, agent actions) and enables external integrations.

## Design Principles

1. **Unified event source** - Single event system feeds both notifications and webhooks
2. **Multi-channel delivery** - In-app, email, webhooks
3. **Dual interface** - Works for both HTML UI and markdown API
4. **Multi-tenant aware** - Respects tenant/studio scoping
5. **User/studio preferences** - Configurable per notification type and webhook
6. **Reliable delivery** - Retry logic, delivery tracking, failure handling

---

## Data Model

### Core Events

#### `events` table

Central record of every event that can trigger notifications or webhooks.

| Column | Type | Purpose |
|--------|------|---------|
| `id` | uuid | Primary key |
| `tenant_id` | uuid | Tenant scope |
| `studio_id` | uuid | Studio scope |
| `event_type` | string | 'note.created', 'decision.voted', 'commitment.joined', etc. |
| `actor_id` | uuid | User who triggered the event (nullable for system) |
| `subject_type` | string | Polymorphic: 'Note', 'Decision', 'Commitment' |
| `subject_id` | uuid | The content this is about |
| `metadata` | jsonb | Event-specific data |
| `created_at` | timestamp | When the event occurred |

### Notifications

#### `notifications` table

| Column | Type | Purpose |
|--------|------|---------|
| `id` | uuid | Primary key |
| `event_id` | uuid | Links to triggering event |
| `tenant_id` | uuid | Tenant scope |
| `notification_type` | string | 'mention', 'comment', 'participation', 'system' |
| `title` | string | Short summary |
| `body` | text | Longer description (markdown) |
| `url` | string | Link to relevant content |
| `created_at` | timestamp | |

#### `notification_recipients` table

| Column | Type | Purpose |
|--------|------|---------|
| `id` | uuid | Primary key |
| `notification_id` | uuid | Links to notification |
| `user_id` | uuid | Recipient |
| `channel` | string | 'in_app', 'email' |
| `status` | string | 'pending', 'delivered', 'read', 'dismissed' |
| `read_at` | timestamp | When user read it |
| `dismissed_at` | timestamp | When user dismissed it |
| `delivered_at` | timestamp | When delivered |
| `created_at` | timestamp | |

### Webhooks

#### `webhooks` table

Webhook endpoint registrations.

| Column | Type | Purpose |
|--------|------|---------|
| `id` | uuid | Primary key |
| `tenant_id` | uuid | Tenant scope |
| `studio_id` | uuid | Studio scope (nullable for tenant-wide) |
| `name` | string | Human-readable name |
| `url` | string | Endpoint URL (https required) |
| `secret` | string | HMAC signing secret |
| `events` | jsonb | Array of event types to subscribe to |
| `enabled` | boolean | On/off switch |
| `created_by_id` | uuid | User who created it |
| `metadata` | jsonb | Custom headers, etc. |
| `created_at` | timestamp | |
| `updated_at` | timestamp | |

#### `webhook_deliveries` table

Track every delivery attempt for debugging and retry.

| Column | Type | Purpose |
|--------|------|---------|
| `id` | uuid | Primary key |
| `webhook_id` | uuid | Links to webhook |
| `event_id` | uuid | Links to event |
| `status` | string | 'pending', 'success', 'failed', 'retrying' |
| `attempt_count` | integer | Number of attempts |
| `request_body` | text | JSON payload sent |
| `response_code` | integer | HTTP response code |
| `response_body` | text | Response body (truncated) |
| `error_message` | text | Error details if failed |
| `delivered_at` | timestamp | When successfully delivered |
| `next_retry_at` | timestamp | When to retry (if retrying) |
| `created_at` | timestamp | |

### User Preferences

Stored in `tenant_user.settings`:

```json
{
  "notification_preferences": {
    "mentions": { "in_app": true, "email": true },
    "comments": { "in_app": true, "email": false },
    "participation": { "in_app": true, "email": false },
    "system": { "in_app": true, "email": true }
  },
  "email_frequency": "immediate"
}
```

---

## Event Types

### Content Events (trigger both notifications and webhooks)
| Event Type | Trigger | Notification? | Webhook? |
|------------|---------|---------------|----------|
| `note.created` | Note created | If mentions | Yes |
| `note.updated` | Note updated | If mentions | Yes |
| `note.deleted` | Note deleted | No | Yes |
| `decision.created` | Decision created | No | Yes |
| `decision.voted` | Vote cast | To decision owner | Yes |
| `decision.resolved` | Decision closed | To participants | Yes |
| `commitment.created` | Commitment created | No | Yes |
| `commitment.joined` | User joined | To commitment owner | Yes |
| `commitment.critical_mass` | Threshold reached | To participants | Yes |
| `comment.created` | Comment added | To content owner | Yes |

### System Events (notifications only, not webhooks)
| Event Type | Trigger |
|------------|---------|
| `agent.action_pending` | AI agent needs approval |
| `agent.action_completed` | AI agent took action |
| `agent.cost_alert` | Cost threshold reached |

---

## Architecture

### Event Flow

```
Content Change (Note created, Vote cast, etc.)
        │
        ▼
┌─────────────────────────┐
│ Trackable concern       │  (ActiveRecord after_commit)
│ (replaces Tracked)      │
└───────────┬─────────────┘
            │
            ▼
┌─────────────────────────┐
│ EventService.record!    │  (Creates Event record)
└───────────┬─────────────┘
            │
    ┌───────┴───────┐
    │               │
    ▼               ▼
┌──────────┐  ┌──────────────┐
│ Notifi-  │  │ Webhook      │
│ cation   │  │ Dispatcher   │
│ Service  │  │              │
└────┬─────┘  └──────┬───────┘
     │               │
     ▼               ▼
┌──────────┐  ┌──────────────┐
│ Notifi-  │  │ Webhook      │
│ cation   │  │ Delivery     │
│ Delivery │  │ Job          │
│ Job      │  │              │
└──────────┘  └──────────────┘
```

### Webhook Payload Format

```json
{
  "id": "evt_abc123",
  "type": "note.created",
  "created_at": "2024-01-15T10:30:00Z",
  "tenant": {
    "id": "tenant_xyz",
    "subdomain": "acme"
  },
  "studio": {
    "id": "studio_123",
    "handle": "engineering"
  },
  "actor": {
    "id": "user_456",
    "handle": "alice",
    "name": "Alice Smith"
  },
  "data": {
    "note": {
      "id": "note_789",
      "truncated_id": "a1b2c3d4",
      "text": "Hello @bob, check this out!",
      "url": "https://acme.harmonic.so/studios/engineering/n/a1b2c3d4"
    }
  }
}
```

### Webhook Security

**Request signing:**
```
X-Harmonic-Signature: sha256=<HMAC-SHA256 of body using webhook secret>
X-Harmonic-Timestamp: <Unix timestamp>
X-Harmonic-Event: <event type>
X-Harmonic-Delivery: <delivery id>
```

**Verification (receiver side):**
```ruby
expected = OpenSSL::HMAC.hexdigest('sha256', secret, "#{timestamp}.#{body}")
Rack::Utils.secure_compare(expected, signature)
```

---

## Key Services

### `EventService`

Central service for recording events and dispatching to handlers.

```ruby
# app/services/event_service.rb
class EventService
  def self.record!(event_type:, actor:, subject:, metadata: {})
    event = Event.create!(
      tenant_id: Tenant.current_id,
      studio_id: Studio.current_id,
      event_type: event_type,
      actor: actor,
      subject: subject,
      metadata: metadata
    )

    # Dispatch to notification and webhook systems
    NotificationDispatcher.dispatch(event)
    WebhookDispatcher.dispatch(event)

    event
  end
end
```

### `NotificationDispatcher`

Determines who should be notified and creates notification records.

```ruby
# app/services/notification_dispatcher.rb
class NotificationDispatcher
  def self.dispatch(event)
    case event.event_type
    when /^note\.(created|updated)$/
      handle_note_event(event)
    when 'comment.created'
      handle_comment_event(event)
    when /^decision\./
      handle_decision_event(event)
    when /^commitment\./
      handle_commitment_event(event)
    when /^agent\./
      handle_agent_event(event)
    end
  end

  def self.handle_note_event(event)
    note = event.subject
    mentioned_users = MentionParser.parse(note.text, tenant_id: event.tenant_id)

    mentioned_users.each do |user|
      NotificationService.create_and_deliver!(
        event: event,
        recipient: user,
        notification_type: 'mention',
        title: "#{event.actor.display_name} mentioned you",
        body: note.text.truncate(200),
        url: note.url
      )
    end
  end
  # ... other handlers
end
```

### `WebhookDispatcher`

Finds matching webhooks and enqueues deliveries.

```ruby
# app/services/webhook_dispatcher.rb
class WebhookDispatcher
  def self.dispatch(event)
    # Skip system events (not exposed via webhooks)
    return if event.event_type.start_with?('agent.')

    webhooks = Webhook.where(tenant_id: event.tenant_id, enabled: true)
      .where('studio_id IS NULL OR studio_id = ?', event.studio_id)
      .select { |w| w.subscribed_to?(event.event_type) }

    webhooks.each do |webhook|
      delivery = WebhookDelivery.create!(
        webhook: webhook,
        event: event,
        status: 'pending',
        attempt_count: 0,
        request_body: build_payload(event, webhook)
      )

      WebhookDeliveryJob.perform_later(delivery.id)
    end
  end

  def self.build_payload(event, webhook)
    # Build JSON payload
  end
end
```

### `WebhookDeliveryService`

Handles actual HTTP delivery with retries.

```ruby
# app/services/webhook_delivery_service.rb
class WebhookDeliveryService
  MAX_ATTEMPTS = 5
  RETRY_DELAYS = [1.minute, 5.minutes, 30.minutes, 2.hours, 24.hours]

  def self.deliver!(delivery)
    webhook = delivery.webhook
    timestamp = Time.current.to_i
    signature = sign(delivery.request_body, timestamp, webhook.secret)

    response = HTTP.timeout(30)
      .headers(
        'Content-Type' => 'application/json',
        'X-Harmonic-Signature' => "sha256=#{signature}",
        'X-Harmonic-Timestamp' => timestamp.to_s,
        'X-Harmonic-Event' => delivery.event.event_type,
        'X-Harmonic-Delivery' => delivery.id
      )
      .post(webhook.url, body: delivery.request_body)

    delivery.update!(
      status: 'success',
      response_code: response.code,
      response_body: response.body.to_s.truncate(1000),
      delivered_at: Time.current,
      attempt_count: delivery.attempt_count + 1
    )
  rescue => e
    handle_failure(delivery, e)
  end

  def self.handle_failure(delivery, error)
    attempt = delivery.attempt_count + 1

    if attempt >= MAX_ATTEMPTS
      delivery.update!(
        status: 'failed',
        error_message: error.message,
        attempt_count: attempt
      )
    else
      delivery.update!(
        status: 'retrying',
        error_message: error.message,
        attempt_count: attempt,
        next_retry_at: Time.current + RETRY_DELAYS[attempt - 1]
      )
      WebhookDeliveryJob.set(wait_until: delivery.next_retry_at).perform_later(delivery.id)
    end
  end

  def self.sign(body, timestamp, secret)
    OpenSSL::HMAC.hexdigest('sha256', secret, "#{timestamp}.#{body}")
  end
end
```

### `MentionParser`

```ruby
# app/services/mention_parser.rb
class MentionParser
  MENTION_PATTERN = /@([a-zA-Z0-9_-]+)/

  def self.parse(text, tenant_id:)
    return [] if text.blank?

    handles = text.scan(MENTION_PATTERN).flatten.uniq
    return [] if handles.empty?

    TenantUser.where(tenant_id: tenant_id, handle: handles)
              .includes(:user)
              .map(&:user)
  end

  def self.extract_handles(text)
    return [] if text.blank?
    text.scan(MENTION_PATTERN).flatten.uniq
  end
end
```

---

## Models

### `Event`

```ruby
# app/models/event.rb
class Event < ApplicationRecord
  include HasTenant

  belongs_to :studio
  belongs_to :actor, class_name: 'User', optional: true
  belongs_to :subject, polymorphic: true

  has_many :notifications, dependent: :destroy
  has_many :webhook_deliveries, dependent: :destroy

  validates :event_type, presence: true

  scope :recent, -> { order(created_at: :desc) }
end
```

### `Notification`

```ruby
# app/models/notification.rb
class Notification < ApplicationRecord
  include HasTenant

  belongs_to :event
  has_many :notification_recipients, dependent: :destroy
  has_many :recipients, through: :notification_recipients, source: :user

  validates :notification_type, presence: true
  validates :title, presence: true

  scope :recent, -> { order(created_at: :desc) }
end
```

### `NotificationRecipient`

```ruby
# app/models/notification_recipient.rb
class NotificationRecipient < ApplicationRecord
  belongs_to :notification
  belongs_to :user

  validates :channel, inclusion: { in: %w[in_app email] }
  validates :status, inclusion: { in: %w[pending delivered read dismissed] }

  scope :unread, -> { where(read_at: nil, dismissed_at: nil) }
  scope :in_app, -> { where(channel: 'in_app') }

  def read!
    update!(read_at: Time.current, status: 'read')
  end

  def dismiss!
    update!(dismissed_at: Time.current, status: 'dismissed')
  end
end
```

### `Webhook`

```ruby
# app/models/webhook.rb
class Webhook < ApplicationRecord
  include HasTenant
  include HasTruncatedId

  belongs_to :studio, optional: true
  belongs_to :created_by, class_name: 'User'
  has_many :webhook_deliveries, dependent: :destroy

  validates :name, presence: true
  validates :url, presence: true, format: { with: /\Ahttps:\/\// }
  validates :secret, presence: true

  before_validation :generate_secret, on: :create

  def subscribed_to?(event_type)
    events.include?(event_type) || events.include?('*')
  end

  private

  def generate_secret
    self.secret ||= SecureRandom.hex(32)
  end
end
```

### `WebhookDelivery`

```ruby
# app/models/webhook_delivery.rb
class WebhookDelivery < ApplicationRecord
  belongs_to :webhook
  belongs_to :event

  validates :status, inclusion: { in: %w[pending success failed retrying] }

  scope :pending, -> { where(status: 'pending') }
  scope :failed, -> { where(status: 'failed') }
  scope :needs_retry, -> { where(status: 'retrying').where('next_retry_at <= ?', Time.current) }
end
```

### `Trackable` concern (replaces `Tracked`)

```ruby
# app/models/concerns/trackable.rb
module Trackable
  extend ActiveSupport::Concern

  included do
    after_create_commit :track_creation
    after_update_commit :track_changes
    after_destroy_commit :track_deletion
  end

  private

  def track_creation
    EventService.record!(
      event_type: "#{self.class.name.underscore}.created",
      actor: respond_to?(:created_by) ? created_by : nil,
      subject: self,
      metadata: trackable_attributes
    )
  end

  def track_changes
    return if saved_changes.except('updated_at').empty?

    EventService.record!(
      event_type: "#{self.class.name.underscore}.updated",
      actor: respond_to?(:updated_by) ? updated_by : nil,
      subject: self,
      metadata: { changes: saved_changes.except('updated_at') }
    )
  end

  def track_deletion
    EventService.record!(
      event_type: "#{self.class.name.underscore}.deleted",
      actor: nil,
      subject: self,
      metadata: trackable_attributes
    )
  end

  def trackable_attributes
    attributes.slice('id', 'truncated_id', 'text', 'title', 'name').compact
  end
end
```

---

## Controllers

### `NotificationsController`

```ruby
# app/controllers/notifications_controller.rb
class NotificationsController < ApplicationController
  def index
    @recipients = current_user.notification_recipients
      .includes(notification: :event)
      .in_app
      .order(created_at: :desc)
      .page(params[:page])
  end

  def unread_count
    count = current_user.notification_recipients.in_app.unread.count
    render json: { count: count }
  end

  def execute_mark_read
    recipient = current_user.notification_recipients.find(params[:id])
    recipient.read!
    render_action_success(action_name: 'mark_read', resource: recipient)
  end

  def execute_dismiss
    recipient = current_user.notification_recipients.find(params[:id])
    recipient.dismiss!
    render_action_success(action_name: 'dismiss', resource: recipient)
  end

  def execute_mark_all_read
    current_user.notification_recipients.in_app.unread.update_all(
      read_at: Time.current, status: 'read'
    )
    render_action_success(action_name: 'mark_all_read', resource: nil)
  end
end
```

### `WebhooksController`

```ruby
# app/controllers/webhooks_controller.rb
class WebhooksController < ApplicationController
  before_action :require_admin!

  def index
    @webhooks = current_studio.webhooks.order(created_at: :desc)
  end

  def show
    @webhook = current_studio.webhooks.find_by_truncated_id!(params[:id])
    @recent_deliveries = @webhook.webhook_deliveries.order(created_at: :desc).limit(20)
  end

  def execute_create_webhook
    webhook = current_studio.webhooks.create!(
      name: params[:name],
      url: params[:url],
      events: params[:events] || ['*'],
      created_by: current_user
    )
    render_action_success(action_name: 'create_webhook', resource: webhook)
  end

  def execute_update_webhook
    webhook = current_studio.webhooks.find_by_truncated_id!(params[:id])
    webhook.update!(webhook_params)
    render_action_success(action_name: 'update_webhook', resource: webhook)
  end

  def execute_delete_webhook
    webhook = current_studio.webhooks.find_by_truncated_id!(params[:id])
    webhook.destroy!
    render_action_success(action_name: 'delete_webhook', resource: webhook)
  end

  def execute_test_webhook
    webhook = current_studio.webhooks.find_by_truncated_id!(params[:id])
    WebhookTestService.send_test!(webhook)
    render_action_success(action_name: 'test_webhook', resource: webhook)
  end

  private

  def webhook_params
    params.permit(:name, :url, :enabled, events: [])
  end
end
```

---

## Jobs

### `NotificationDeliveryJob`

```ruby
# app/jobs/notification_delivery_job.rb
class NotificationDeliveryJob < ApplicationJob
  queue_as :default

  def perform(notification_recipient_id)
    recipient = NotificationRecipient.find(notification_recipient_id)

    case recipient.channel
    when 'in_app'
      recipient.update!(status: 'delivered', delivered_at: Time.current)
    when 'email'
      NotificationMailer.notification_email(recipient).deliver_now
      recipient.update!(status: 'delivered', delivered_at: Time.current)
    end
  end
end
```

### `WebhookDeliveryJob`

```ruby
# app/jobs/webhook_delivery_job.rb
class WebhookDeliveryJob < ApplicationJob
  queue_as :webhooks

  def perform(delivery_id)
    delivery = WebhookDelivery.find(delivery_id)
    return if delivery.status == 'success'
    return unless delivery.webhook.enabled?

    WebhookDeliveryService.deliver!(delivery)
  end
end
```

### `WebhookRetryJob`

```ruby
# app/jobs/webhook_retry_job.rb
class WebhookRetryJob < ApplicationJob
  queue_as :webhooks

  # Run every minute via cron/whenever
  def perform
    WebhookDelivery.needs_retry.find_each do |delivery|
      WebhookDeliveryJob.perform_later(delivery.id)
    end
  end
end
```

---

## Routes

```ruby
# config/routes.rb

# Notifications (user-facing)
resources :notifications, only: [:index, :show] do
  collection do
    get :unread_count
    post 'actions/mark_all_read', to: 'notifications#execute_mark_all_read'
  end
  member do
    post 'actions/mark_read', to: 'notifications#execute_mark_read'
    post 'actions/dismiss', to: 'notifications#execute_dismiss'
  end
end

# Webhooks (studio admin)
scope '/studios/:studio_handle' do
  resources :webhooks, only: [:index, :show, :new] do
    collection do
      post 'actions/create_webhook', to: 'webhooks#execute_create_webhook'
    end
    member do
      get 'actions', to: 'webhooks#actions_index'
      post 'actions/update_webhook', to: 'webhooks#execute_update_webhook'
      post 'actions/delete_webhook', to: 'webhooks#execute_delete_webhook'
      post 'actions/test_webhook', to: 'webhooks#execute_test_webhook'
    end
  end
end
```

---

## UI

### Notification Badge (header)
- Bell icon with unread count badge
- Dropdown showing recent notifications
- "Mark all read" action
- Link to full notifications page

### Notifications Page (`/notifications`)
- List of notifications with type icons
- Click to navigate to content
- Mark read / dismiss actions
- Pagination

### Webhook Management (`/studios/:handle/settings/webhooks`)
- List of registered webhooks
- Create new webhook form
- Edit webhook (name, URL, events)
- Enable/disable toggle
- View recent deliveries
- Test webhook button
- Delete webhook

---

## Files to Create

### Migrations
- `db/migrate/XXXXXX_create_events.rb`
- `db/migrate/XXXXXX_create_notifications.rb`
- `db/migrate/XXXXXX_create_notification_recipients.rb`
- `db/migrate/XXXXXX_create_webhooks.rb`
- `db/migrate/XXXXXX_create_webhook_deliveries.rb`

### Models
- `app/models/event.rb`
- `app/models/notification.rb`
- `app/models/notification_recipient.rb`
- `app/models/webhook.rb`
- `app/models/webhook_delivery.rb`
- `app/models/concerns/trackable.rb` (replaces tracked.rb)

### Services
- `app/services/event_service.rb`
- `app/services/notification_service.rb`
- `app/services/notification_dispatcher.rb`
- `app/services/webhook_dispatcher.rb`
- `app/services/webhook_delivery_service.rb`
- `app/services/webhook_test_service.rb`
- `app/services/mention_parser.rb`

### Jobs
- `app/jobs/notification_delivery_job.rb`
- `app/jobs/webhook_delivery_job.rb`
- `app/jobs/webhook_retry_job.rb`

### Controllers
- `app/controllers/notifications_controller.rb`
- `app/controllers/webhooks_controller.rb`

### Views
- `app/views/notifications/index.html.erb`
- `app/views/notifications/index.md.erb`
- `app/views/notifications/show.md.erb`
- `app/views/webhooks/index.html.erb`
- `app/views/webhooks/index.md.erb`
- `app/views/webhooks/show.html.erb`
- `app/views/webhooks/show.md.erb`
- `app/views/webhooks/new.html.erb`
- `app/views/webhooks/new.md.erb`
- `app/views/notification_mailer/notification_email.html.erb`
- `app/views/notification_mailer/notification_email.text.erb`

### Tests
- `test/models/event_test.rb`
- `test/models/notification_test.rb`
- `test/models/webhook_test.rb`
- `test/services/event_service_test.rb`
- `test/services/notification_dispatcher_test.rb`
- `test/services/webhook_dispatcher_test.rb`
- `test/services/webhook_delivery_service_test.rb`
- `test/services/mention_parser_test.rb`
- `test/integration/notifications_test.rb`
- `test/integration/webhooks_test.rb`
- `app/javascript/controllers/mention_autocomplete_controller.test.ts`
- `app/javascript/controllers/notification_badge_controller.test.ts`

### Stimulus Controllers (Phase 7)
- `app/javascript/controllers/mention_autocomplete_controller.ts` - @ mention autocomplete
- `app/javascript/controllers/notification_badge_controller.ts` - Real-time badge updates

### API Endpoints (Phase 7)
- `app/controllers/api/users_controller.rb` - User search for autocomplete

### Modified Files
- `config/routes.rb` - Add routes
- `config/sidekiq.yml` - Add webhooks queue
- `app/models/user.rb` - Add associations
- `app/models/note.rb` - Include Trackable
- `app/models/decision.rb` - Include Trackable
- `app/models/commitment.rb` - Include Trackable
- `app/services/actions_helper.rb` - Add webhook/notification actions
- `app/views/layouts/application.html.erb` - Add notification badge and navigation
- `app/views/layouts/_header.html.erb` - Notification badge with unread count
- `app/views/studios/settings/*.html.erb` - Webhook navigation links
- `app/views/notes/_form.html.erb` - Mention autocomplete integration
- `app/views/comments/_form.html.erb` - Mention autocomplete integration

---

## Implementation Phases

### Phase 1: Event Infrastructure
1. Create `events` table and model
2. Create `EventService`
3. Create `Trackable` concern (replaces `Tracked`)
4. Include in Note, Decision, Commitment

### Phase 2: Notifications Core
1. Create notifications tables and models
2. Create `NotificationService` and `NotificationDispatcher`
3. Create `MentionParser`
4. Create `NotificationDeliveryJob`

### Phase 3: Notifications UI
1. `NotificationsController` with actions
2. Notification views (HTML + markdown)
3. Header notification badge
4. User preferences settings

### Phase 4: Webhooks Core
1. Create webhooks tables and models
2. Create `WebhookDispatcher`
3. Create `WebhookDeliveryService`
4. Create delivery and retry jobs

### Phase 5: Webhooks UI
1. `WebhooksController` with CRUD actions
2. Webhook management views (HTML + markdown)
3. Delivery history view
4. Test webhook functionality

### Phase 6: Email Delivery
1. `NotificationMailer`
2. Email templates
3. Preference-based delivery
4. (Optional) Digest job

### Phase 7: UI Improvements
1. **Notification Navigation & Header Status**
   - Add notifications link to main navigation (header/sidebar)
   - Persistent notification badge in header showing unread count
   - Visual indicator for unread state (color/animation)
   - Turbo Stream updates for real-time badge count changes

2. **Webhook Navigation**
   - Add webhooks link to studio settings navigation
   - Breadcrumb navigation for webhook detail pages
   - Clear entry point from studio admin panel

3. **@ Mention Autocomplete**
   - Stimulus controller for mention autocomplete in text inputs
   - API endpoint for searching users by handle/name
   - Dropdown UI showing matching users as you type `@`
   - Keyboard navigation (arrow keys, enter to select)
   - Apply to: note forms, comment forms, decision/commitment descriptions
   - Graceful degradation when JS disabled

4. **Navigation Polish**
   - Consistent back links and breadcrumbs
   - Clear visual hierarchy for notification types
   - Empty state messaging for notifications and webhooks lists

---

## Verification

### Manual Testing - Notifications
1. Create a note with `@handle` mention
2. Verify notification appears for mentioned user
3. Check notification badge updates
4. Mark as read, verify badge decrements
5. Test markdown API endpoints with MCP

### Manual Testing - Webhooks
1. Create a webhook endpoint (use webhook.site or similar)
2. Register webhook in studio settings
3. Create a note in that studio
4. Verify webhook received with correct payload
5. Check signature validation
6. Test retry behavior (use invalid URL first)

### Manual Testing - UI Improvements (Phase 7)
1. **Notification Navigation**
   - Verify notifications link visible in header/navigation
   - Check unread badge displays correct count
   - Confirm badge updates when notifications are read/created
2. **Webhook Navigation**
   - Navigate to studio settings
   - Verify webhooks link is clearly visible
   - Test breadcrumb navigation from webhook detail back to list
3. **Mention Autocomplete**
   - In a note form, type `@` followed by partial handle
   - Verify dropdown appears with matching users
   - Test keyboard navigation (up/down arrows)
   - Select user with Enter key, verify handle inserted
   - Test mouse click selection
   - Verify works in comment forms as well

### Automated Tests
```bash
docker compose exec web bundle exec rails test test/models/event_test.rb
docker compose exec web bundle exec rails test test/services/event_service_test.rb
docker compose exec web bundle exec rails test test/services/mention_parser_test.rb
docker compose exec web bundle exec rails test test/services/webhook_delivery_service_test.rb
docker compose exec web bundle exec rails test test/integration/notifications_test.rb
docker compose exec web bundle exec rails test test/integration/webhooks_test.rb

# Frontend tests for Phase 7
docker compose exec js npm test -- mention_autocomplete
docker compose exec js npm test -- notification_badge
```

---

## Future Considerations

- **Real-time updates**: Action Cable for instant notifications
- **Webhook events UI**: Let users choose specific events per webhook
- **Digest emails**: Daily/weekly summary jobs
- **Notification grouping**: Collapse similar notifications
- **Webhook logs retention**: Auto-cleanup old delivery records
- **Rate limiting**: Prevent webhook spam to external endpoints

---

## Implementation Status

| Phase | Status | Notes |
|-------|--------|-------|
| Phase 1: Event Infrastructure | Completed | Events table, EventService, Trackable concern |
| Phase 2: Notifications Core | Completed | Notifications models, NotificationService, MentionParser |
| Phase 3: Notifications UI | Completed | NotificationsController, views (HTML + markdown) |
| Phase 4: Webhooks Core | Completed | Webhooks models, WebhookDispatcher, WebhookDeliveryService |
| Phase 5: Webhooks UI | Completed | WebhooksController, management views |
| Phase 6: Email Delivery | Completed | NotificationMailer, email templates |
| Phase 7: UI Improvements | Completed | Notification badge, mention autocomplete, navigation links |
