# typed: true

class NotificationDeliveryJob < ApplicationJob
  extend T::Sig

  queue_as :default

  sig { params(notification_recipient_id: String).void }
  def perform(notification_recipient_id)
    recipient = NotificationRecipient.find_by(id: notification_recipient_id)
    return unless recipient
    return if T.unsafe(recipient).status == "delivered"

    # In Phase 6, email delivery will be added:
    # if T.unsafe(recipient).channel == "email"
    #   NotificationMailer.notification_email(recipient).deliver_now
    # end
    recipient.mark_delivered!
  end
end
