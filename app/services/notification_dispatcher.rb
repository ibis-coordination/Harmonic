# typed: true

class NotificationDispatcher
  extend T::Sig

  sig { params(event: Event).void }
  def self.dispatch(event)
    case T.unsafe(event).event_type
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
    subject = T.unsafe(event).subject
    return unless subject.is_a?(Note)

    note = T.let(subject, Note)

    # Find mentioned users from the note text
    mentioned_users = MentionParser.parse(note.text, tenant_id: T.unsafe(event).tenant_id)

    # Don't notify the actor (they mentioned themselves)
    mentioned_users = mentioned_users.reject { |u| u.id == T.unsafe(event).actor_id }

    mentioned_users.each do |user|
      actor_name = T.unsafe(event).actor&.display_name || "Someone"

      NotificationService.create_and_deliver!(
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
    subject = T.unsafe(event).subject
    return unless subject.is_a?(Note)

    comment = T.let(subject, Note)
    return unless comment.commentable

    # Notify the owner of the content being commented on
    commentable = comment.commentable
    return unless commentable.respond_to?(:created_by)

    owner = T.unsafe(commentable).created_by
    return if owner.nil? || owner.id == T.unsafe(event).actor_id

    actor_name = T.unsafe(event).actor&.display_name || "Someone"
    content_type = T.must(commentable).class.name.underscore.humanize.downcase

    NotificationService.create_and_deliver!(
      event: event,
      recipient: owner,
      notification_type: "comment",
      title: "#{actor_name} commented on your #{content_type}",
      body: comment.text.to_s.truncate(200),
      url: T.unsafe(commentable).path
    )
  end

  sig { params(event: Event).void }
  def self.handle_decision_vote_event(event)
    subject = T.unsafe(event).subject
    return unless subject.is_a?(Decision)

    decision = T.let(subject, Decision)

    owner = decision.created_by
    return if owner.nil? || owner.id == T.unsafe(event).actor_id

    actor_name = T.unsafe(event).actor&.display_name || "Someone"
    vote_type = T.unsafe(event).metadata&.dig("vote_type") || "voted"

    NotificationService.create_and_deliver!(
      event: event,
      recipient: owner,
      notification_type: "participation",
      title: "#{actor_name} #{vote_type} on your decision",
      body: T.unsafe(decision).description.to_s.truncate(200),
      url: decision.path
    )
  end

  sig { params(event: Event).void }
  def self.handle_decision_resolved_event(event)
    subject = T.unsafe(event).subject
    return unless subject.is_a?(Decision)

    decision = T.let(subject, Decision)

    # Notify all participants except the one who resolved it
    participants = decision_participants(decision)
    participants = participants.reject { |u| u.id == T.unsafe(event).actor_id }

    participants.each do |user|
      NotificationService.create_and_deliver!(
        event: event,
        recipient: user,
        notification_type: "participation",
        title: "A decision you participated in was resolved",
        body: T.unsafe(decision).description.to_s.truncate(200),
        url: decision.path
      )
    end
  end

  sig { params(event: Event).void }
  def self.handle_commitment_join_event(event)
    subject = T.unsafe(event).subject
    return unless subject.is_a?(Commitment)

    commitment = T.let(subject, Commitment)

    owner = commitment.created_by
    return if owner.nil? || owner.id == T.unsafe(event).actor_id

    actor_name = T.unsafe(event).actor&.display_name || "Someone"

    NotificationService.create_and_deliver!(
      event: event,
      recipient: owner,
      notification_type: "participation",
      title: "#{actor_name} joined your commitment",
      body: T.unsafe(commitment).description.to_s.truncate(200),
      url: commitment.path
    )
  end

  sig { params(event: Event).void }
  def self.handle_commitment_critical_mass_event(event)
    subject = T.unsafe(event).subject
    return unless subject.is_a?(Commitment)

    commitment = T.let(subject, Commitment)

    # Notify all participants
    participants = commitment_participants(commitment)
    participants = participants.reject { |u| u.id == T.unsafe(event).actor_id }

    participants.each do |user|
      NotificationService.create_and_deliver!(
        event: event,
        recipient: user,
        notification_type: "participation",
        title: "Critical mass reached on a commitment you joined",
        body: T.unsafe(commitment).description.to_s.truncate(200),
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

  private_class_method def self.decision_participants(decision)
    # Get all users who voted on this decision
    if decision.respond_to?(:decision_participants)
      T.unsafe(decision).decision_participants.includes(:user).map(&:user).compact
    else
      []
    end
  end

  private_class_method def self.commitment_participants(commitment)
    # Get all users who joined this commitment
    if commitment.respond_to?(:commitment_participants)
      T.unsafe(commitment).commitment_participants.includes(:user).map(&:user).compact
    else
      []
    end
  end
end
