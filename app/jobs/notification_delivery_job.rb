# typed: true

class NotificationDeliveryJob < ApplicationJob
  extend T::Sig

  queue_as :default

  sig { params(notification_recipient_id: String).void }
  def perform(notification_recipient_id)
    recipient = NotificationRecipient.find_by(id: notification_recipient_id)
    return unless recipient
    return if recipient.status == "delivered"

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

    # Need tenant and superagent context to fire events
    return unless event&.tenant_id && event.superagent_id

    tenant = event.tenant
    return unless tenant

    # Set context for EventService
    set_tenant_context(tenant)
    set_superagent_context(event.superagent)

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
      },
    )
  rescue StandardError => e
    # Don't fail the job if event recording fails
    Rails.logger.error("Failed to fire notifications.delivered event: #{e.message}")
  ensure
    clear_context
  end

  sig { params(tenant: Tenant).void }
  def set_tenant_context(tenant)
    Tenant.current_subdomain = tenant.subdomain
    Tenant.current_id = tenant.id
    Tenant.current_main_superagent_id = tenant.main_superagent_id
  end

  sig { params(superagent: T.nilable(Superagent)).void }
  def set_superagent_context(superagent)
    return unless superagent

    Thread.current[:superagent_id] = superagent.id
    Thread.current[:superagent_handle] = superagent.handle
  end

  sig { void }
  def clear_context
    Tenant.clear_thread_scope
    Superagent.clear_thread_scope
  end
end
