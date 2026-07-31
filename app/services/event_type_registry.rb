# typed: true

# The single declaration of every event type the system emits, and its
# audience. The audience decides who may react to an event:
#
#   :collective       — content events. Any automation rule with access to the
#                       event's collective may match.
#   :single_recipient — delivery events. `event.actor` is the recipient (the
#                       user being notified), and only rules owned by the
#                       recipient may match. Dispatching these through
#                       collective matching would leak one member's
#                       notification payloads to other members' webhooks.
#
# EventService refuses to emit unregistered types outside production, so a new
# event type must be declared here — with an audience — to exist.
class EventTypeRegistry
  extend T::Sig

  class UnknownEventType < StandardError; end

  # Models including Tracked emit "<prefix>.created/.updated/.deleted".
  # Note emits under "comment" when the record is a comment.
  TRACKED_PREFIXES = T.let(%w[
    chat_message
    comment
    commitment
    decision
    note
    option
    user_list_member
    vote
  ].freeze, T::Array[String])

  # DeadlineEventJob emits "<model>.deadline_reached" for these models.
  DEADLINE_PREFIXES = T.let(%w[commitment decision].freeze, T::Array[String])

  TYPES = T.let(
    begin
      types = {}
      TRACKED_PREFIXES.each do |prefix|
        %w[created updated deleted].each { |verb| types["#{prefix}.#{verb}"] = :collective }
      end
      DEADLINE_PREFIXES.each { |prefix| types["#{prefix}.deadline_reached"] = :collective }
      types["commitment.joined"] = :collective
      types["commitment.critical_mass"] = :collective
      types["invite.accepted"] = :collective
      types["collective_member.role_granted"] = :collective
      types["notifications.delivered"] = :single_recipient
      types["reminders.delivered"] = :single_recipient
      types.freeze
    end,
    T::Hash[String, Symbol]
  )

  sig { params(event_type: String).returns(T::Boolean) }
  def self.registered?(event_type)
    TYPES.key?(event_type)
  end

  sig { params(event_type: String).returns(Symbol) }
  def self.audience_for(event_type)
    TYPES.fetch(event_type) do
      raise UnknownEventType, "Unregistered event type: #{event_type.inspect}"
    end
  end

  # Non-raising: dispatch must not fail on a type that slipped past
  # verification in production. Unknown types take the collective path,
  # whose access checks still apply.
  sig { params(event_type: String).returns(T::Boolean) }
  def self.single_recipient?(event_type)
    TYPES[event_type] == :single_recipient
  end

  sig { params(event_type: String).void }
  def self.verify!(event_type)
    return if registered?(event_type)

    unless Rails.env.production?
      raise UnknownEventType, "Unregistered event type: #{event_type.inspect} — declare it in EventTypeRegistry"
    end

    Rails.logger.error("[EventTypeRegistry] Unregistered event type emitted: #{event_type}")
  end
end
