class AddCollectiveIdToChatSessionsAndChatMessages < ActiveRecord::Migration[7.2]
  def up
    add_reference :chat_sessions, :collective, type: :uuid, null: true, foreign_key: true
    add_reference :chat_messages, :collective, type: :uuid, null: true, foreign_key: true

    # Backfill existing records with the tenant's main collective
    execute <<~SQL
      UPDATE chat_sessions
      SET collective_id = tenants.main_collective_id
      FROM tenants
      WHERE chat_sessions.tenant_id = tenants.id
        AND chat_sessions.collective_id IS NULL;
    SQL

    execute <<~SQL
      UPDATE chat_messages
      SET collective_id = tenants.main_collective_id
      FROM tenants
      WHERE chat_messages.tenant_id = tenants.id
        AND chat_messages.collective_id IS NULL;
    SQL

    change_column_null :chat_sessions, :collective_id, false
    change_column_null :chat_messages, :collective_id, false
  end

  def down
    remove_reference :chat_messages, :collective
    remove_reference :chat_sessions, :collective
  end
end
