# typed: true
# frozen_string_literal: true

class NotificationDeliveryJob < TenantScopedJob
  extend T::Sig

  queue_as :default

  sig { params(notification_recipient_id: String).void }
  def perform(notification_recipient_id)
    # Load recipient without tenant context (middleware cleared it)
    recipient = NotificationRecipient.unscoped_for_system_job.find_by(id: notification_recipient_id)
    return unless recipient
    return if recipient.status == "delivered"

    # Set tenant context from the notification
    notification = recipient.notification
    return unless notification&.tenant

    set_tenant_context!(notification.tenant)

    case recipient.channel
    when "email"
      deliver_email(recipient)
    when "in_app"
      # In-app notifications are already created, just mark as delivered
      recipient.mark_delivered!
    end

    # Fire notifications.delivered event for user webhooks
    # Skip if this is a reminder being delivered as part of ReminderDeliveryJob batch
    # (those already fire reminders.delivered)
    fire_notification_delivered_event(recipient)
  end

  private

  sig { params(recipient: NotificationRecipient).void }
  def deliver_email(recipient)
    user = recipient.user
    # Skip email delivery for users without email addresses
    return recipient.mark_delivered! if user.nil? || user.email.blank?

    NotificationMailer.notification_email(recipient).deliver_now
    recipient.mark_delivered!
  rescue StandardError => e
    # Log the error but don't fail the job - email delivery failures shouldn't
    # prevent the notification from being marked. We may want to retry or track
    # failures in the future.
    Rails.logger.error("Failed to deliver notification email: #{e.message}")
    recipient.mark_delivered!
  end

  sig { params(recipient: NotificationRecipient).void }
  def fire_notification_delivered_event(recipient)
    notification = recipient.notification
    return unless notification

    # Skip reminders - ReminderDeliveryJob already fires reminders.delivered for them
    return if notification.notification_type == "reminder"

    # Only fire event for in_app channel to avoid duplicates when users have
    # multiple channels (email + in_app). in_app is the default/primary channel.
    return unless recipient.channel == "in_app"

    event = notification.event
    user = recipient.user

    # Need tenant and collective context to fire events
    return unless event&.tenant_id && event.collective_id

    # Set collective context for EventService
    collective = event.collective
    set_collective_context!(collective) if collective

    EventService.record!(
      event_type: "notifications.delivered",
      actor: user,
      subject: notification,
      metadata: {
        "notification_type" => notification.notification_type,
        "title" => notification.title,
        "body" => notification.body,
        "url" => notification.url,
        "channel" => recipient.channel,
      }
    )
  rescue StandardError => e
    # Don't fail the job if event recording fails
    Rails.logger.error("Failed to fire notifications.delivered event: #{e.message}")
  end
end
