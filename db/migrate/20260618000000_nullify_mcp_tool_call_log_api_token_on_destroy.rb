class NullifyMcpToolCallLogApiTokenOnDestroy < ActiveRecord::Migration[7.2]
  # Task-scoped internal ApiTokens are destroyed on task completion. Audit
  # rows in mcp_tool_call_logs that reference those tokens must survive — the
  # log is the load-bearing record, the token pointer is incidental. The
  # original FK was RESTRICT + NOT NULL, which blocked the cleanup with a
  # PG::ForeignKeyViolation and left the task in a half-finished state.
  def change
    change_column_null :mcp_tool_call_logs, :api_token_id, true

    remove_foreign_key :mcp_tool_call_logs, :api_tokens
    add_foreign_key :mcp_tool_call_logs, :api_tokens, on_delete: :nullify
  end
end
