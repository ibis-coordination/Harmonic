# typed: true

class NotificationDispatcher
  extend T::Sig

  sig { params(event: Event).void }
  def self.dispatch(event)
    case event.event_type
    when /^(note|comment)\.(created|updated)$/
      handle_note_event(event)
    when "vote.created"
      handle_vote_event(event)
    when "decision.deadline_reached"
      handle_decision_resolved_event(event)
    when "commitment.joined"
      handle_commitment_join_event(event)
    when "commitment.critical_mass"
      handle_commitment_critical_mass_event(event)
    when "decision.created"
      handle_decision_created_event(event)
    when "commitment.created"
      handle_commitment_created_event(event)
    when "option.created"
      handle_option_created_event(event)
    when "user_list_member.created"
      handle_member_added_event(event)
    when "collective_member.role_granted"
      handle_role_granted_event(event)
    when /^agent\./
      handle_agent_event(event)
    end
  end

  # Notify a member that they were granted a collective role (admin,
  # representative, or summarizer), naming who granted it (issue #340).
  sig { params(event: Event).void }
  def self.handle_role_granted_event(event)
    membership = event.subject
    return unless membership.is_a?(CollectiveMember)

    recipient = membership.user
    collective = membership.collective
    return if collective.nil?
    # Don't notify an admin who edited their own roles.
    return if event.actor_id && recipient.id == event.actor_id

    role = event.metadata.is_a?(Hash) ? event.metadata["role"].to_s : ""
    return if role.blank?

    granter = T.unsafe(event).actor
    granter_name = granter&.display_name || "An admin"
    title = "#{granter_name} made you #{role_phrase(role)} of #{collective.name}"

    notify_user(
      event: event,
      recipient: recipient,
      notification_type: "role_change",
      title: title,
      url: "#{collective.path}/members"
    )
  end

  # "an admin" / "a representative" / "a summarizer" — falls back to a bare
  # "the <role> role" for any future role that doesn't read well with an article.
  sig { params(role: String).returns(String) }
  def self.role_phrase(role)
    case role
    when "admin" then "an admin"
    when "representative" then "a representative"
    when "summarizer" then "a summarizer"
    else "the #{role} role"
    end
  end

  sig { params(event: Event).void }
  def self.handle_member_added_event(event)
    membership = event.subject
    return unless membership.is_a?(UserListMember)

    list = membership.user_list
    target = membership.user
    return if target.nil? || list.nil?
    return if event.actor_id && target.id == event.actor_id
    return unless list.is_primary || list.public?
    return if recent_tune_in_notification_exists?(event: event, recipient: target)

    title, url = member_added_title_and_url(event, list)
    notify_user(
      event: event,
      recipient: target,
      notification_type: "tune_in",
      title: title,
      url: url
    )
  end

  # Suppresses a fresh tune_in notification when the recipient already has
  # an unread one from the same actor in the same tenant. Prevents rapid
  # tune-out / tune-in cycles from spamming the target's inbox. Once the
  # notification is read or dismissed, a re-tune-in is news again.
  sig { params(event: Event, recipient: User).returns(T::Boolean) }
  def self.recent_tune_in_notification_exists?(event:, recipient:)
    return false if event.actor_id.nil?

    NotificationRecipient
      .joins(:notification)
      .joins("INNER JOIN events ON events.id = notifications.event_id")
      .where(user_id: recipient.id, tenant_id: event.tenant_id, dismissed_at: nil, read_at: nil)
      .where(notifications: { notification_type: "tune_in" })
      .exists?(events: { actor_id: event.actor_id })
  end

  sig { params(event: Event, list: UserList).returns([String, T.nilable(String)]) }
  def self.member_added_title_and_url(event, list)
    actor_name = event.actor&.display_name || "Someone"
    if list.is_primary
      handle = actor_tenant_handle(event)
      ["#{actor_name} tuned in to you", handle ? "/u/#{handle}" : nil]
    else
      ["#{actor_name} added you to their list \"#{list.display_name}\"", list.path]
    end
  end

  sig { params(event: Event).returns(T.nilable(String)) }
  def self.actor_tenant_handle(event)
    actor = event.actor
    return nil if actor.nil?

    actor.tenant_users.find_by(tenant_id: event.tenant_id)&.handle
  end

  sig { params(event: Event).void }
  def self.handle_note_event(event)
    subject = event.subject
    return unless subject.is_a?(Note)

    note = T.let(subject, Note)

    # If this note is a comment/reply, notify the parent content owner
    handle_reply_notification(event, note) if note.is_comment?

    # Find mentioned users from the note text
    mentioned_users = MentionParser.parse(note.text, tenant_id: event.tenant_id, collective: note.collective)

    # Don't notify the actor (they mentioned themselves)
    mentioned_users = mentioned_users.reject { |u| u.id == event.actor_id }

    # Only notify users who have access to the collective
    mentioned_users = mentioned_users.select { |u| user_can_access_collective?(event, u) }

    mentioned_users.each do |user|
      actor_name = event.actor&.display_name || "Someone"

      notify_user(
        event: event,
        recipient: user,
        notification_type: "mention",
        title: "#{actor_name} mentioned you",
        body: note.text.to_s.truncate(200),
        url: note.display_path
      )
    end

    maybe_send_trio_unavailable_hint(event, note.text, note.collective)
  end

  # Handle reply notifications when a note is a comment on another piece of content.
  # This is called from handle_note_event when the note has a commentable.
  sig { params(event: Event, comment: Note).void }
  def self.handle_reply_notification(event, comment)
    commentable = comment.commentable
    return unless commentable

    owner = get_created_by(commentable)
    return if owner.nil? || owner.id == event.actor_id
    return unless user_can_access_collective?(event, owner)

    actor_name = event.actor&.display_name || "Someone"
    content_type = commentable.class.name.underscore.humanize.downcase

    notify_user(
      event: event,
      recipient: owner,
      notification_type: "comment",
      title: "#{actor_name} replied to your #{content_type}",
      body: comment.text.to_s.truncate(200),
      # Link to the reply itself (so `?comment_id=` highlights the new reply),
      # not the comment being replied to.
      url: get_path(comment)
    )
  end

  sig { params(event: Event).void }
  def self.handle_vote_event(event)
    subject = event.subject
    return unless subject.is_a?(Vote)

    decision = T.let(subject, Vote).decision
    return if decision.nil?

    owner = decision.created_by
    return if owner.nil? || owner.id == event.actor_id
    return if recent_vote_notification_exists?(event: event, decision: decision, recipient: owner)

    actor_name = event.actor&.display_name || "Someone"

    notify_user(
      event: event,
      recipient: owner,
      notification_type: "participation",
      title: "#{actor_name} voted on your decision",
      body: decision.description.to_s.truncate(200),
      url: decision.display_path
    )
  end

  # Suppresses repeat vote notifications while the recipient still has an
  # unread one from the same voter on the same decision. A ballot is one vote
  # row per option, so without this a single ballot would notify N times.
  sig { params(event: Event, decision: Decision, recipient: User).returns(T::Boolean) }
  def self.recent_vote_notification_exists?(event:, decision:, recipient:)
    return false if event.actor_id.nil?

    NotificationRecipient
      .joins(:notification)
      .joins("INNER JOIN events ON events.id = notifications.event_id")
      .where(user_id: recipient.id, tenant_id: event.tenant_id, dismissed_at: nil, read_at: nil)
      .where(notifications: { notification_type: "participation", url: decision.display_path })
      .exists?(events: { actor_id: event.actor_id, event_type: "vote.created" })
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
        url: decision.display_path
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
      url: commitment.display_path
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
        url: commitment.display_path
      )
    end
  end

  sig { params(event: Event).void }
  def self.handle_agent_event(event)
    # Agent events are system notifications to specific users
    # These will be implemented when the AI agent feature is built
    # For now, this is a placeholder
  end

  sig { params(event: Event).void }
  def self.handle_decision_created_event(event)
    subject = event.subject
    return unless subject.is_a?(Decision)

    decision = T.let(subject, Decision)

    # Parse mentions from question and description fields
    text_to_parse = [decision.question, decision.description].compact.join(" ")
    mentioned_users = MentionParser.parse(text_to_parse, tenant_id: event.tenant_id, collective: decision.collective)

    # Don't notify the actor (they mentioned themselves)
    mentioned_users = mentioned_users.reject { |u| u.id == event.actor_id }

    # Only notify users who have access to the collective
    mentioned_users = mentioned_users.select { |u| user_can_access_collective?(event, u) }

    mentioned_users.each do |user|
      actor_name = event.actor&.display_name || "Someone"

      notify_user(
        event: event,
        recipient: user,
        notification_type: "mention",
        title: "#{actor_name} mentioned you in a decision",
        body: decision.question.to_s.truncate(200),
        url: decision.display_path
      )
    end

    maybe_send_trio_unavailable_hint(event, text_to_parse, decision.collective)
  end

  sig { params(event: Event).void }
  def self.handle_commitment_created_event(event)
    subject = event.subject
    return unless subject.is_a?(Commitment)

    commitment = T.let(subject, Commitment)

    # Parse mentions from title and description fields
    text_to_parse = [commitment.title, commitment.description].compact.join(" ")
    mentioned_users = MentionParser.parse(text_to_parse, tenant_id: event.tenant_id, collective: commitment.collective)

    # Don't notify the actor (they mentioned themselves)
    mentioned_users = mentioned_users.reject { |u| u.id == event.actor_id }

    # Only notify users who have access to the collective
    mentioned_users = mentioned_users.select { |u| user_can_access_collective?(event, u) }

    mentioned_users.each do |user|
      actor_name = event.actor&.display_name || "Someone"

      notify_user(
        event: event,
        recipient: user,
        notification_type: "mention",
        title: "#{actor_name} mentioned you in a commitment",
        body: commitment.title.to_s.truncate(200),
        url: commitment.display_path
      )
    end

    maybe_send_trio_unavailable_hint(event, text_to_parse, commitment.collective)
  end

  sig { params(event: Event).void }
  def self.handle_option_created_event(event)
    subject = event.subject
    return unless subject.is_a?(Option)

    option = T.let(subject, Option)
    decision = option.decision

    # Parse mentions from title and description fields
    text_to_parse = [option.title, option.description].compact.join(" ")
    mentioned_users = MentionParser.parse(text_to_parse, tenant_id: event.tenant_id, collective: option.collective)

    # Don't notify the actor (they mentioned themselves)
    mentioned_users = mentioned_users.reject { |u| u.id == event.actor_id }

    # Only notify users who have access to the collective
    mentioned_users = mentioned_users.select { |u| user_can_access_collective?(event, u) }

    mentioned_users.each do |user|
      actor_name = event.actor&.display_name || "Someone"

      notify_user(
        event: event,
        recipient: user,
        notification_type: "mention",
        title: "#{actor_name} mentioned you in a decision option",
        body: option.title.to_s.truncate(200),
        url: decision&.display_path
      )
    end

    maybe_send_trio_unavailable_hint(event, text_to_parse, option.collective)
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
    # Suppress notifications when recipient has blocked the actor
    return if event.actor_id && T.unsafe(event).actor && UserBlock.between?(recipient, T.unsafe(event).actor)

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

  # If @trio appears in mention-bearing content and the collective hasn't
  # enabled trio, send a one-shot hint notification to the actor so they know
  # why nothing happened. Agents receive this just like humans do — an agent
  # whose automation posts @trio still needs to know the mention went nowhere
  # so its owner can fix it. The trio-as-actor case is naturally excluded by
  # the trio_user check above: if trio is the actor, trio_user is set.
  sig do
    params(
      event: Event,
      text: T.nilable(String),
      collective: T.nilable(Collective)
    ).void
  end
  def self.maybe_send_trio_unavailable_hint(event, text, collective)
    return if text.blank?
    return unless collective
    return unless MentionParser.extract_handles(text).include?(MentionParser::TRIO_HANDLE)
    return if collective.trio_user

    actor = event.actor
    return unless actor

    # In a private workspace there's no collective settings page — the trio
    # opt-in lives in user settings. For other collectives we use the model's
    # path helper, which returns nil for the main collective (intentional —
    # main collective settings live in tenant admin, not under /collectives/);
    # in that edge case the notification carries no link.
    if collective.private_workspace?
      settings_url = "/settings"
      body = "You mentioned @trio in your workspace, but Trio isn't enabled there. " \
             "Enable it in your user settings."
    else
      settings_url = collective.path ? "#{collective.path}/settings" : nil
      body = "You mentioned @trio, but Trio isn't enabled in this collective. " \
             "Ask an admin to enable it in collective settings."
    end

    notify_user(
      event: event,
      recipient: actor,
      notification_type: "trio_unavailable",
      title: "Trio isn't enabled in #{collective.name}",
      body: body,
      url: settings_url
    )
  end

  # Helper to safely get created_by from polymorphic objects
  sig { params(obj: T.untyped).returns(T.nilable(User)) }
  def self.get_created_by(obj)
    return nil unless obj.respond_to?(:created_by)

    obj.created_by
  end

  # Helper to safely get the display URL from polymorphic objects. Uses
  # `display_path` so comment-subtype Notes surface the in-thread URL
  # (`{root}?comment_id={id}`) — recipients land on the full conversation.
  sig { params(obj: T.untyped).returns(T.nilable(String)) }
  def self.get_path(obj)
    return nil unless obj.respond_to?(:display_path)

    obj.display_path
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

  # Check if a user has access to the collective where the event occurred
  sig { params(event: Event, user: User).returns(T::Boolean) }
  def self.user_can_access_collective?(event, user)
    collective_member = CollectiveMember.find_by(collective: event.collective, user: user)
    collective_member.present? && !collective_member.archived?
  end

  private_class_method :get_created_by, :get_path, :decision_participants, :commitment_participants,
                       :user_can_access_collective?
end
