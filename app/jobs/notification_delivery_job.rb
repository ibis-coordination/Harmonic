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
    when "web_push"
      deliver_web_push(recipient)
    end
  end

  private

  # Fan out one WebPushDeliveryJob per active subscription (device). The
  # recipient row is "delivered" once handed off; per-device outcomes land on
  # the subscription rows (revocation, error forensics).
  sig { params(recipient: NotificationRecipient).void }
  def deliver_web_push(recipient)
    user = recipient.user
    return recipient.mark_delivered! if user.nil? || !user.human?

    user.web_push_subscriptions.active.find_each do |subscription|
      WebPushDeliveryJob.perform_later(T.must(recipient.id), subscription.id)
    end
    recipient.mark_delivered!
  end

  sig { params(recipient: NotificationRecipient).void }
  def deliver_email(recipient)
    user = recipient.user
    # Skip email delivery for users without a routable address. Non-human users
    # (ai_agent, collective_identity) carry a syntactically valid but unroutable
    # placeholder address (e.g. "<uuid>@not-a-real-email.com"), so a blank check
    # alone lets them through. Guarding on human? covers existing DB rows without
    # a backfill — this is the load-bearing layer.
    return recipient.mark_delivered! if user.nil? || !user.human? || user.email.blank?

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
