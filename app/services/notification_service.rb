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
end
