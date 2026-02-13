# typed: true
# frozen_string_literal: true

class WebhookDeliveryJob < TenantScopedJob
  extend T::Sig

  queue_as :webhooks

  sig { params(delivery_id: String).void }
  def perform(delivery_id)
    # Load delivery without tenant context (middleware cleared it)
    # WebhookDelivery has tenant_id, so we can use unscoped_for_system_job
    delivery = WebhookDelivery.unscoped_for_system_job.find_by(id: delivery_id)
    return unless delivery
    return if delivery.success?

    # Set tenant context from the delivery
    set_tenant_context!(delivery.tenant)

    webhook = delivery.webhook
    return unless webhook&.enabled?

    WebhookDeliveryService.deliver!(delivery)
  end
end
