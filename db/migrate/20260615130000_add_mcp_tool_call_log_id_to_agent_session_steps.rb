class AddMcpToolCallLogIdToAgentSessionSteps < ActiveRecord::Migration[7.2]
  def change
    # Optional link from an agent_session_step to the McpToolCallLog row
    # representing the underlying MCP tool call. Populated by the agent-runner
    # from the _meta.harmonic.tool_call_log_id field on the MCP response, so
    # the steps timeline can deep-link to the raw call record.
    #
    # Pre-runner-migration step rows leave this null. Loop-internal step
    # types (think, done, error, security_warning, scratchpad_update*) also
    # leave it null because they don't correspond to a tool call.
    #
    # on_delete: :nullify so a step row survives audit-log retention pruning
    # (eventual partition+archive) with a broken link rather than vanishing.
    add_reference :agent_session_steps, :mcp_tool_call_log,
                  type: :uuid,
                  null: true,
                  foreign_key: { on_delete: :nullify },
                  index: { where: "mcp_tool_call_log_id IS NOT NULL", name: "idx_session_steps_on_mcp_log" }
  end
end
