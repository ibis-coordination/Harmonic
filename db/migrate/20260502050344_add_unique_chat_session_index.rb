class AddUniqueChatSessionIndex < ActiveRecord::Migration[7.2]
  def up
    # Consolidate duplicate chat sessions (same tenant + agent + user).
    # Keep the session with the most recent task_run activity; reassign
    # task_runs from duplicates to the keeper, then delete duplicates.
    execute <<~SQL
      WITH ranked AS (
        SELECT
          cs.id,
          cs.tenant_id,
          cs.ai_agent_id,
          cs.initiated_by_id,
          ROW_NUMBER() OVER (
            PARTITION BY cs.tenant_id, cs.ai_agent_id, cs.initiated_by_id
            ORDER BY COALESCE(
              (SELECT MAX(tr.created_at) FROM ai_agent_task_runs tr WHERE tr.chat_session_id = cs.id),
              cs.created_at
            ) DESC
          ) AS rn
        FROM chat_sessions cs
      ),
      keepers AS (
        SELECT id, tenant_id, ai_agent_id, initiated_by_id
        FROM ranked
        WHERE rn = 1
      )
      UPDATE ai_agent_task_runs
      SET chat_session_id = keepers.id
      FROM ranked
      JOIN keepers
        ON keepers.tenant_id = ranked.tenant_id
        AND keepers.ai_agent_id = ranked.ai_agent_id
        AND keepers.initiated_by_id = ranked.initiated_by_id
      WHERE ai_agent_task_runs.chat_session_id = ranked.id
        AND ranked.rn > 1;
    SQL

    execute <<~SQL
      WITH ranked AS (
        SELECT
          cs.id,
          ROW_NUMBER() OVER (
            PARTITION BY cs.tenant_id, cs.ai_agent_id, cs.initiated_by_id
            ORDER BY COALESCE(
              (SELECT MAX(tr.created_at) FROM ai_agent_task_runs tr WHERE tr.chat_session_id = cs.id),
              cs.created_at
            ) DESC
          ) AS rn
        FROM chat_sessions cs
      )
      DELETE FROM chat_sessions
      WHERE id IN (SELECT id FROM ranked WHERE rn > 1);
    SQL

    # Remove the old non-unique index if it exists
    remove_index :chat_sessions, [:ai_agent_id, :initiated_by_id], if_exists: true

    # Add unique index enforcing one session per agent-user pair per tenant
    add_index :chat_sessions, [:tenant_id, :ai_agent_id, :initiated_by_id],
              unique: true,
              name: "index_chat_sessions_unique_per_agent_user"
  end

  def down
    remove_index :chat_sessions, name: "index_chat_sessions_unique_per_agent_user", if_exists: true
  end
end
