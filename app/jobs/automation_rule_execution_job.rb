# typed: true
# frozen_string_literal: true

class AutomationRuleExecutionJob < TenantScopedJob
  extend T::Sig

  queue_as :default

  sig { params(automation_rule_run_id: String).void }
  def perform(automation_rule_run_id:)
    # Load run without tenant context (middleware cleared it)
    run = AutomationRuleRun.unscoped_for_system_job.find_by(id: automation_rule_run_id)
    return unless run

    # Skip if already processed
    return unless run.pending?

    # Set tenant context for the execution
    # This is required for things like User#display_name which depend on Tenant.current_id
    set_tenant_context!(run.tenant)

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
