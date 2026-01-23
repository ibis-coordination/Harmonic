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
    # Use unscoped to bypass default_scope since we need to find webhooks with different superagent_id values
    webhooks = Webhook.unscoped.where(tenant_id: event.tenant_id, enabled: true)

    # For user-specific events (like reminders), also match user-level webhooks
    if event.actor_id.present? && user_scoped_event?(event.event_type)
      # Match:
      # - Tenant-level webhooks (no superagent, no user)
      # - Studio-level webhooks for this studio
      # - User-level webhooks for the event actor
      webhooks = webhooks.where(
        "(superagent_id IS NULL AND user_id IS NULL) OR superagent_id = ? OR user_id = ?",
        event.superagent_id,
        event.actor_id,
      )
    else
      # Match:
      # - Tenant-level webhooks (no superagent, no user)
      # - Studio-level webhooks for this studio
      webhooks = webhooks.where(
        "(superagent_id IS NULL AND user_id IS NULL) OR superagent_id = ?",
        event.superagent_id,
      )
    end

    webhooks.to_a.select { |webhook| webhook.subscribed_to?(event.event_type) }
  end

  sig { params(event_type: String).returns(T::Boolean) }
  def self.user_scoped_event?(event_type)
    event_type.start_with?("reminders") || event_type.start_with?("notifications")
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
    studio = event.superagent
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
