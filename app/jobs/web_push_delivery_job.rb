# typed: true
# frozen_string_literal: true

# Sends one notification to one of the recipient's push subscriptions.
# Fan-out (one job per active subscription) happens in NotificationDeliveryJob.
class WebPushDeliveryJob < TenantScopedJob
  extend T::Sig

  queue_as :default

  # Rate limiting and push-service hiccups are transient; back off and retry.
  # Other response errors are terminal for this attempt and handled below.
  retry_on WebPush::TooManyRequests, WebPush::PushServiceError, wait: :polynomially_longer, attempts: 5

  sig { params(notification_recipient_id: String, subscription_id: String).void }
  def perform(notification_recipient_id, subscription_id)
    recipient = NotificationRecipient.unscoped_for_system_job.find_by(id: notification_recipient_id)
    subscription = WebPushSubscription.find_by(id: subscription_id)
    return unless recipient && subscription&.active?

    notification = recipient.notification
    tenant = notification&.tenant
    return unless notification && tenant

    set_tenant_context!(tenant)
    deliver!(subscription, notification, tenant)
  end

  private

  sig { params(subscription: WebPushSubscription, notification: Notification, tenant: Tenant).void }
  def deliver!(subscription, notification, tenant)
    WebPush.payload_send(
      message: payload(notification, tenant).to_json,
      endpoint: subscription.endpoint,
      p256dh: subscription.p256dh_key,
      auth: subscription.auth_key,
      vapid: {
        subject: vapid_subject,
        public_key: ENV.fetch("VAPID_PUBLIC_KEY", nil),
        private_key: ENV.fetch("VAPID_PRIVATE_KEY", nil),
      }
    )
  rescue WebPush::ExpiredSubscription, WebPush::InvalidSubscription
    # The push service no longer knows this endpoint — the browser rotated or
    # dropped the subscription. Revoke; a live device will re-subscribe.
    subscription.revoke!(reason: "gone")
  rescue WebPush::Unauthorized
    # Our VAPID signature doesn't match the key the subscription was minted
    # with (key rotation). The subscription can never deliver with the
    # current keys; revoking it lets the client-side repair path run — the
    # settings page stops claiming "enabled" and re-subscribing mints a
    # fresh subscription against the new key.
    subscription.revoke!(reason: "unauthorized")
  rescue WebPush::TooManyRequests, WebPush::PushServiceError
    raise # handled by retry_on
  rescue WebPush::ResponseError => e
    subscription.record_error!("#{e.class.to_s.demodulize}: #{e.message}")
  end

  sig { params(notification: Notification, tenant: Tenant).returns(T::Hash[Symbol, T.untyped]) }
  def payload(notification, tenant)
    {
      title: notification.title,
      body: notification.body,
      url: absolute_url(notification, tenant),
      icon: "/harmonic-icon-192.png",
      badge: "/harmonic-icon-192.png",
      notification_type: notification.notification_type,
      notification_id: notification.id,
    }
  end

  # Notification#url is a relative path; the push payload needs an absolute
  # URL on the notification's tenant host. Subscriptions are user-global, so
  # this may be a different origin than the one the subscription was created
  # on — the SW opens cross-origin deep links with clients.openWindow.
  sig { params(notification: Notification, tenant: Tenant).returns(String) }
  def absolute_url(notification, tenant)
    path = notification.url
    path.present? ? "#{tenant.url}#{path}" : tenant.url
  end

  sig { returns(String) }
  def vapid_subject
    ENV["VAPID_SUBJECT"].presence || "https://#{ENV.fetch("HOSTNAME", nil)}"
  end
end
