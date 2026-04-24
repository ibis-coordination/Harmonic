class RemoveCollectiveFromChatSessions < ActiveRecord::Migration[7.2]
  def change
    remove_reference :chat_sessions, :collective, type: :uuid, foreign_key: true
  end
end
