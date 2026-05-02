class GeneralizeChatSessionParticipants < ActiveRecord::Migration[7.2]
  def up
    # Add new generic participant columns
    add_reference :chat_sessions, :user_one, type: :uuid, null: true, foreign_key: { to_table: :users }
    add_reference :chat_sessions, :user_two, type: :uuid, null: true, foreign_key: { to_table: :users }

    # Backfill: store participants in canonical order (lower UUID first)
    # so the unique index works regardless of who initiates
    execute <<~SQL
      UPDATE chat_sessions
      SET user_one_id = LEAST(ai_agent_id, initiated_by_id),
          user_two_id = GREATEST(ai_agent_id, initiated_by_id);
    SQL

    # Make NOT NULL and add unique index
    change_column_null :chat_sessions, :user_one_id, false
    change_column_null :chat_sessions, :user_two_id, false
    add_index :chat_sessions, [:tenant_id, :user_one_id, :user_two_id],
              unique: true,
              name: "index_chat_sessions_unique_participants"

    # Remove old columns and their index
    remove_index :chat_sessions, name: "index_chat_sessions_unique_per_agent_user", if_exists: true
    remove_column :chat_sessions, :ai_agent_id
    remove_column :chat_sessions, :initiated_by_id
  end

  def down
    add_reference :chat_sessions, :ai_agent, type: :uuid, null: true, foreign_key: { to_table: :users }
    add_reference :chat_sessions, :initiated_by, type: :uuid, null: true, foreign_key: { to_table: :users }

    # Best-effort restore: user_one → ai_agent, user_two → initiated_by
    # (not guaranteed to be correct for all sessions)
    execute <<~SQL
      UPDATE chat_sessions
      SET ai_agent_id = user_one_id,
          initiated_by_id = user_two_id;
    SQL

    change_column_null :chat_sessions, :ai_agent_id, false
    change_column_null :chat_sessions, :initiated_by_id, false

    remove_index :chat_sessions, name: "index_chat_sessions_unique_participants", if_exists: true
    remove_column :chat_sessions, :user_one_id
    remove_column :chat_sessions, :user_two_id
  end
end
