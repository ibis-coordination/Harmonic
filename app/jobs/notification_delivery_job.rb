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
end
