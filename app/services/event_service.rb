# typed: true

class EventService
  extend T::Sig

  sig do
    params(
      event_type: String,
      actor: T.nilable(User),
      subject: T.untyped,
      metadata: T::Hash[String, T.untyped],
      tenant_id: T.nilable(String),
      collective_id: T.nilable(String)
    ).returns(T.nilable(Event))
  end
  def self.record!(event_type:, actor:, subject:, metadata: {}, tenant_id: nil, collective_id: nil)
    # Explicit tenant/collective for events whose home isn't the request's
    # thread context (e.g. accepting an invite to another collective from the
    # bare tenant subdomain). Defaults to the thread context.
    tenant_id ||= Tenant.current_id
    collective_id ||= Collective.current_id
    # Skip event creation if tenant/collective context isn't set
    # This can happen in some test scenarios or background jobs without context
    return nil unless tenant_id && collective_id

    event = Event.create!(
      tenant_id: tenant_id,
      collective_id: collective_id,
      event_type: event_type,
      actor: actor,
      subject: subject,
      metadata: metadata
    )

    # Dispatch to notification and webhook systems
    # These will be implemented in later phases
    dispatch_to_handlers(event)

    event
  end

  sig { params(event: Event).void }
  def self.dispatch_to_handlers(event)
    NotificationDispatcher.dispatch(event)
    AutomationDispatcher.dispatch(event)
  end
end
