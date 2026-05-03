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

    notification
  end

  # Create or update a chat message notification for the recipient.
  # One notification per sender — if an undismissed notification from
  # the same sender already exists, we update its timestamp instead
  # of creating a duplicate.
  sig { params(sender: User, recipient: User, tenant: Tenant, url: String).void }
  def self.notify_chat_message!(sender:, recipient:, tenant:, url:)
    return if sender.id == recipient.id

    # Find existing undismissed chat_message notification from this sender to this recipient
    existing = NotificationRecipient
      .joins(:notification)
      .where(user: recipient, tenant: tenant, channel: "in_app")
      .where(dismissed_at: nil)
      .where(notifications: { notification_type: "chat_message", url: url })
      .first

    if existing
      # Already have an undismissed notification from this sender — nothing to do.
      # The notification stays at its original position in the inbox.
    else
      notification = Notification.create!(
        tenant: tenant,
        notification_type: "chat_message",
        title: "New message from #{sender.display_name}",
        url: url,
      )

      NotificationRecipient.create!(
        notification: notification,
        user: recipient,
        tenant: tenant,
        channel: "in_app",
        status: "delivered",
        delivered_at: Time.current,
      )
    end
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
      .update_all(dismissed_at: Time.current, status: "dismissed")
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
      .in_app.unread.not_scheduled.update_all(
        dismissed_at: Time.current,
        status: "dismissed"
      )
  end

  sig { params(user: User, tenant: Tenant, collective_id: String).returns(Integer) }
  def self.dismiss_all_for_collective(user, tenant:, collective_id:)
    # Dismiss all notifications for a specific collective
    # We bypass the collective scope on Event by using tenant_scoped_only
    event_ids = Event.tenant_scoped_only(tenant.id).where(collective_id: collective_id).pluck(:id)
    notification_ids = Notification.tenant_scoped_only(tenant.id).where(event_id: event_ids).pluck(:id)

    NotificationRecipient
      .where(user: user, tenant: tenant)
      .where(notification_id: notification_ids)
      .in_app.unread.not_scheduled
      .update_all(dismissed_at: Time.current, status: "dismissed")
  end

  sig { params(user: User, tenant: Tenant).returns(Integer) }
  def self.dismiss_all_reminders(user, tenant:)
    # Dismiss all notifications without an event (i.e., reminders that have become due)
    NotificationRecipient
      .joins(:notification)
      .where(user: user, tenant: tenant)
      .where(notifications: { event_id: nil })
      .in_app.unread.not_scheduled
      .update_all(dismissed_at: Time.current, status: "dismissed")
  end
end
