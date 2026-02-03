# typed: false

class SubagentTaskRun < ApplicationRecord
  DEFAULT_MAX_STEPS = 30

  belongs_to :tenant
  belongs_to :subagent, class_name: "User"
  belongs_to :initiated_by, class_name: "User"

  validates :task, presence: true
  validates :max_steps, presence: true, numericality: { greater_than: 0, less_than_or_equal_to: 50 }
  validates :status, presence: true, inclusion: { in: ["queued", "pending", "running", "completed", "failed", "cancelled"] }

  scope :recent, -> { order(created_at: :desc) }
  scope :for_subagent, ->(subagent) { where(subagent: subagent) }

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
