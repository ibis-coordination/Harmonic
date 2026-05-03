# typed: false

class ChatSessionChannel < ApplicationCable::Channel
  def subscribed
    chat_session = ChatSession.find_by(id: params[:session_id])

    if chat_session.nil? || !chat_session.participant?(current_user)
      reject
      return
    end

    stream_for chat_session
  end
end
