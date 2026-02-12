# typed: true

class AutomationRuleExecutionJob < ApplicationJob
  extend T::Sig

  queue_as :default

  sig { params(automation_rule_run_id: String).void }
  def perform(automation_rule_run_id:)
    run = AutomationRuleRun.find_by(id: automation_rule_run_id)
    return unless run

    # Skip if already processed
    return unless run.pending?

    # Execute the rule
    AutomationExecutor.execute(run)
  rescue StandardError => e
    Rails.logger.error("[AutomationRuleExecutionJob] Error executing run #{automation_rule_run_id}: #{e.message}")
    Rails.logger.error(e.backtrace&.join("\n") || "No backtrace available")

    # Mark as failed if not already
    if run && (run.pending? || run.running?)
      run.mark_failed!(e.message)
    end
  end
end
