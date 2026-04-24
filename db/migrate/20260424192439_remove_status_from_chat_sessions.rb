class RemoveStatusFromChatSessions < ActiveRecord::Migration[7.2]
  def change
    remove_column :chat_sessions, :status, :string, null: false, default: "active"
  end
end
