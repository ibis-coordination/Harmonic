# typed: false

class AiAgentTaskRun < ApplicationRecord
  DEFAULT_MAX_STEPS = 30

  belongs_to :tenant
  belongs_to :ai_agent, class_name: "User"
  belongs_to :initiated_by, class_name: "User"

  has_many :ai_agent_task_run_resources, dependent: :destroy

  validates :task, presence: true
  validates :max_steps, presence: true, numericality: { greater_than: 0, less_than_or_equal_to: 50 }
  validates :status, presence: true, inclusion: { in: ["queued", "pending", "running", "completed", "failed", "cancelled"] }

  scope :recent, -> { order(created_at: :desc) }
  scope :for_ai_agent, ->(ai_agent) { where(ai_agent: ai_agent) }

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
    # @return [AiAgentTaskRun] The created task run
    def create_queued(ai_agent:, tenant:, initiated_by:, task:, max_steps: nil)
      model = ai_agent.agent_configuration&.dig("model") || "default"

      create!(
        tenant: tenant,
        ai_agent: ai_agent,
        initiated_by: initiated_by,
        task: task,
        max_steps: max_steps || DEFAULT_MAX_STEPS,
        model: model,
        status: "queued"
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
