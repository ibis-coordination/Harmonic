# typed: true

# Formats chat messages for delivery to the browser — used by both
# ActionCable broadcasts and the polling endpoint to ensure consistency.
class ChatMessagePresenter
  extend T::Sig

  sig { params(step: AgentSessionStep, chat_session: ChatSession).returns(T::Hash[String, T.untyped]) }
  def self.format(step, chat_session)
    {
      type: "message",
      id: step.id,
      sender_id: step.sender_id,
      sender_name: step.sender&.name,
      content: step.detail&.dig("content"),
      timestamp: step.created_at.iso8601,
      is_agent: step.sender_id == chat_session.ai_agent_id,
    }
  end
end
