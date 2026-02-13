# typed: true
# frozen_string_literal: true

# AutomationSchedulerJob processes scheduled automation rules across all tenants.
# It runs every minute (via sidekiq-cron) and triggers rules whose cron expressions
# match the current time.
#
# This is a SystemJob because it operates across all tenants without a specific
# tenant context.
class AutomationSchedulerJob < SystemJob
  extend T::Sig

  queue_as :default

  sig { void }
  def perform
    scheduled_rules.find_each do |rule|
      process_rule(rule)
    rescue StandardError => e
      # Log error but continue processing other rules
      Rails.logger.error("AutomationSchedulerJob: Failed to process rule #{rule.id}: #{e.message}")
    end
  end

  private

  sig { returns(ActiveRecord::Relation) }
  def scheduled_rules
    AutomationRule.unscoped_for_system_job
      .where(trigger_type: "schedule")
      .where(enabled: true)
  end

  sig { params(rule: AutomationRule).void }
  def process_rule(rule)
    return unless should_trigger?(rule)
    return if already_ran_this_minute?(rule)

    create_and_queue_run(rule)
  end

  sig { params(rule: AutomationRule).returns(T::Boolean) }
  def should_trigger?(rule)
    cron_expression = rule.cron_expression
    return false if cron_expression.blank?

    timezone = rule.timezone || "UTC"

    begin
      # Parse cron with timezone so Fugit evaluates the expression in the correct timezone
      # e.g., "0 9 * * *" with timezone "America/New_York" means 9am in New York
      cron = Fugit::Cron.parse("#{cron_expression} #{timezone}")
      return false unless cron

      # Check if current time matches the cron expression
      # Use beginning_of_minute because cron.match? only returns true at second 0
      now = Time.current.utc.change(sec: 0)
      cron.match?(now)
    rescue StandardError => e
      Rails.logger.error("AutomationSchedulerJob: Invalid cron '#{cron_expression}' for rule #{rule.id}: #{e.message}")
      false
    end
  end

  sig { params(rule: AutomationRule).returns(T::Boolean) }
  def already_ran_this_minute?(rule)
    last_executed = rule.last_executed_at
    return false if last_executed.nil?

    # Check if last execution was within the current minute
    # Note: Using change(sec: 0) instead of beginning_of_minute for Sorbet compatibility
    last_executed >= Time.current.change(sec: 0)
  end

  sig { params(rule: AutomationRule).void }
  def create_and_queue_run(rule)
    # Update last_executed_at immediately to prevent duplicate runs
    # (the executor will also update it, but we need it now for duplicate detection)
    rule.update!(last_executed_at: Time.current)

    run = AutomationRuleRun.create!(
      tenant: rule.tenant,
      automation_rule: rule,
      trigger_source: "schedule",
      trigger_data: { "scheduled_at" => Time.current.iso8601 },
      status: "pending"
    )

    AutomationRuleExecutionJob.perform_later(
      automation_rule_run_id: run.id,
      tenant_id: rule.tenant_id
    )

    Rails.logger.info("AutomationSchedulerJob: Queued rule #{rule.id} (#{rule.name}) for execution")
  end
end
