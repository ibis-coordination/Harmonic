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
end
