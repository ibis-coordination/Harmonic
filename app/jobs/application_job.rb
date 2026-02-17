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
      tenant_id: Thread.current[:tenant_id],
      tenant_subdomain: Thread.current[:tenant_subdomain],
      main_collective_id: Thread.current[:main_collective_id],
      collective_id: Thread.current[:collective_id],
      collective_handle: Thread.current[:collective_handle],
      ai_agent_task_run_id: Thread.current[:ai_agent_task_run_id],
    }
  end

  def restore_tenant_context(saved)
    Thread.current[:tenant_id] = saved[:tenant_id]
    Thread.current[:tenant_subdomain] = saved[:tenant_subdomain]
    Thread.current[:main_collective_id] = saved[:main_collective_id]
    Thread.current[:collective_id] = saved[:collective_id]
    Thread.current[:collective_handle] = saved[:collective_handle]
    Thread.current[:ai_agent_task_run_id] = saved[:ai_agent_task_run_id]
  end

  def clear_all_tenant_context
    Tenant.clear_thread_scope
    Collective.clear_thread_scope
    AiAgentTaskRun.clear_thread_scope
  end
end
