# typed: true

# Formats chat messages for delivery to the browser — used by both
# ActionCable broadcasts and the polling endpoint to ensure consistency.
class ChatMessagePresenter
  extend T::Sig

  sig { params(message: ChatMessage, chat_session: ChatSession).returns(T::Hash[String, T.untyped]) }
  def self.format(message, chat_session)
    is_agent = message.sender&.ai_agent? || false

    {
      type: "message",
      id: message.id,
      sender_id: message.sender_id,
      sender_name: message.sender&.name,
      content: message.content,
      content_html: is_agent ? MarkdownRenderer.render(message.content.to_s, shift_headers: false, display_references: false) : nil,
      timestamp: message.created_at.iso8601,
      is_agent: is_agent,
    }
  end
end
