# typed: false

class AiAgentTaskRun < ApplicationRecord
  DEFAULT_MAX_STEPS = 30

  belongs_to :tenant
  belongs_to :ai_agent, class_name: "User"
  belongs_to :initiated_by, class_name: "User"
  belongs_to :automation_rule, optional: true

  has_many :ai_agent_task_run_resources, dependent: :destroy

  validates :task, presence: true
  validates :max_steps, presence: true, numericality: { greater_than: 0, less_than_or_equal_to: 50 }
  validates :status, presence: true, inclusion: { in: ["queued", "pending", "running", "completed", "failed", "cancelled"] }

  scope :recent, -> { order(created_at: :desc) }
  scope :for_ai_agent, ->(ai_agent) { where(ai_agent: ai_agent) }
  scope :completed, -> { where(status: "completed") }
  scope :with_usage, -> { where.not(total_tokens: 0) }
  scope :in_period, ->(start_date, end_date) { where(completed_at: start_date..end_date) }

  # Calculate total cost for completed tasks in a date range
  #
  # @param start_date [Date, Time] Start of the period
  # @param end_date [Date, Time] End of the period
  # @return [BigDecimal] Total cost in USD
  def self.total_cost_for_period(start_date, end_date)
    completed.in_period(start_date, end_date).sum(:estimated_cost_usd)
  end

  # Thread-local context management for tracking which task run is currently executing
  class << self
    def current_id
      Thread.current[:ai_agent_task_run_id]
    end

    def current_id=(id)
      Thread.current[:ai_agent_task_run_id] = id
    end

    def clear_thread_scope
      Thread.current[:ai_agent_task_run_id] = nil
    end

    # Factory method for creating queued task runs with proper defaults.
    # Centralizes the logic for extracting model from AI agent config.
    #
    # @param ai_agent [User] The AI agent to run the task
    # @param tenant [Tenant] The tenant context
    # @param initiated_by [User] The user who initiated the task
    # @param task [String] The task description/prompt
    # @param max_steps [Integer, nil] Optional max steps override
    # @param automation_rule [AutomationRule, nil] Optional automation rule that triggered this task
    # @return [AiAgentTaskRun] The created task run
    def create_queued(ai_agent:, tenant:, initiated_by:, task:, max_steps: nil, automation_rule: nil)
      model = ai_agent.agent_configuration&.dig("model") || "default"

      create!(
        tenant: tenant,
        ai_agent: ai_agent,
        initiated_by: initiated_by,
        task: task,
        max_steps: max_steps || DEFAULT_MAX_STEPS,
        model: model,
        status: "queued",
        automation_rule: automation_rule
      )
    end
  end

  # Convenience methods for querying created resources
  def created_notes
    Note.where(id: ai_agent_task_run_resources.where(resource_type: "Note", action_type: "create").select(:resource_id))
  end

  def created_decisions
    Decision.where(id: ai_agent_task_run_resources.where(resource_type: "Decision", action_type: "create").select(:resource_id))
  end

  def created_commitments
    Commitment.where(id: ai_agent_task_run_resources.where(resource_type: "Commitment", action_type: "create").select(:resource_id))
  end

  def all_resources
    ai_agent_task_run_resources.includes(:resource).map(&:resource)
  end

  def queued?
    status == "queued"
  end

  def running?
    status == "running"
  end

  def completed?
    status == "completed"
  end

  def failed?
    status == "failed"
  end

  def triggered_by_automation?
    automation_rule_id.present?
  end

  # Notify any parent automation rule runs that this task has reached a terminal state.
  # Called after task completion/failure to update the run's aggregate status.
  def notify_parent_automation_runs!
    return unless triggered_by_automation?

    # Find any AutomationRuleRun records that reference this task run
    # either via the belongs_to association or via actions_executed array
    parent_runs = find_parent_automation_runs
    parent_runs.each do |run|
      next unless run.running?

      run.update_status_from_actions!
    rescue StandardError => e
      Rails.logger.error("AiAgentTaskRun: Failed to notify parent run #{run.id}: #{e.message}")
    end
  end

  private

  def find_parent_automation_runs
    runs = []

    # For agent rules: AutomationRuleRun.ai_agent_task_run_id = self.id
    direct_run = AutomationRuleRun.find_by(ai_agent_task_run_id: id)
    runs << direct_run if direct_run

    # For general rules with trigger_agent actions: actions_executed contains task_run_id
    # This is more complex - we need to search JSON
    AutomationRuleRun.where(status: "running").find_each do |run|
      actions = run.actions_executed || []
      has_this_task = actions.any? do |action|
        (action.dig("result", "task_run_id") == id) ||
          (action.dig("result", :task_run_id) == id)
      end
      runs << run if has_this_task
    end

    runs.uniq
  end

  def duration
    return nil unless started_at && completed_at

    completed_at - started_at
  end

  def formatted_duration
    return nil unless duration

    if duration < 60
      "#{duration.round(1)}s"
    else
      minutes = (duration / 60).floor
      seconds = (duration % 60).round
      "#{minutes}m #{seconds}s"
    end
  end

  # Format the estimated cost for display
  #
  # @return [String, nil] Formatted cost (e.g., "$0.0035") or nil if no cost
  def formatted_cost
    return nil unless estimated_cost_usd&.positive?

    if estimated_cost_usd < 0.01
      "< $0.01"
    else
      "$#{format("%.4f", estimated_cost_usd)}"
    end
  end

  # Format the total tokens with commas for display
  #
  # @return [String, nil] Formatted tokens (e.g., "12,345") or nil if no tokens
  def formatted_tokens
    return nil unless total_tokens&.positive?

    total_tokens.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1,').reverse
  end

  def task_summary(max_length = 80)
    if task.length > max_length
      "#{task[0...max_length]}..."
    else
      task
    end
  end

  def status_badge_class
    case status
    when "completed"
      success ? "pulse-badge-success" : "pulse-badge-danger"
    when "failed"
      "pulse-badge-danger"
    when "running"
      "pulse-badge-info"
    when "queued"
      "pulse-badge-warning"
    else # cancelled, pending, or unknown
      "pulse-badge-muted"
    end
  end
end
