class AddAiAgentTaskRunIdToMcpToolCallLogs < ActiveRecord::Migration[7.2]
  def up
    unless column_exists?(:mcp_tool_call_logs, :ai_agent_task_run_id)
      add_column :mcp_tool_call_logs, :ai_agent_task_run_id, :uuid, null: true
    end

    # Drop any pre-existing FK on this column (may have been added by an earlier
    # iteration of this migration without on_delete: :nullify) so we can
    # recreate it with the audit-trail-correct cascade.
    if foreign_key_exists?(:mcp_tool_call_logs, column: :ai_agent_task_run_id)
      remove_foreign_key :mcp_tool_call_logs, column: :ai_agent_task_run_id
    end
    add_foreign_key :mcp_tool_call_logs, :ai_agent_task_runs,
                    column: :ai_agent_task_run_id, on_delete: :nullify

    # Compound index supports the most common query shape:
    # "what tool calls happened during task run X, in order?"
    unless index_exists?(:mcp_tool_call_logs, [:ai_agent_task_run_id, :created_at],
                        name: "idx_mcp_logs_on_task_run_and_created_at")
      add_index :mcp_tool_call_logs, [:ai_agent_task_run_id, :created_at],
                where: "ai_agent_task_run_id IS NOT NULL",
                name: "idx_mcp_logs_on_task_run_and_created_at"
    end
  end

  def down
    if index_exists?(:mcp_tool_call_logs, [:ai_agent_task_run_id, :created_at],
                    name: "idx_mcp_logs_on_task_run_and_created_at")
      remove_index :mcp_tool_call_logs, name: "idx_mcp_logs_on_task_run_and_created_at"
    end
    if foreign_key_exists?(:mcp_tool_call_logs, column: :ai_agent_task_run_id)
      remove_foreign_key :mcp_tool_call_logs, column: :ai_agent_task_run_id
    end
    if column_exists?(:mcp_tool_call_logs, :ai_agent_task_run_id)
      remove_column :mcp_tool_call_logs, :ai_agent_task_run_id
    end
  end
end
