class AddCurrentStateToChatSessions < ActiveRecord::Migration[7.2]
  def change
    add_column :chat_sessions, :current_state, :jsonb, null: false, default: {}
  end
end
