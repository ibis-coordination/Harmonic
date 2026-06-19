class AddContextToMcpToolCallLogs < ActiveRecord::Migration[7.2]
  # Verbatim audit of the agent-declared context block; separate from
  # `arguments` because that column is shape-summarized.
  def change
    add_column :mcp_tool_call_logs, :context, :jsonb
  end
end
