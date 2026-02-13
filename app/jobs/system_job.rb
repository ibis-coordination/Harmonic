# typed: true
# frozen_string_literal: true

# Base class for jobs that intentionally operate outside tenant context.
#
# SystemJob provides safety guarantees:
# 1. Validates that no tenant context is set when the job starts
# 2. Makes the cross-tenant nature of the job explicit in the class hierarchy
#
# Use SystemJob for:
# - Cleanup/maintenance jobs that process data across all tenants
# - Jobs that iterate over tenants and set context for each
# - Administrative jobs that need cross-tenant access
#
# Usage:
#   class CleanupExpiredTokensJob < SystemJob
#     def perform
#       # Use unscoped_for_system_job to access data across tenants
#       ApiToken.unscoped_for_system_job.where(...).delete_all
#     end
#   end
#
# For jobs that iterate tenants and temporarily set context:
#   class BackfillJob < SystemJob
#     def perform
#       Tenant.find_each do |tenant|
#         with_tenant_context(tenant) do
#           # Process tenant's data with proper scoping
#         end
#       end
#     end
#   end
#
# IMPORTANT: If your job operates within a single tenant's context,
# use TenantScopedJob instead.
class SystemJob < ApplicationJob
  extend T::Sig

  # Error raised when a system job unexpectedly has tenant context set.
  # This would indicate a bug in the middleware or job scheduling.
  class UnexpectedTenantContextError < StandardError; end

  # Verify job is running without tenant context.
  # This runs automatically before perform.
  before_perform :verify_no_tenant_context!

  protected

  # Temporarily set tenant context for a block, then clear it.
  # Useful for system jobs that iterate over tenants.
  #
  # @param tenant [Tenant] The tenant to scope to
  # @yield Block to execute with tenant context
  sig { params(tenant: Tenant, _block: T.proc.void).void }
  def with_tenant_context(tenant, &_block)
    Tenant.set_thread_context(tenant)
    yield
  ensure
    Tenant.clear_thread_scope
    Superagent.clear_thread_scope
  end

  # Temporarily set tenant and superagent context for a block.
  #
  # @param tenant [Tenant] The tenant to scope to
  # @param superagent [Superagent] The superagent to scope to
  # @yield Block to execute with tenant and superagent context
  sig { params(tenant: Tenant, superagent: Superagent, _block: T.proc.void).void }
  def with_tenant_and_superagent_context(tenant, superagent, &_block)
    Tenant.set_thread_context(tenant)
    Superagent.set_thread_context(superagent)
    yield
  ensure
    Tenant.clear_thread_scope
    Superagent.clear_thread_scope
  end

  private

  sig { void }
  def verify_no_tenant_context!
    return if Tenant.current_id.nil?

    raise UnexpectedTenantContextError,
          "#{self.class.name} is a SystemJob and should not have tenant context set. " \
          "Found tenant_id: #{Tenant.current_id}. This indicates a bug in job scheduling " \
          "or the TenantContextMiddleware."
  end
end
