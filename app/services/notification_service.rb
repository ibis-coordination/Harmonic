# typed: true

class NotificationService
  extend T::Sig

  sig do
    params(
      event: Event,
      recipient: User,
      notification_type: String,
      title: String,
      body: T.nilable(String),
      url: T.nilable(String),
      channels: T::Array[String]
    ).returns(Notification)
  end
  def self.create_and_deliver!(event:, recipient:, notification_type:, title:, body: nil, url: nil, channels: ["in_app"])
    notification = Notification.create!(
      event: event,
      tenant_id: T.unsafe(event).tenant_id,
      notification_type: notification_type,
      title: title,
      body: body,
      url: url
    )

    channels.each do |channel|
      notification_recipient = NotificationRecipient.create!(
        notification: notification,
        user: recipient,
        channel: channel,
        status: "pending"
      )

      # Enqueue delivery job
      NotificationDeliveryJob.perform_later(notification_recipient.id)
    end

    # Fire notifications.delivered event (for user-notification webhooks).
    # Once per notification, regardless of channels. Reminders skip — they
    # fire reminders.delivered from ReminderDeliveryJob.
    fire_notifications_delivered_event(notification: notification, recipient: recipient, channels: channels)

    notification
  end

  # Create or update a chat message notification for the recipient.
  # One notification per sender — if an undismissed notification from
  # the same sender already exists, we update its timestamp instead
  # of creating a duplicate.
  sig { params(sender: User, recipient: User, tenant: Tenant, url: String).void }
  def self.notify_chat_message!(sender:, recipient:, tenant:, url:)
    return if sender.id == recipient.id

    # Find existing unread chat_message notification from this sender to this
    # recipient. Read or dismissed ones don't suppress — a new message after
    # the recipient has seen the old notification is new information.
    existing = NotificationRecipient
      .joins(:notification)
      .where(user: recipient, tenant: tenant, channel: "in_app")
      .where(dismissed_at: nil, read_at: nil)
      .where(notifications: { notification_type: "chat_message", url: url })
      .first

    notification = if existing
      # In-app inbox dedups: keep the existing notification so the recipient
      # sees one consolidated row, not a pile of unread chat pings. The join
      # on :notification above guarantees `existing.notification` is non-nil.
      T.must(existing.notification)
    else
      n = Notification.create!(
        tenant: tenant,
        notification_type: "chat_message",
        title: "New message from #{sender.display_name}",
        url: url
      )

      NotificationRecipient.create!(
        notification: n,
        user: recipient,
        tenant: tenant,
        channel: "in_app",
        status: "delivered",
        delivered_at: Time.current
      )

      n
    end

    # Always fire the event — every chat message is independently meaningful
    # to notification-webhook subscribers (external agents, integrations).
    # In-app dedup is a UX concern; webhook delivery is a transport concern.
    #
    # Chat-message notifications have no triggering Event, so the renderer's
    # `notification.event.actor` path returns nil. Pass the sender id through
    # metadata so the webhook payload still resolves an `actor`.
    fire_notifications_delivered_event(
      notification: notification,
      recipient: recipient,
      channels: ["in_app"],
      extra_metadata: { "original_actor_id" => sender.id }
    )
  end

  # Dismiss chat notifications from a specific sender for a user.
  # Called when the user replies, so the notification auto-clears.
  sig { params(user: User, sender: User, tenant: Tenant).void }
  def self.dismiss_chat_notifications_from!(user:, sender:, tenant:)
    sender_handle = TenantUser.tenant_scoped_only(tenant.id).find_by(user: sender)&.handle
    return unless sender_handle

    chat_url = "/chat/#{sender_handle}"

    NotificationRecipient
      .joins(:notification)
      .where(user: user, tenant: tenant, channel: "in_app")
      .where(dismissed_at: nil)
      .where(notifications: { notification_type: "chat_message", url: chat_url })
      .update_all(dismiss_attributes)
  end

  sig { params(user: User, tenant: Tenant).returns(Integer) }
  def self.unread_count_for(user, tenant:)
    # Exclude scheduled future reminders - they're not "unread" until their scheduled time
    NotificationRecipient
      .where(user: user, tenant: tenant)
      .in_app.unread.not_scheduled.count
  end

  sig { params(user: User, tenant: Tenant).void }
  def self.dismiss_all_for(user, tenant:)
    # Exclude scheduled future reminders - they shouldn't be dismissed before they trigger
    NotificationRecipient
      .where(user: user, tenant: tenant)
      .in_app.undismissed.not_scheduled.update_all(dismiss_attributes)
  end

  sig { params(user: User, tenant: Tenant, collective_id: String).returns(Integer) }
  def self.dismiss_all_for_collective(user, tenant:, collective_id:)
    # Dismiss all notifications for a specific collective
    # We bypass the collective scope on Event by using tenant_scoped_only
    NotificationRecipient
      .where(user: user, tenant: tenant)
      .where(notification_id: notification_ids_for_collective(tenant, collective_id))
      .in_app.undismissed.not_scheduled
      .update_all(dismiss_attributes)
  end

  sig { params(user: User, tenant: Tenant).returns(Integer) }
  def self.dismiss_all_reminders(user, tenant:)
    # Dismiss all notifications without an event (i.e., reminders that have become due)
    NotificationRecipient
      .joins(:notification)
      .where(user: user, tenant: tenant)
      .where(notifications: { event_id: nil })
      .in_app.undismissed.not_scheduled
      .update_all(dismiss_attributes)
  end

  sig { params(user: User, tenant: Tenant).returns(Integer) }
  def self.mark_all_read_for(user, tenant:)
    NotificationRecipient
      .where(user: user, tenant: tenant)
      .in_app.unread.not_scheduled
      .update_all(read_at: Time.current)
  end

  sig { params(user: User, tenant: Tenant, collective_id: String).returns(Integer) }
  def self.mark_all_read_for_collective(user, tenant:, collective_id:)
    NotificationRecipient
      .where(user: user, tenant: tenant)
      .where(notification_id: notification_ids_for_collective(tenant, collective_id))
      .in_app.unread.not_scheduled
      .update_all(read_at: Time.current)
  end

  sig { params(user: User, tenant: Tenant).returns(Integer) }
  def self.mark_all_read_reminders(user, tenant:)
    # Mark all notifications without an event (i.e., reminders that have become due)
    NotificationRecipient
      .joins(:notification)
      .where(user: user, tenant: tenant)
      .where(notifications: { event_id: nil })
      .in_app.unread.not_scheduled
      .update_all(read_at: Time.current)
  end

  # Dismissing implies reading: rows dismissed in bulk keep an existing
  # read_at and get one stamped otherwise. The COALESCE reference is
  # table-qualified because some callers join :notification.
  sig { returns(T::Array[T.untyped]) }
  def self.dismiss_attributes
    now = Time.current
    ["dismissed_at = ?, status = 'dismissed', read_at = COALESCE(notification_recipients.read_at, ?)", now, now]
  end

  sig { params(tenant: Tenant, collective_id: String).returns(T::Array[String]) }
  def self.notification_ids_for_collective(tenant, collective_id)
    event_ids = Event.tenant_scoped_only(tenant.id).where(collective_id: collective_id).pluck(:id)
    Notification.tenant_scoped_only(tenant.id).where(event_id: event_ids).pluck(:id)
  end

  # Fires `notifications.delivered` for user-notification webhook routing.
  # Skipped for reminder notifications — `ReminderDeliveryJob` fires
  # `reminders.delivered` for those.
  sig do
    params(
      notification: Notification,
      recipient: User,
      channels: T::Array[String],
      extra_metadata: T::Hash[String, T.untyped]
    ).void
  end
  def self.fire_notifications_delivered_event(notification:, recipient:, channels:, extra_metadata: {})
    return if notification.notification_type == "reminder"

    metadata = {
      "notification_type" => notification.notification_type,
      "title" => notification.title,
      "body" => notification.body,
      "url" => notification.url,
      "channels" => channels,
    }.merge(extra_metadata)

    EventService.record!(
      event_type: "notifications.delivered",
      actor: recipient,
      subject: notification,
      metadata: metadata
    )
  rescue StandardError => e
    Rails.logger.error("Failed to fire notifications.delivered event: #{e.message}")
  end

  private_class_method :dismiss_attributes, :notification_ids_for_collective
end
