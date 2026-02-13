# typed: true

class AutomationRuleRun < ApplicationRecord
  extend T::Sig
  include MightNotBelongToSuperagent

  STATUSES = ["pending", "running", "completed", "failed", "skipped"].freeze
  TRIGGER_SOURCES = ["event", "schedule", "webhook", "manual"].freeze

  belongs_to :tenant
  belongs_to :superagent, optional: true
  belongs_to :automation_rule
  belongs_to :triggered_by_event, class_name: "Event", optional: true
  belongs_to :ai_agent_task_run, optional: true

  validates :status, inclusion: { in: STATUSES }
  validates :trigger_source, inclusion: { in: TRIGGER_SOURCES }, allow_nil: true
  validate :tenant_matches_rule
  validate :superagent_matches_rule

  before_validation :set_tenant_and_superagent_from_rule, on: :create

  scope :pending, -> { where(status: "pending") }
  scope :running, -> { where(status: "running") }
  scope :completed, -> { where(status: "completed") }
  scope :failed, -> { where(status: "failed") }
  scope :recent, -> { order(created_at: :desc) }

  sig { returns(T::Boolean) }
  def pending?
    status == "pending"
  end

  sig { returns(T::Boolean) }
  def running?
    status == "running"
  end

  sig { returns(T::Boolean) }
  def completed?
    status == "completed"
  end

  sig { returns(T::Boolean) }
  def failed?
    status == "failed"
  end

  sig { returns(T::Boolean) }
  def skipped?
    status == "skipped"
  end

  sig { void }
  def mark_running!
    update!(status: "running", started_at: Time.current)
  end

  sig { params(executed_actions: T::Array[T::Hash[String, T.untyped]]).void }
  def mark_completed!(executed_actions: [])
    update!(
      status: "completed",
      completed_at: Time.current,
      actions_executed: executed_actions
    )
  end

  sig { params(message: String).void }
  def mark_failed!(message)
    update!(
      status: "failed",
      completed_at: Time.current,
      error_message: message
    )
  end

  sig { params(reason: String).void }
  def mark_skipped!(reason)
    update!(
      status: "skipped",
      completed_at: Time.current,
      error_message: reason
    )
  end

  sig { params(task_run: AiAgentTaskRun).void }
  def link_to_task_run!(task_run)
    update!(ai_agent_task_run: task_run)
  end

  private

  sig { void }
  def set_tenant_and_superagent_from_rule
    rule = automation_rule
    return unless rule

    self.tenant_id = rule.tenant_id if tenant_id.nil?
    self.superagent_id = rule.superagent_id if superagent_id.nil?
  end

  sig { void }
  def tenant_matches_rule
    rule = automation_rule
    return unless rule && tenant_id

    return if tenant_id == rule.tenant_id

    errors.add(:tenant, "must match the automation rule's tenant")
  end

  sig { void }
  def superagent_matches_rule
    rule = automation_rule
    return unless rule

    # Both nil is valid (for agent rules without superagent scope)
    return if superagent_id.nil? && rule.superagent_id.nil?

    # Both must match if either is set
    return if superagent_id == rule.superagent_id

    errors.add(:superagent, "must match the automation rule's superagent")
  end
end
