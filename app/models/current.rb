# typed: false

# Centralized request-scoped state using ActiveSupport::CurrentAttributes.
#
# Replaces raw Thread.current[:...] usage across the codebase. Rails automatically
# resets all attributes at the end of every HTTP request (via ActionDispatch::Executor)
# and every ActiveJob execution, eliminating thread-local state leakage.
#
# Public APIs (Tenant.current_id, AutomationContext.current_run_id, etc.) delegate
# here — callers should continue using those domain-specific accessors.
class Current < ActiveSupport::CurrentAttributes
  # Tenant scope
  attribute :tenant_id, :tenant_subdomain, :main_collective_id

  # Collective scope
  attribute :collective_id, :collective_handle

  # Task run tracking
  attribute :ai_agent_task_run_id

  # Automation context
  attribute :automation_rule_run_id, :automation_chain

  # Current MCP tool call (when an MCP dispatch is in flight). Set by
  # Mcp::EndpointController before dispatching the inner request; read by
  # track_task_run_resource to attribute touched resources to the call.
  # mcp_action_name is the action name as invoked via the execute_action
  # MCP tool (`create_note`, `confirm_read`, etc.); nil for other tools.
  # mcp_action_context holds the agent-declared `context` block (read by
  # ActionContextValidation).
  attribute :mcp_tool_call_log_id, :mcp_action_name, :mcp_action_context

  # Data import flag — when true, model concerns (Tracked, Searchable, etc.)
  # skip side effects like Event creation and search indexing
  attribute :importing_data
end
