# typed: true

class WebhookTestService
  extend T::Sig

  sig { params(webhook: Webhook, user: User).void }
  def self.send_test!(webhook, user)
    # Create a test event
    test_event = Event.create!(
      tenant_id: webhook.tenant_id,
      superagent_id: webhook.superagent_id,
      event_type: "webhook.test",
      actor: user,
      subject: webhook,
      metadata: { test: true },
    )

    # Create and dispatch the delivery
    delivery = WebhookDelivery.create!(
      webhook: webhook,
      event: test_event,
      status: "pending",
      attempt_count: 0,
      request_body: build_test_payload(webhook, user),
    )

    WebhookDeliveryJob.perform_later(delivery.id)
  end

  sig { params(webhook: Webhook, user: User).returns(String) }
  def self.build_test_payload(webhook, user)
    tenant = Tenant.find_by(id: webhook.tenant_id)
    studio = Superagent.unscoped.find_by(id: webhook.superagent_id)

    payload = {
      id: SecureRandom.uuid,
      type: "webhook.test",
      created_at: Time.current.iso8601,
      tenant: tenant ? {
        id: tenant.id,
        subdomain: tenant.subdomain,
      } : nil,
      studio: studio ? {
        id: studio.id,
        handle: studio.handle,
        name: studio.name,
      } : nil,
      actor: {
        id: user.id,
        handle: user.tenant_user&.handle,
        name: user.name,
      },
      data: {
        message: "This is a test webhook delivery.",
        webhook_id: webhook.id,
        webhook_name: webhook.name,
      },
    }

    payload.to_json
  end
end
