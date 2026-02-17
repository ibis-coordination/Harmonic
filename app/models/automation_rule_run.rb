# typed: true

class AutomationRuleRun < ApplicationRecord
  extend T::Sig
  include MightNotBelongToSuperagent

  STATUSES = ["pending", "running", "completed", "failed", "skipped"].freeze
  TRIGGER_SOURCES = ["event", "schedule", "webhook", "manual", "test"].freeze

  belongs_to :tenant
  belongs_to :superagent, optional: true
  belongs_to :automation_rule
  belongs_to :triggered_by_event, class_name: "Event", optional: true
  belongs_to :ai_agent_task_run, optional: true
  has_many :webhook_deliveries, dependent: :nullify
  has_many :automation_rule_run_resources, dependent: :destroy

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

  # Get all notes created by this automation run
  sig { returns(T::Array[Note]) }
  def created_notes
    resource_ids = automation_rule_run_resources
      .where(resource_type: "Note", action_type: "create")
      .pluck(:resource_id)
    Note.tenant_scoped_only(tenant_id).where(id: resource_ids).to_a
  end

  # Get all decisions created by this automation run
  sig { returns(T::Array[Decision]) }
  def created_decisions
    resource_ids = automation_rule_run_resources
      .where(resource_type: "Decision", action_type: "create")
      .pluck(:resource_id)
    Decision.tenant_scoped_only(tenant_id).where(id: resource_ids).to_a
  end

  # Get all commitments created by this automation run
  sig { returns(T::Array[Commitment]) }
  def created_commitments
    resource_ids = automation_rule_run_resources
      .where(resource_type: "Commitment", action_type: "create")
      .pluck(:resource_id)
    Commitment.tenant_scoped_only(tenant_id).where(id: resource_ids).to_a
  end

  # Record executed actions without marking as completed.
  # Used for async actions that need to finish before run is complete.
  sig { params(executed_actions: T::Array[T::Hash[String, T.untyped]]).void }
  def record_actions!(executed_actions:)
    update!(actions_executed: executed_actions)
  end

  # Check if all async actions have finished executing.
  # Returns true if there are no pending webhooks or task runs.
  sig { returns(T::Boolean) }
  def all_async_actions_complete?
    # Check webhook deliveries
    pending_webhooks = webhook_deliveries.where(status: %w[pending retrying]).exists?
    return false if pending_webhooks

    # Check task runs from actions_executed
    task_run_ids = (actions_executed || [])
      .select { |a| a["type"] == "trigger_agent" }
      .map { |a| a.dig("result", "task_run_id") || a.dig("result", :task_run_id) }
      .compact

    if task_run_ids.any?
      # Check if any task runs are still in progress
      incomplete_tasks = AiAgentTaskRun.where(id: task_run_ids)
        .where.not(status: %w[completed failed cancelled])
        .exists?
      return false if incomplete_tasks
    end

    # Also check the linked ai_agent_task_run for agent rules
    task_run = ai_agent_task_run
    if task_run
      return false unless task_run.status.in?(%w[completed failed cancelled])
    end

    true
  end

  # Calculate and update status based on async action results.
  # Called when a webhook delivery or task run completes.
  sig { void }
  def update_status_from_actions!
    return unless running?
    return unless all_async_actions_complete?

    # Determine final status based on action outcomes
    webhook_statuses = webhook_deliveries.pluck(:status)
    task_run_statuses = collect_task_run_statuses

    all_statuses = webhook_statuses + task_run_statuses

    if all_statuses.empty?
      # No async actions, mark as completed
      mark_completed!(executed_actions: actions_executed || [])
    elsif all_statuses.all? { |s| s.in?(%w[success completed]) }
      # All succeeded
      mark_completed!(executed_actions: actions_executed || [])
    elsif all_statuses.any? { |s| s.in?(%w[success completed]) }
      # Mixed results - some succeeded, some failed
      first_error = find_first_error
      update!(
        status: "completed",
        completed_at: Time.current,
        error_message: "Some actions failed: #{first_error}"
      )
    else
      # All failed
      first_error = find_first_error
      mark_failed!(first_error || "All actions failed")
    end
  end

  private

  sig { returns(T::Array[String]) }
  def collect_task_run_statuses
    statuses = []

    # From trigger_agent actions
    task_run_ids = (actions_executed || [])
      .select { |a| a["type"] == "trigger_agent" }
      .map { |a| a.dig("result", "task_run_id") || a.dig("result", :task_run_id) }
      .compact

    if task_run_ids.any?
      statuses += AiAgentTaskRun.where(id: task_run_ids).pluck(:status)
    end

    # From linked agent rule task run
    linked_task_run = ai_agent_task_run
    if linked_task_run
      statuses << linked_task_run.status
    end

    statuses
  end

  sig { returns(T.nilable(String)) }
  def find_first_error
    # Check webhook errors
    failed_webhook = webhook_deliveries.where(status: "failed").first
    if failed_webhook && failed_webhook.error_message.present?
      return failed_webhook.error_message
    end

    # Check task run errors
    task_run_ids = (actions_executed || [])
      .select { |a| a["type"] == "trigger_agent" }
      .map { |a| a.dig("result", "task_run_id") || a.dig("result", :task_run_id) }
      .compact

    if task_run_ids.any?
      failed_task = AiAgentTaskRun.where(id: task_run_ids, status: "failed").first
      if failed_task
        return failed_task.error if failed_task.error.present?
      end
    end

    linked_task = ai_agent_task_run
    if linked_task && linked_task.status == "failed"
      return linked_task.error
    end

    nil
  end

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
