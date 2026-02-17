# typed: true
# frozen_string_literal: true

class AutomationRuleExecutionJob < TenantScopedJob
  extend T::Sig

  queue_as :default

  sig do
    params(
      automation_rule_run_id: String,
      tenant_id: String,
      chain: T.nilable(T::Hash[String, T.untyped])
    ).void
  end
  def perform(automation_rule_run_id:, tenant_id:, chain: nil)
    # Restore chain context from parent execution (for cascade tracking)
    # This must happen before any automation logic runs
    AutomationContext.restore_chain!(chain) if chain.present?

    # Set tenant context first (explicit is better than implicit)
    tenant = Tenant.find_by(id: tenant_id)
    return unless tenant

    set_tenant_context!(tenant)

    # Now load the run within tenant context
    run = AutomationRuleRun.tenant_scoped_only.find_by(id: automation_rule_run_id)
    return unless run

    # Skip if already processed
    return unless run.pending?

    # Set collective context if the rule/run has one
    collective = run.collective || run.automation_rule&.collective
    if collective
      set_collective_context!(collective)
    else
      clear_collective_context!
    end

    # Execute the rule (any events created during execution will inherit the chain context)
    AutomationExecutor.execute(run)
  rescue StandardError => e
    Rails.logger.error("[AutomationRuleExecutionJob] Error executing run #{automation_rule_run_id}: #{e.message}")
    Rails.logger.error(e.backtrace&.join("\n") || "No backtrace available")

    # Mark as failed if not already
    run.mark_failed!(e.message) if run && (run.pending? || run.running?)
  ensure
    # Always clear chain context when job completes
    AutomationContext.clear_chain!
  end
end
