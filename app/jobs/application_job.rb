# typed: false
# frozen_string_literal: true

# Base class for all background jobs.
#
# IMPORTANT: Do not inherit directly from ApplicationJob.
# All jobs must inherit from either:
#   - TenantScopedJob: For jobs that operate within a tenant context
#   - SystemJob: For jobs that operate across tenants (maintenance, cleanup)
#
# This ensures tenant context is properly managed for every job.
class ApplicationJob < ActiveJob::Base
  # Context management runs for all jobs.
  # This ensures:
  # 1. Jobs start with clean context (preventing stale context leakage)
  # 2. Context is restored after job completion (for inline perform_now)
  around_perform :with_clean_tenant_context

  private

  def with_clean_tenant_context
    # Save existing context (important for perform_now in tests)
    saved_context = save_tenant_context

    # Clear all context before job execution
    clear_all_tenant_context

    yield
  ensure
    # Restore saved context (for inline perform_now)
    restore_tenant_context(saved_context)
  end

  def save_tenant_context
    {
      tenant_id: Current.tenant_id,
      tenant_subdomain: Current.tenant_subdomain,
      main_collective_id: Current.main_collective_id,
      collective_id: Current.collective_id,
      collective_handle: Current.collective_handle,
      ai_agent_task_run_id: Current.ai_agent_task_run_id,
    }
  end

  def restore_tenant_context(saved)
    Current.tenant_id = saved[:tenant_id]
    Current.tenant_subdomain = saved[:tenant_subdomain]
    Current.main_collective_id = saved[:main_collective_id]
    Current.collective_id = saved[:collective_id]
    Current.collective_handle = saved[:collective_handle]
    Current.ai_agent_task_run_id = saved[:ai_agent_task_run_id]
  end

  def clear_all_tenant_context
    Current.reset
  end
end
