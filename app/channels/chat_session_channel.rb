# typed: false

class ChatSessionChannel < ApplicationCable::Channel
  def subscribed
    stream_for_authorized(find_session) { |session| session.participant?(current_user) }
  end

  private

  def find_session
    ChatSession.find_by(id: params[:session_id])
  end
end
