# typed: false

class ChatSessionChannel < ApplicationCable::Channel
  def subscribed
    chat_session = ChatSession.find_by(
      id: params[:session_id],
      initiated_by_id: current_user.id,
    )

    if chat_session.nil?
      reject
      return
    end

    stream_for chat_session
  end
end
