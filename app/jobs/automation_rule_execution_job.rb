# typed: true
# frozen_string_literal: true

class AutomationRuleExecutionJob < TenantScopedJob
  extend T::Sig

  queue_as :default

  sig { params(automation_rule_run_id: String, tenant_id: String).void }
  def perform(automation_rule_run_id:, tenant_id:)
    # Set tenant context first (explicit is better than implicit)
    tenant = Tenant.find_by(id: tenant_id)
    return unless tenant

    set_tenant_context!(tenant)

    # Now load the run within tenant context
    run = AutomationRuleRun.tenant_scoped_only.find_by(id: automation_rule_run_id)
    return unless run

    # Skip if already processed
    return unless run.pending?

    # Set superagent context if the rule/run has one
    superagent = run.superagent || run.automation_rule&.superagent
    if superagent
      set_superagent_context!(superagent)
    else
      clear_superagent_context!
    end

    # Execute the rule
    AutomationExecutor.execute(run)
  rescue StandardError => e
    Rails.logger.error("[AutomationRuleExecutionJob] Error executing run #{automation_rule_run_id}: #{e.message}")
    Rails.logger.error(e.backtrace&.join("\n") || "No backtrace available")

    # Mark as failed if not already
    run.mark_failed!(e.message) if run && (run.pending? || run.running?)
  end
end
