class MigrateMessageStepsToChatMessages < ActiveRecord::Migration[7.2]
  def up
    execute <<~SQL
      INSERT INTO chat_messages (id, tenant_id, chat_session_id, sender_id, content, created_at, updated_at)
      SELECT
        gen_random_uuid(),
        s.tenant_id,
        tr.chat_session_id,
        s.sender_id,
        COALESCE(s.detail->>'content', ''),
        s.created_at,
        s.created_at
      FROM agent_session_steps s
      JOIN ai_agent_task_runs tr ON tr.id = s.ai_agent_task_run_id
      WHERE s.step_type = 'message'
        AND tr.chat_session_id IS NOT NULL
        AND s.sender_id IS NOT NULL;
    SQL
  end

  def down
    execute "DELETE FROM chat_messages;"
  end
end
