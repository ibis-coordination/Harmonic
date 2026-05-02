class CleanupOrphanedMessageSteps < ActiveRecord::Migration[7.2]
  def up
    # Remove old AgentSessionStep records with step_type "message" that were
    # migrated to the chat_messages table. These are no longer readable by the
    # app since "message" was removed from AgentSessionStep::STEP_TYPES.
    execute <<~SQL
      DELETE FROM agent_session_steps
      WHERE step_type = 'message';
    SQL
  end

  def down
    # Data deletion is irreversible — the messages live in chat_messages now.
  end
end
