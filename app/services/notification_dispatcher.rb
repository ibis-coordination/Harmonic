# typed: true

class NotificationDispatcher
  extend T::Sig

  sig { params(event: Event).void }
  def self.dispatch(event)
    case event.event_type
    when /^note\.(created|updated)$/
      handle_note_event(event)
    when "comment.created"
      handle_comment_event(event)
    when "decision.voted"
      handle_decision_vote_event(event)
    when "decision.resolved"
      handle_decision_resolved_event(event)
    when "commitment.joined"
      handle_commitment_join_event(event)
    when "commitment.critical_mass"
      handle_commitment_critical_mass_event(event)
    when /^agent\./
      handle_agent_event(event)
    end
  end

  sig { params(event: Event).void }
  def self.handle_note_event(event)
    subject = event.subject
    return unless subject.is_a?(Note)

    note = T.let(subject, Note)

    # Find mentioned users from the note text
    mentioned_users = MentionParser.parse(note.text, tenant_id: event.tenant_id)

    # Don't notify the actor (they mentioned themselves)
    mentioned_users = mentioned_users.reject { |u| u.id == event.actor_id }

    mentioned_users.each do |user|
      actor_name = event.actor&.display_name || "Someone"

      notify_user(
        event: event,
        recipient: user,
        notification_type: "mention",
        title: "#{actor_name} mentioned you",
        body: note.text.to_s.truncate(200),
        url: note.path
      )
    end
  end

  sig { params(event: Event).void }
  def self.handle_comment_event(event)
    subject = event.subject
    return unless subject.is_a?(Note)

    comment = T.let(subject, Note)
    commentable = comment.commentable
    return unless commentable

    # Notify the owner of the content being commented on
    owner = get_created_by(commentable)
    return if owner.nil? || owner.id == event.actor_id

    actor_name = event.actor&.display_name || "Someone"
    content_type = commentable.class.name.underscore.humanize.downcase

    notify_user(
      event: event,
      recipient: owner,
      notification_type: "comment",
      title: "#{actor_name} commented on your #{content_type}",
      body: comment.text.to_s.truncate(200),
      url: get_path(commentable)
    )
  end

  sig { params(event: Event).void }
  def self.handle_decision_vote_event(event)
    subject = event.subject
    return unless subject.is_a?(Decision)

    decision = T.let(subject, Decision)

    owner = decision.created_by
    return if owner.nil? || owner.id == event.actor_id

    actor_name = event.actor&.display_name || "Someone"
    vote_type = event.metadata&.dig("vote_type") || "voted"

    notify_user(
      event: event,
      recipient: owner,
      notification_type: "participation",
      title: "#{actor_name} #{vote_type} on your decision",
      body: decision.description.to_s.truncate(200),
      url: decision.path
    )
  end

  sig { params(event: Event).void }
  def self.handle_decision_resolved_event(event)
    subject = event.subject
    return unless subject.is_a?(Decision)

    decision = T.let(subject, Decision)

    # Notify all participants except the one who resolved it
    participants = decision_participants(decision)
    participants = participants.reject { |u| u.id == event.actor_id }

    participants.each do |user|
      notify_user(
        event: event,
        recipient: user,
        notification_type: "participation",
        title: "A decision you participated in was resolved",
        body: decision.description.to_s.truncate(200),
        url: decision.path
      )
    end
  end

  sig { params(event: Event).void }
  def self.handle_commitment_join_event(event)
    subject = event.subject
    return unless subject.is_a?(Commitment)

    commitment = T.let(subject, Commitment)

    owner = commitment.created_by
    return if owner.nil? || owner.id == event.actor_id

    actor_name = event.actor&.display_name || "Someone"

    notify_user(
      event: event,
      recipient: owner,
      notification_type: "participation",
      title: "#{actor_name} joined your commitment",
      body: commitment.description.to_s.truncate(200),
      url: commitment.path
    )
  end

  sig { params(event: Event).void }
  def self.handle_commitment_critical_mass_event(event)
    subject = event.subject
    return unless subject.is_a?(Commitment)

    commitment = T.let(subject, Commitment)

    # Notify all participants
    participants = commitment_participants(commitment)
    participants = participants.reject { |u| u.id == event.actor_id }

    participants.each do |user|
      notify_user(
        event: event,
        recipient: user,
        notification_type: "participation",
        title: "Critical mass reached on a commitment you joined",
        body: commitment.description.to_s.truncate(200),
        url: commitment.path
      )
    end
  end

  sig { params(event: Event).void }
  def self.handle_agent_event(event)
    # Agent events are system notifications to specific users
    # These will be implemented when the AI agent feature is built
    # For now, this is a placeholder
  end

  # Helper method to create notifications with preference-based channel selection
  sig do
    params(
      event: Event,
      recipient: User,
      notification_type: String,
      title: String,
      body: T.nilable(String),
      url: T.nilable(String)
    ).void
  end
  # rubocop:disable Metrics/ParameterLists
  def self.notify_user(event:, recipient:, notification_type:, title:, body: nil, url: nil)
    # rubocop:enable Metrics/ParameterLists
    channels = channels_for_user(recipient, notification_type)
    return if channels.empty?

    NotificationService.create_and_deliver!(
      event: event,
      recipient: recipient,
      notification_type: notification_type,
      title: title,
      body: body,
      url: url,
      channels: channels
    )
  end

  # Get the appropriate channels based on user preferences
  sig { params(user: User, notification_type: String).returns(T::Array[String]) }
  def self.channels_for_user(user, notification_type)
    tenant_user = user.tenant_user
    return ["in_app"] unless tenant_user

    tenant_user.notification_channels_for(notification_type)
  end

  # Helper to safely get created_by from polymorphic objects
  sig { params(obj: T.untyped).returns(T.nilable(User)) }
  def self.get_created_by(obj)
    return nil unless obj.respond_to?(:created_by)

    obj.created_by
  end

  # Helper to safely get path from polymorphic objects
  sig { params(obj: T.untyped).returns(T.nilable(String)) }
  def self.get_path(obj)
    return nil unless obj.respond_to?(:path)

    obj.path
  end

  sig { params(decision: Decision).returns(T::Array[User]) }
  def self.decision_participants(decision)
    # Get all users who voted on this decision
    decision.decision_participants.includes(:user).map(&:user).compact
  end

  sig { params(commitment: Commitment).returns(T::Array[User]) }
  def self.commitment_participants(commitment)
    # Get all users who joined this commitment
    commitment.participants.includes(:user).map(&:user).compact
  end

  private_class_method :get_created_by, :get_path, :decision_participants, :commitment_participants
end
