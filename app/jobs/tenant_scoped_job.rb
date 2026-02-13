# typed: true
# frozen_string_literal: true

# Base class for jobs that operate within a tenant context.
#
# TenantScopedJob provides safety guarantees:
# 1. Jobs start with clean context (via TenantContextMiddleware)
# 2. Subclasses must explicitly set tenant context before accessing tenant-scoped data
# 3. Helper methods provide a consistent interface for setting context
#
# Usage patterns:
#
# Pattern 1: Load a record and set context from it
#   def perform(note_id)
#     note = Note.unscoped_for_system_job.find_by(id: note_id)
#     return unless note
#
#     set_tenant_context!(note.tenant)
#     # Now you can access tenant-scoped data
#   end
#
# Pattern 2: Receive tenant_id as a parameter
#   def perform(note_id:, tenant_id:)
#     tenant = Tenant.find_by(id: tenant_id)
#     return unless tenant
#
#     set_tenant_context!(tenant)
#     note = Note.find_by(id: note_id)  # Now properly scoped
#   end
#
# IMPORTANT: If your job needs to access data across all tenants (e.g., cleanup jobs),
# use SystemJob instead.
class TenantScopedJob < ApplicationJob
  extend T::Sig

  # Error raised when a job attempts to perform tenant-scoped operations
  # without first setting tenant context.
  class MissingTenantContextError < StandardError; end

  protected

  # Set the tenant context from a Tenant record.
  # Call this before accessing any tenant-scoped models.
  #
  # @param tenant [Tenant] The tenant to scope to
  sig { params(tenant: Tenant).void }
  def set_tenant_context!(tenant)
    Tenant.set_thread_context(tenant)
  end

  # Set the superagent context from a Superagent record.
  # Call this after set_tenant_context! if your job needs superagent scoping.
  #
  # @param superagent [Superagent] The superagent to scope to
  sig { params(superagent: Superagent).void }
  def set_superagent_context!(superagent)
    Superagent.set_thread_context(superagent)
  end

  # Set the AI agent task run context.
  # Used for tracking resources created by AI agent tasks.
  #
  # @param task_run [AiAgentTaskRun] The task run to set as current
  sig { params(task_run: AiAgentTaskRun).void }
  def set_task_run_context!(task_run)
    AiAgentTaskRun.current_id = task_run.id
  end

  # Clear superagent context without affecting tenant context.
  # Useful when processing items across multiple superagents within a tenant.
  sig { void }
  def clear_superagent_context!
    Superagent.clear_thread_scope
  end

  # Verify that tenant context has been set.
  # Call this at the start of any code that requires tenant scoping.
  #
  # @raise [MissingTenantContextError] if no tenant context is set
  sig { void }
  def require_tenant_context!
    return if Tenant.current_id.present?

    raise MissingTenantContextError,
          "#{self.class.name} requires tenant context but none was set. " \
          "Call set_tenant_context!(tenant) before accessing tenant-scoped data."
  end

  # Check if tenant context is currently set.
  #
  # @return [Boolean] true if tenant context is set
  sig { returns(T::Boolean) }
  def tenant_context_set?
    Tenant.current_id.present?
  end
end
