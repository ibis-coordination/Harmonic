# typed: true

class AutomationMentionFilter
  extend T::Sig

  # Check if an event matches a mention filter for a specific agent
  sig { params(event: Event, ai_agent: User, mention_filter: T.nilable(String)).returns(T::Boolean) }
  def self.matches?(event, ai_agent, mention_filter)
    return true if mention_filter.blank?

    case mention_filter
    when "self"
      agent_mentioned_in_event?(event, ai_agent)
    when "any_agent"
      any_agent_mentioned_in_event?(event)
    else
      # Unknown filter type - don't match
      false
    end
  end

  # Check if a specific agent was mentioned in the event's subject content
  sig { params(event: Event, ai_agent: User).returns(T::Boolean) }
  def self.agent_mentioned_in_event?(event, ai_agent)
    text = extract_mentionable_text(event.subject)
    return false if text.blank?

    mentioned_users = MentionParser.parse(text, tenant_id: event.tenant_id)
    mentioned_users.any? { |user| user.id == ai_agent.id }
  end

  # Check if any AI agent was mentioned in the event's subject content
  sig { params(event: Event).returns(T::Boolean) }
  def self.any_agent_mentioned_in_event?(event)
    text = extract_mentionable_text(event.subject)
    return false if text.blank?

    mentioned_users = MentionParser.parse(text, tenant_id: event.tenant_id)
    mentioned_users.any?(&:ai_agent?)
  end

  # Extract text content from various subject types that might contain mentions
  sig { params(subject: T.untyped).returns(T.nilable(String)) }
  def self.extract_mentionable_text(subject)
    return nil if subject.nil?

    texts = []

    # Note (including comments)
    texts << subject.text if subject.respond_to?(:text)

    # Decision
    texts << subject.question if subject.respond_to?(:question)
    texts << subject.description if subject.respond_to?(:description)

    # Commitment
    texts << subject.title if subject.respond_to?(:title)

    # Option
    if subject.is_a?(Option) && subject.respond_to?(:decision) && subject.respond_to?(:title)
      # Option title and description
      texts << subject.title
    end

    texts.compact.join(" ")
  end

  private_class_method :extract_mentionable_text
end
