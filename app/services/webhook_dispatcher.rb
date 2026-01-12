# typed: true

class WebhookDispatcher
  extend T::Sig

  SYSTEM_EVENT_PREFIX = "agent."

  sig { params(event: Event).void }
  def self.dispatch(event)
    # Skip system events (not exposed via webhooks)
    return if event.event_type.start_with?(SYSTEM_EVENT_PREFIX)

    webhooks = find_matching_webhooks(event)
    webhooks.each do |webhook|
      create_and_enqueue_delivery(event, webhook)
    end
  end

  sig { params(event: Event).returns(T::Array[Webhook]) }
  def self.find_matching_webhooks(event)
    Webhook.where(tenant_id: event.tenant_id, enabled: true)
      .where("studio_id IS NULL OR studio_id = ?", event.studio_id)
      .to_a
      .select { |webhook| webhook.subscribed_to?(event.event_type) }
  end

  sig { params(event: Event, webhook: Webhook).returns(WebhookDelivery) }
  def self.create_and_enqueue_delivery(event, webhook)
    delivery = WebhookDelivery.create!(
      webhook: webhook,
      event: event,
      status: "pending",
      attempt_count: 0,
      request_body: build_payload(event, webhook),
    )

    WebhookDeliveryJob.perform_later(delivery.id)
    delivery
  end

  sig { params(event: Event, webhook: Webhook).returns(String) }
  def self.build_payload(event, webhook)
    tenant = event.tenant
    studio = event.studio
    actor = event.actor

    payload = {
      id: event.id,
      type: event.event_type,
      created_at: event.created_at.iso8601,
      tenant: tenant ? {
        id: tenant.id,
        subdomain: tenant.subdomain,
      } : nil,
      studio: studio ? {
        id: studio.id,
        handle: studio.handle,
        name: studio.name,
      } : nil,
      actor: actor ? {
        id: actor.id,
        handle: actor.tenant_user&.handle,
        name: actor.name,
      } : nil,
      data: build_event_data(event),
    }

    payload.to_json
  end

  sig { params(event: Event).returns(T::Hash[Symbol, T.untyped]) }
  def self.build_event_data(event)
    subject = event.subject
    return {} unless subject

    case subject
    when Note
      {
        note: {
          id: subject.id,
          truncated_id: subject.truncated_id,
          text: subject.text.to_s.truncate(500),
          path: subject.path,
        },
      }
    when Decision
      {
        decision: {
          id: subject.id,
          truncated_id: subject.truncated_id,
          description: subject.description.to_s.truncate(500),
          path: subject.path,
        },
      }
    when Commitment
      {
        commitment: {
          id: subject.id,
          truncated_id: subject.truncated_id,
          description: subject.description.to_s.truncate(500),
          path: subject.path,
        },
      }
    else
      { subject_type: subject.class.name, subject_id: subject.id }
    end
  end
end
