# typed: false

class SubagentTaskRun < ApplicationRecord
  DEFAULT_MAX_STEPS = 30

  belongs_to :tenant
  belongs_to :subagent, class_name: "User"
  belongs_to :initiated_by, class_name: "User"

  has_many :subagent_task_run_resources, dependent: :destroy

  validates :task, presence: true
  validates :max_steps, presence: true, numericality: { greater_than: 0, less_than_or_equal_to: 50 }
  validates :status, presence: true, inclusion: { in: ["queued", "pending", "running", "completed", "failed", "cancelled"] }

  scope :recent, -> { order(created_at: :desc) }
  scope :for_subagent, ->(subagent) { where(subagent: subagent) }

  # Thread-local context management for tracking which task run is currently executing
  class << self
    def current_id
      Thread.current[:subagent_task_run_id]
    end

    def current_id=(id)
      Thread.current[:subagent_task_run_id] = id
    end

    def clear_thread_scope
      Thread.current[:subagent_task_run_id] = nil
    end
  end

  # Convenience methods for querying created resources
  def created_notes
    Note.where(id: subagent_task_run_resources.where(resource_type: "Note", action_type: "create").select(:resource_id))
  end

  def created_decisions
    Decision.where(id: subagent_task_run_resources.where(resource_type: "Decision", action_type: "create").select(:resource_id))
  end

  def created_commitments
    Commitment.where(id: subagent_task_run_resources.where(resource_type: "Commitment", action_type: "create").select(:resource_id))
  end

  def all_resources
    subagent_task_run_resources.includes(:resource).map(&:resource)
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
