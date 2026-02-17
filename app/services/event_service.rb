# typed: true

class EventService
  extend T::Sig

  sig do
    params(
      event_type: String,
      actor: T.nilable(User),
      subject: T.untyped,
      metadata: T::Hash[String, T.untyped]
    ).returns(T.nilable(Event))
  end
  def self.record!(event_type:, actor:, subject:, metadata: {})
    # Skip event creation if tenant/superagent context isn't set
    # This can happen in some test scenarios or background jobs without context
    return nil unless Tenant.current_id && Superagent.current_id

    event = Event.create!(
      tenant_id: Tenant.current_id,
      superagent_id: Superagent.current_id,
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
