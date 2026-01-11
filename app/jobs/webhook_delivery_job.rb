# typed: true

class WebhookDeliveryJob < ApplicationJob
  extend T::Sig

  queue_as :webhooks

  sig { params(delivery_id: String).void }
  def perform(delivery_id)
    delivery = WebhookDelivery.find_by(id: delivery_id)
    return unless delivery
    return if delivery.success?

    webhook = delivery.webhook
    return unless webhook&.enabled?

    WebhookDeliveryService.deliver!(delivery)
  end
end
